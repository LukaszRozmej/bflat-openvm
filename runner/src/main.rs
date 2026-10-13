use std::path::PathBuf;
use openvm_sdk::{config::{AggregationSystemParams, AppConfig}, GenericSdk, StdIn};
use openvm_stark_sdk::config::baby_bear_poseidon2::BabyBearPoseidon2CpuEngine;

mod hints;
use hints::{RunnerVmConfig, RunnerVmCpuBuilder};

/// The SDK on the configuration in openvm.toml plus the division hint (see hints.rs).
type Sdk = GenericSdk<BabyBearPoseidon2CpuEngine, RunnerVmCpuBuilder>;

fn main() -> eyre::Result<()> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 { eyre::bail!("usage: openvm-runelf <elf> <openvm.toml|-> <input-bytes>"); }
    // "-" means the configuration shipped in the image: the extension set the
    // bindings are built against. A guest that pins its own set passes a path.
    let cfg_path = if a[2] == "-" { "/openvm.toml".to_string() } else { a[2].clone() };
    let cfg: AppConfig<RunnerVmConfig> = toml::from_str(&std::fs::read_to_string(&cfg_path)?)?;
    let sdk = Sdk::new(cfg, AggregationSystemParams::default())?;
    let mut stdin = StdIn::default();
    stdin.write_bytes(&std::fs::read(&a[3])?);
    let t = std::time::Instant::now();
    let out = sdk.compile_and_execute(PathBuf::from(&a[1]), stdin)?;
    eprintln!("executed in {:?}", t.elapsed());
    println!("public_values={}", hex::encode(out));
    Ok(())
}
