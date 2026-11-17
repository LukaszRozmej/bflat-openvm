use std::path::PathBuf;
use openvm_sdk::{config::{AggregationSystemParams, AppConfig}, GenericSdk, StdIn};
use openvm_sdk_config::SdkVmConfig;
use openvm_stark_sdk::config::{
    app_params_with_100_bits_security, baby_bear_poseidon2::BabyBearPoseidon2CpuEngine,
    MAX_APP_LOG_STACKED_HEIGHT,
};

mod hints;
use hints::{RunnerVmConfig, RunnerVmCpuBuilder};

/// The same SDK and configuration as openvm-runelf (main.rs).
type Sdk = GenericSdk<BabyBearPoseidon2CpuEngine, RunnerVmCpuBuilder>;

/// Compiles the ELF once for metered execution, then executes every input and
/// prints one line per input on stdout, in input order:
///
///   RESULT <input> instret=<u64> cost=<u64> public_values=<64 hex digits>
///
/// instret is the count of retired instructions and cost the trace cost that
/// execute_metered_cost reports. Timings go to stderr only, so stdout is the
/// same for the same ELF and inputs.
fn main() -> eyre::Result<()> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 { eyre::bail!("usage: openvm-runelf-cost <elf> <input-bytes>..."); }
    // The line format splits on spaces.
    if let Some(bad) = a[2..].iter().find(|p| p.chars().any(char::is_whitespace)) {
        eyre::bail!("input path contains whitespace: {bad:?}");
    }
    let cfg = AppConfig::new(
        RunnerVmConfig(SdkVmConfig::standard()),
        app_params_with_100_bits_security(MAX_APP_LOG_STACKED_HEIGHT),
    );
    let sdk = Sdk::new(cfg, AggregationSystemParams::default())?;
    let compiled = sdk.compile_metered_cost(PathBuf::from(&a[1]))?;
    for input in &a[2..] {
        let mut stdin = StdIn::default();
        stdin.write_bytes(&std::fs::read(input)?);
        let t = std::time::Instant::now();
        let (out, (cost, instret)) = sdk.execute_metered_cost(&compiled, stdin)?;
        eprintln!("{input} executed in {:?}", t.elapsed());
        println!("RESULT {input} instret={instret} cost={cost} public_values={}", hex::encode(out));
    }
    Ok(())
}
