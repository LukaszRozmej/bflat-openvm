//! A division hint: a phantom instruction that queues `n / d` and `n mod d`, for a 512-bit
//! `n` and a 256-bit `d`, on the hint stream. The guest reads them with HINT_BUFFER and checks
//! `q * d + r == n` and `r < d` with constrained instructions, so nothing here is trusted. A
//! phantom adds no AIR: the circuit, and so the proving and verifying keys, are the SDK
//! configuration's, but only an executor that registers the phantom can run such a guest.
use num_bigint::BigUint;
use openvm_circuit::{
    arch::{
        AirInventory, AirInventoryError, ChipInventoryError, ExecutorInventory,
        ExecutorInventoryBuilder, ExecutorInventoryError, InitFileGenerator, PhantomSubExecutor,
        Streams, SystemConfig, VmBuilder, VmChipComplex, VmCircuitConfig, VmExecutionConfig,
        VmExecutionExtension,
    },
    system::{memory::online::GuestMemory, SystemChipInventory},
};
use openvm_cpu_backend::{CpuBackend, CpuDevice};
use openvm_instructions::{
    instruction::{Instruction, InstructionOperand},
    riscv::{MEMORY_AS, REGISTER_NUM_LIMBS},
    PhantomDiscriminant,
};
use openvm_riscv_circuit::adapters::read_register_as_u32;
use openvm_sdk_config::{SdkVmConfig, SdkVmConfigExecutor, SdkVmCpuBuilder, TranspilerConfig};
use openvm_stark_backend::{StarkEngine, StarkProtocolConfig};
use openvm_stark_sdk::config::baby_bear_poseidon2::BabyBearPoseidon2Config;
use openvm_transpiler::{transpiler::Transpiler, TranspilerExtension, TranspilerOutput};
use rand::rngs::StdRng;
use serde::{Deserialize, Serialize};

/// custom-0 (0x0b), the system opcode, with the phantom funct3: `rd` holds the address of
/// `n` (64 bytes, little-endian) and `rs1` that of `d` (32 bytes). The imm selects this hint;
/// the RV64 transpiler claims only imm 0..=2.
const SYSTEM_OPCODE: u32 = 0x0b;
const PHANTOM_FUNCT3: u32 = 0b011;
pub const DIVREM_IMM: u32 = 0x4d1;
pub const DIVREM_PHANTOM: PhantomDiscriminant = PhantomDiscriminant(0x4e44);

#[derive(Clone, Copy, Default)]
pub struct DivRemHint;

#[derive(Clone, Copy)]
struct DivRemHintSubEx;

impl PhantomSubExecutor for DivRemHintSubEx {
    fn phantom_execute(
        &self,
        memory: &GuestMemory,
        streams: &mut Streams,
        _: &mut StdRng,
        _: PhantomDiscriminant,
        a: u32,
        b: u32,
        _: u16,
    ) -> eyre::Result<()> {
        let n_ptr = read_register_as_u32(memory, a);
        let d_ptr = read_register_as_u32(memory, b);
        // SAFETY: MEMORY_AS holds bytes and the pointers come from the guest's registers.
        let hint = unsafe {
            divrem_hint(
                memory.memory.get_u8_slice(MEMORY_AS, n_ptr as usize, 64),
                memory.memory.get_u8_slice(MEMORY_AS, d_ptr as usize, 32),
            )
        };
        streams.hint_stream.set_hint(hint);
        Ok(())
    }
}

/// `q || r`, 32 little-endian bytes each, for the little-endian `n` and `d`. A quotient of
/// 2^256 or more is truncated, and a zero divisor gives zeros: the guest's check rejects both.
fn divrem_hint(n: &[u8], d: &[u8]) -> Vec<u8> {
    let n = BigUint::from_bytes_le(n);
    let d = BigUint::from_bytes_le(d);
    let mut hint = vec![0u8; 64];
    if d.bits() == 0 {
        return hint;
    }
    let q = (&n / &d).to_bytes_le();
    let r = (&n % &d).to_bytes_le();
    let ql = q.len().min(32);
    hint[..ql].copy_from_slice(&q[..ql]);
    hint[32..32 + r.len()].copy_from_slice(&r);
    hint
}

/// `rd` and `rs1` of the hint's encoding, or `None` for any other instruction.
fn decode(insn: u32) -> Option<(usize, usize)> {
    if insn & 0x7f != SYSTEM_OPCODE || (insn >> 12) & 0b111 != PHANTOM_FUNCT3 || insn >> 20 != DIVREM_IMM {
        return None;
    }
    Some((((insn >> 7) & 0x1f) as usize, ((insn >> 15) & 0x1f) as usize))
}

impl VmExecutionExtension for DivRemHint {
    type Executor = SdkVmConfigExecutor;

    fn extend_execution(
        &self,
        inventory: &mut ExecutorInventoryBuilder<SdkVmConfigExecutor>,
    ) -> Result<(), ExecutorInventoryError> {
        inventory.add_phantom_sub_executor(DivRemHintSubEx, DIVREM_PHANTOM)
    }
}

impl TranspilerExtension for DivRemHint {
    fn process_custom(&self, stream: &[u32]) -> Option<TranspilerOutput> {
        let (rd, rs1) = decode(*stream.first()?)?;
        Some(TranspilerOutput::one_to_one(Instruction::phantom(
            DIVREM_PHANTOM,
            InstructionOperand::from_usize(REGISTER_NUM_LIMBS * rd),
            InstructionOperand::from_usize(REGISTER_NUM_LIMBS * rs1),
            0,
        )))
    }
}

/// The SDK configuration plus the hint. Its AIRs are the SDK configuration's, so a proof
/// verifies against the same keys.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RunnerVmConfig(pub SdkVmConfig);

impl AsRef<SystemConfig> for RunnerVmConfig {
    fn as_ref(&self) -> &SystemConfig {
        self.0.as_ref()
    }
}

impl AsMut<SystemConfig> for RunnerVmConfig {
    fn as_mut(&mut self) -> &mut SystemConfig {
        self.0.as_mut()
    }
}

impl InitFileGenerator for RunnerVmConfig {
    fn generate_init_file_contents(&self) -> Option<String> {
        self.0.generate_init_file_contents()
    }
}

impl<F> VmExecutionConfig<F> for RunnerVmConfig
where
    SdkVmConfig: VmExecutionConfig<F, Executor = SdkVmConfigExecutor>,
{
    type Executor = SdkVmConfigExecutor;

    fn create_executors(&self) -> Result<ExecutorInventory<SdkVmConfigExecutor>, ExecutorInventoryError> {
        self.0.create_executors()?.extend::<SdkVmConfigExecutor, _>(&DivRemHint)
    }
}

impl<SC: StarkProtocolConfig> VmCircuitConfig<SC> for RunnerVmConfig
where
    SdkVmConfig: VmCircuitConfig<SC>,
{
    fn create_airs(&self) -> Result<AirInventory<SC>, AirInventoryError> {
        self.0.create_airs()
    }
}

impl TranspilerConfig for RunnerVmConfig {
    fn transpiler(&self) -> Transpiler {
        self.0.transpiler().with_extension(DivRemHint)
    }
}

type SC = BabyBearPoseidon2Config;

#[derive(Clone, Copy, Default)]
pub struct RunnerVmCpuBuilder;

impl<E> VmBuilder<E> for RunnerVmCpuBuilder
where
    E: StarkEngine<SC = SC, PB = CpuBackend<SC>, PD = CpuDevice<SC>>,
{
    type VmConfig = RunnerVmConfig;
    type SystemChipInventory = SystemChipInventory<SC>;

    fn create_chip_complex(
        &self,
        config: &RunnerVmConfig,
        circuit: AirInventory<SC>,
        device_ctx: &openvm_stark_backend::EngineDeviceCtx<E>,
    ) -> Result<VmChipComplex<SC, E::PB, Self::SystemChipInventory>, ChipInventoryError> {
        VmBuilder::<E>::create_chip_complex(&SdkVmCpuBuilder, &config.0, circuit, device_ctx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn le(x: &BigUint, len: usize) -> Vec<u8> {
        let mut v = x.to_bytes_le();
        v.resize(len, 0);
        v
    }

    fn hint_of(n: &BigUint, d: &BigUint) -> (BigUint, BigUint) {
        let h = divrem_hint(&le(n, 64), &le(d, 32));
        (BigUint::from_bytes_le(&h[..32]), BigUint::from_bytes_le(&h[32..]))
    }

    #[test]
    fn divides_a_512_bit_numerator() {
        let max = (BigUint::from(1u8) << 256u32) - 1u8;
        let bn254 = BigUint::parse_bytes(
            b"21888242871839275222246405745257275088548364400416034343698204186575808495617",
            10,
        )
        .unwrap();
        let n = (&bn254 - 1u8) * (&bn254 - 2u8);
        assert_eq!(hint_of(&n, &bn254), (&n / &bn254, &n % &bn254));
        let n = &max * &max;
        assert_eq!(hint_of(&n, &max), (max.clone(), BigUint::default()));
    }

    #[test]
    fn truncates_a_wide_quotient_and_zeroes_a_zero_divisor() {
        let n = (BigUint::from(1u8) << 511u32) + 12345u32;
        let d = BigUint::from(3u8);
        let (q, r) = hint_of(&n, &d);
        assert_eq!(q, (&n / &d) % (BigUint::from(1u8) << 256u32));
        assert_eq!(r, &n % &d);
        assert_eq!(hint_of(&n, &BigUint::default()), (BigUint::default(), BigUint::default()));
    }

    #[test]
    fn decodes_only_its_own_encoding() {
        // .insn i 0x0b, 0b011, a0, a1, 0x4d1
        let insn = (DIVREM_IMM << 20) | (11 << 15) | (PHANTOM_FUNCT3 << 12) | (10 << 7) | SYSTEM_OPCODE;
        assert_eq!(decode(insn), Some((10, 11)));
        // HintInput, PrintStr and HintRandom stay with the RV64 transpiler.
        for imm in 0..=2 {
            assert_eq!(decode((imm << 20) | (PHANTOM_FUNCT3 << 12) | SYSTEM_OPCODE), None);
        }
        // HINT_BUFFER shares the opcode but not the funct3.
        assert_eq!(decode((1 << 20) | (0b001 << 12) | SYSTEM_OPCODE), None);
    }
}
