//! Transpiles and executes a bflat-built OpenVM RV32 guest with cost metering.
//!
//!   openvm-runelf [--execute-only] <elf> [-] <input-bytes>...
//!
//! For each input, in order, prints one line per value:
//!
//!   public_values=<64 hex digits>
//!   instret=<u64>
//!   cost=<u64>
//!
//! --execute-only skips proving-key setup and cost metering, printing only
//! public_values for correctness checks.
//!
//! The optional `-` is the configuration argument of the RV64 runner's older
//! tags, where it selects the standard configuration; this runner has only that
//! one. The configuration is SdkVmConfig::standard() of the SDK, the one the
//! moduli and curves of libopenvm32 are registered in the order of. There is no
//! division hint: OpenVM's RV32 line has no hint the guest could ask for it with.
use openvm_circuit::{
    arch::instructions::exe::VmExe, system::memory::merkle::public_values::extract_public_values,
};
use openvm_sdk::{
    config::{AggregationSystemParams, AppConfig},
    Sdk, StdIn,
};
use openvm_sdk_config::{SdkVmConfig, TranspilerConfig};
use openvm_stark_sdk::config::{app_params_with_100_bits_security, MAX_APP_LOG_STACKED_HEIGHT};
use openvm_transpiler::{elf::Elf, openvm_platform::memory::MEM_SIZE, FromElf};
use std::sync::Arc;

fn main() -> eyre::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let execute_only = args.first().is_some_and(|arg| arg == "--execute-only");
    let args = if execute_only { &args[1..] } else { &args[..] };
    let (elf, inputs) = match args.split_first() {
        Some((elf, rest)) if !rest.is_empty() => {
            (elf, if rest[0] == "-" { &rest[1..] } else { rest })
        }
        _ => eyre::bail!("usage: openvm-runelf [--execute-only] <elf> [-] <input-bytes>..."),
    };
    if inputs.is_empty() {
        eyre::bail!("usage: openvm-runelf [--execute-only] <elf> [-] <input-bytes>...");
    }

    let vm_config = SdkVmConfig::standard();
    let transpiler = vm_config.transpiler().clone();
    let app_config =
        AppConfig::new(vm_config, app_params_with_100_bits_security(MAX_APP_LOG_STACKED_HEIGHT));
    let sdk = Sdk::builder()
        .app_config(app_config)
        .agg_params(AggregationSystemParams::default())
        .build()?;
    let exe = VmExe::from_elf(Elf::decode(&std::fs::read(elf)?, MEM_SIZE as u32)?, transpiler)?;
    if execute_only {
        let exe = Arc::new(exe);
        for input in inputs {
            let mut stdin = StdIn::default();
            stdin.write_bytes(&std::fs::read(input)?);
            let t = std::time::Instant::now();
            let public_values = sdk.execute(exe.clone(), stdin)?;
            eprintln!("{input} executed in {:?}", t.elapsed());
            println!("public_values={}", hex::encode(public_values));
        }
        return Ok(());
    }
    let app_prover = sdk.app_prover(exe)?;
    let vm = app_prover.vm();
    let exe = app_prover.exe();
    let interpreter = vm.metered_cost_interpreter(&exe)?;

    for input in inputs {
        let mut stdin = StdIn::default();
        stdin.write_bytes(&std::fs::read(input)?);
        let ctx = vm.build_metered_cost_ctx().with_max_execution_cost(1u64 << 58);
        let t = std::time::Instant::now();
        let (ctx, state) = interpreter.execute_metered_cost(stdin, ctx)?;
        eprintln!("{input} executed in {:?}", t.elapsed());
        println!("public_values={}", hex::encode(extract_public_values(32, &state.memory.memory)));
        println!("instret={}", ctx.instret);
        println!("cost={}", ctx.cost);
    }
    Ok(())
}
