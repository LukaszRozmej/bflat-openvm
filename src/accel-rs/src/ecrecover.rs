// SPDX-FileCopyrightText: 2026 Demerzel Solutions Limited
// SPDX-License-Identifier: MIT

//! `zkvm_secp256k1_ecrecover`, replacing openvm-eth's.
//!
//! openvm-eth recovers through the OpenVM k256 fork, whose `msm` builds a
//! window-4 table of both G and R and then doubles through all 256 bits of
//! u1 and u2: ~254 `SW_DOUBLE` and ~145 `SW_ADD_NE` per recovery, plus up to
//! five `IS_EQ` per addition for its complete-addition checks. This computes
//! the same point with one shared doubling chain over four half-length
//! scalars:
//!
//! - GLV: u = a + b*lambda (mod n) with |a|, |b| < 2^128, and
//!   lambda*(x, y) = (beta*x, y), so u1*G + u2*R becomes a four-term sum
//!   whose doubling chain is ~129 steps instead of 256;
//! - wNAF digits, window 8 against constant tables of odd multiples of G
//!   and lambda*G and of their negations, window 5 against odd multiples of
//!   R and lambda*R built per call.
//!
//! `SW_ADD_NE` is incomplete: it constrains lambda*(x2 - x1) = y2 - y1, which
//! any lambda satisfies when the two points are equal. Every input here is
//! caller-chosen (the 0x01 precompile takes any hash, r and s, so a caller
//! picks u1, u2 and R outright), so each accumulator addition first compares
//! x through `IS_EQ`, which also proves both operands reduced, and handles
//! the equal and opposite cases itself. The accumulator's infinity is a flag,
//! never a point handed to the chips.
//!
//! The inverse of r is the native constrained division. The square root
//! comes from the algebra extension's verified hint (`Sqrt::sqrt`).

use openvm_algebra_guest::{DivUnsafe, IntMod, Sqrt};
use openvm_ecc_guest::weierstrass::WeierstrassPoint;
use openvm_k256::{Secp256k1Coord as Coord, Secp256k1Point as Point, Secp256k1Scalar as Scalar};

use crate::secp256k1_tables::{G_TABLE, LAMBDA_G_TABLE, NEG_G_TABLE, NEG_LAMBDA_G_TABLE, WINDOW_G};

type Limbs = [u64; 4];

const WINDOW_R: u32 = 5;
const R_ENTRIES: usize = 1 << (WINDOW_R - 2);
/// Scalars are at most 256 bits; one more position absorbs the final wNAF carry.
const MAX_DIGITS: usize = 257;

const FIELD_P: Limbs = [0xfffffffefffffc2f, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff];
const ORDER_N: Limbs = [0xbfd25e8cd0364141, 0xbaaedce6af48a03b, 0xfffffffffffffffe, 0xffffffffffffffff];
const HALF_N: Limbs = [0xdfe92f46681b20a0, 0x5d576e7357a4501d, 0xffffffffffffffff, 0x7fffffffffffffff];

/// GLV decomposition constants (as in libsecp256k1's secp256k1_scalar_split_lambda).
const GLV_G1: Limbs = [0xe893209a45dbb031, 0x3daa8a1471e8ca7f, 0xe86c90e49284eb15, 0x3086d221a7d46bcd];
const GLV_G2: Limbs = [0x1571b4ae8ac47f71, 0x221208ac9df506c6, 0x6f547fa90abfe4c4, 0xe4437ed6010e8828];
const MINUS_B1: Scalar =
    Scalar::from_const_bytes(le_bytes([0x6f547fa90abfe4c3, 0xe4437ed6010e8828, 0, 0]));
const MINUS_B2: Scalar = Scalar::from_const_bytes(le_bytes([
    0xd765cda83db1562c,
    0x8a280ac50774346d,
    0xfffffffffffffffe,
    0xffffffffffffffff,
]));
const MINUS_LAMBDA: Scalar = Scalar::from_const_bytes(le_bytes([
    0xe0cfc810b51283cf,
    0xa880b9fc8ec739c2,
    0x5ad9e3fd77ed9ba4,
    0xac9c52b33fa3cf1f,
]));
const BETA: Coord = Coord::from_const_bytes(le_bytes([
    0xc1396c28719501ee,
    0x9cf0497512f58995,
    0x6e64479eac3434e9,
    0x7ae96a2b657c0710,
]));
const SEVEN: Coord = Coord::from_const_bytes(le_bytes([7, 0, 0, 0]));

const fn le_bytes(limbs: Limbs) -> [u8; 32] {
    let mut bytes = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        bytes[i] = (limbs[i / 8] >> (8 * (i % 8))) as u8;
        i += 1;
    }
    bytes
}

/// The limbs of a coordinate or scalar, both 32 little-endian bytes aligned to 32.
#[inline(always)]
fn limbs<T: IntMod<Repr = [u8; 32]>>(value: &T) -> &Limbs {
    // SAFETY: the moduli macros declare both types `repr(C, align(32))` over `[u8; 32]`.
    unsafe { &*(value as *const T as *const Limbs) }
}

#[inline(always)]
fn from_limbs<T: IntMod<Repr = [u8; 32]>>(limbs: Limbs) -> T {
    // SAFETY: [u64; 4] and [u8; 32] have the same size, and the target is little-endian.
    T::from_repr(unsafe { core::mem::transmute::<Limbs, [u8; 32]>(limbs) })
}

fn is_zero(a: &Limbs) -> bool {
    (a[0] | a[1] | a[2] | a[3]) == 0
}

fn less_than(a: &Limbs, b: &Limbs) -> bool {
    for i in (0..4).rev() {
        if a[i] != b[i] {
            return a[i] < b[i];
        }
    }
    false
}

/// r = a + b, returning the carry out.
fn add_carry(r: &mut Limbs, a: &Limbs, b: &Limbs) -> bool {
    let mut carry = false;
    for i in 0..4 {
        let (s, c1) = a[i].overflowing_add(b[i]);
        let (s, c2) = s.overflowing_add(carry as u64);
        r[i] = s;
        carry = c1 | c2;
    }
    carry
}

/// a - b for a >= b.
fn sub(a: &Limbs, b: &Limbs) -> Limbs {
    let mut r = [0u64; 4];
    let mut borrow = false;
    for i in 0..4 {
        let (d, b1) = a[i].overflowing_sub(b[i]);
        let (d, b2) = d.overflowing_sub(borrow as u64);
        r[i] = d;
        borrow = b1 | b2;
    }
    r
}

fn load_be(bytes: &[u8]) -> Limbs {
    let mut r = [0u64; 4];
    for (i, limb) in r.iter_mut().enumerate() {
        let at = 24 - 8 * i;
        *limb = u64::from_be_bytes(bytes[at..at + 8].try_into().unwrap());
    }
    r
}

fn store_be(bytes: &mut [u8], a: &Limbs) {
    for (i, limb) in a.iter().enumerate() {
        let at = 24 - 8 * i;
        bytes[at..at + 8].copy_from_slice(&limb.to_be_bytes());
    }
}

/// p = 2p. The caller guarantees p is not infinity; 2p never is, since the
/// group order is odd.
#[inline(always)]
fn double(p: &mut Point) {
    #[cfg(not(any(openvm_intrinsics, target_os = "openvm")))]
    host::check_double(p);
    // SAFETY: Point::set_up_once ran in recover.
    unsafe { p.double_assign_nonidentity::<false>() }
}

/// p += q for points other than infinity with distinct x.
#[inline(always)]
fn add_ne(p: &mut Point, q: &Point) {
    #[cfg(not(any(openvm_intrinsics, target_os = "openvm")))]
    host::check_add(p, q);
    // SAFETY: Point::set_up_once ran in recover.
    unsafe { p.add_ne_assign_nonidentity::<false>(q) }
}

/// a == b through `IS_EQ`, which only completes for reduced operands.
#[inline(always)]
fn coord_eq(a: &Coord, b: &Coord) -> bool {
    #[cfg(not(any(openvm_intrinsics, target_os = "openvm")))]
    host::check_reduced(a, b);
    // SAFETY: Point::set_up_once ran in recover, and it sets up Coord.
    unsafe { <Coord as IntMod>::eq_impl::<false>(a, b) }
}

#[inline(always)]
fn sqrt(a: &Coord) -> Option<Coord> {
    #[cfg(any(openvm_intrinsics, target_os = "openvm"))]
    {
        a.sqrt()
    }
    #[cfg(not(any(openvm_intrinsics, target_os = "openvm")))]
    {
        host::sqrt(a)
    }
}

/// r = floor(a * b / 2^384 + 1/2), the GLV rounding step.
fn mul_shift_384(a: &Limbs, b: &Limbs) -> Limbs {
    let mut product = [0u64; 8];
    for i in 0..4 {
        let mut carry = 0u64;
        for j in 0..4 {
            let t = (a[i] as u128) * (b[j] as u128) + product[i + j] as u128 + carry as u128;
            product[i + j] = t as u64;
            carry = (t >> 64) as u64;
        }
        product[i + 4] = carry;
    }
    let round = product[5] >> 63;
    let (low, carry) = product[6].overflowing_add(round);
    let (high, carry) = product[7].overflowing_add(carry as u64);
    [low, high, carry as u64, 0]
}

/// A GLV half: the magnitude of k1 or k2, and whether it is negative.
struct Half {
    magnitude: Limbs,
    negative: bool,
}

impl Half {
    /// Takes a reduced scalar k to the representative of least magnitude.
    fn new(k: Scalar) -> Self {
        let k = limbs(&k);
        if less_than(&HALF_N, k) {
            Half { magnitude: sub(&ORDER_N, k), negative: true }
        } else {
            Half { magnitude: *k, negative: false }
        }
    }
}

/// Splits k into k1 + k2*lambda (mod n). The halves are below 2^128 for a
/// reduced k (libsecp256k1 proves it); for an unreduced one they are still
/// congruent, only longer, and nothing below relies on the bound beyond cost.
fn split_lambda(k: &Scalar) -> (Half, Half) {
    let c1: Scalar = from_limbs(mul_shift_384(limbs(k), &GLV_G1));
    let c2: Scalar = from_limbs(mul_shift_384(limbs(k), &GLV_G2));
    let k2 = &(&c1 * &MINUS_B1) + &(&c2 * &MINUS_B2);
    let k1 = &(&k2 * &MINUS_LAMBDA) + k;
    // The sign tests and negations below read the integers, so both must be
    // the canonical representatives.
    k1.assert_reduced();
    k2.assert_reduced();
    (Half::new(k1), Half::new(k2))
}

fn bit_length(a: &Limbs) -> usize {
    for i in (0..4).rev() {
        if a[i] != 0 {
            return 64 * i + 64 - a[i].leading_zeros() as usize;
        }
    }
    0
}

/// Writes the width-w NAF of s into byte `lane` of digits[i] for i < len: odd
/// digits in (-2^(w-1), 2^(w-1)), at least w - 1 zeros between two of them.
/// len must exceed the bit length of s for the last carry to land inside it.
fn wnaf(digits: &mut [u32; MAX_DIGITS], lane: u32, s: &Limbs, w: u32, len: usize) {
    let bit_at = |bit: usize| -> u64 {
        if bit < 256 {
            (s[bit >> 6] >> (bit & 63)) & 1
        } else {
            0
        }
    };
    let mut bit = 0;
    let mut carry = 0u64;
    while bit < len {
        if bit_at(bit) == carry {
            bit += 1;
            continue;
        }
        let now = core::cmp::min(len - bit, w as usize) as u32;
        let mut bits = 0u64;
        if bit < 256 {
            bits = s[bit >> 6] >> (bit & 63);
            if (bit & 63) + now as usize > 64 && bit + 64 < 256 {
                bits |= s[(bit >> 6) + 1] << (64 - (bit & 63));
            }
        }
        let mut word = (bits & ((1u64 << now) - 1)) as i32 + carry as i32;
        carry = ((word as u32) >> (w - 1)) as u64 & 1;
        word -= (carry << w) as i32;
        digits[bit] |= ((word as u8) as u32) << (8 * lane);
        bit += now as usize;
    }
}

/// The constant odd multiples of a base and of its negation, ordered by the
/// sign of the GLV half they multiply: `[0]` serves positive digits.
fn signed<'a>(base: &'a [Point], negated: &'a [Point], half: &Half) -> [&'a [Point]; 2] {
    if half.negative {
        [negated, base]
    } else {
        [base, negated]
    }
}

/// The entry of `table` for a nonzero wNAF digit, negated into `scratch` when
/// the digit's sign disagrees with the half's.
#[inline(always)]
fn signed_entry<'a>(table: &'a [Point], scratch: &'a mut Point, digit: i8, negative: bool) -> &'a Point {
    let entry = &table[(digit.unsigned_abs() >> 1) as usize];
    if negative == (digit < 0) {
        return entry;
    }
    scratch.clone_from(entry);
    scratch.y_mut().neg_assign();
    scratch
}

/// acc += q, with acc's infinity tracked in `infinity`.
#[inline(always)]
fn accumulate(acc: &mut Point, infinity: &mut bool, q: &Point) {
    if *infinity {
        *acc = q.clone();
        *infinity = false;
    } else if coord_eq(acc.x(), q.x()) {
        if coord_eq(acc.y(), q.y()) {
            double(acc);
        } else {
            *infinity = true;
        }
    } else {
        add_ne(acc, q);
    }
}

/// The uncompressed public key (x | y, big-endian) that signed `msg`, or None
/// where ecrecover fails: r or s outside [1, n - 1], a recovery id above 3,
/// an x coordinate (r, or r + n for ids 2 and 3) at or above p or off the
/// curve, or a key at infinity. High s is accepted, as openvm-eth does.
pub fn recover(msg: &[u8; 32], sig: &[u8; 64], recid: u8) -> Option<[u8; 64]> {
    if recid > 3 {
        return None;
    }
    let r = load_be(&sig[..32]);
    let s = load_be(&sig[32..]);
    if is_zero(&r) || !less_than(&r, &ORDER_N) || is_zero(&s) || !less_than(&s, &ORDER_N) {
        return None;
    }

    // Recovery ids 2 and 3 name the point whose x coordinate is r + n.
    let mut x = r;
    if recid & 2 != 0 && (add_carry(&mut x, &r, &ORDER_N) || !less_than(&x, &FIELD_P)) {
        return None;
    }

    <Point as WeierstrassPoint>::set_up_once();

    let x: Coord = from_limbs(x);
    // x^3 + 7 is never 0: a point with y = 0 would have order 2, and the group
    // order is an odd prime. So the root is nonzero and p - y has the other
    // parity, computed on the integers to stay canonical.
    let mut y = *limbs(&sqrt(&(&(&x * &x) * &x + &SEVEN))?);
    if (y[0] & 1) as u8 != recid & 1 {
        y = sub(&FIELD_P, &y);
    }
    // SAFETY: y^2 = x^3 + 7 was checked by the square root.
    let point_r = unsafe { Point::from_xy_unchecked(x, from_limbs(y)) };

    // Q = u1*G + u2*R with u1 = -z/r and u2 = s/r. The hash is below 2^256 < 2n.
    let mut z = load_be(msg);
    if !less_than(&z, &ORDER_N) {
        z = sub(&z, &ORDER_N);
    }
    let r: Scalar = from_limbs(r);
    let z: Scalar = from_limbs(z);
    let u1 = (&Scalar::ZERO - &z).div_unsafe(&r);
    let u2 = from_limbs::<Scalar>(s).div_unsafe(&r);
    let (g, lambda_g) = split_lambda(&u1);
    let (r_half, lambda_r) = split_lambda(&u2);

    // Odd multiples R, 3R, ..., 15R and their lambda images. No addition here
    // can meet equal x: jR = +-2R would need (j -+ 2)R = 0, and R has prime
    // order n.
    let mut twice_r = point_r.clone();
    double(&mut twice_r);
    let mut r_table: [Point; R_ENTRIES] = core::array::from_fn(|_| point_r.clone());
    for i in 1..R_ENTRIES {
        let (done, rest) = r_table.split_at_mut(i);
        rest[0] = done[i - 1].clone();
        add_ne(&mut rest[0], &twice_r);
    }
    let lambda_r_table: [Point; R_ENTRIES] = core::array::from_fn(|i| {
        // SAFETY: (beta*x, y) is lambda times a point on the curve.
        unsafe { Point::from_xy_unchecked(r_table[i].x() * &BETA, r_table[i].y().clone()) }
    });

    let halves = [&g, &lambda_g, &r_half, &lambda_r];
    let length = 1 + halves.iter().map(|h| bit_length(&h.magnitude)).max().unwrap_or(0);

    // Digit j of position i is byte j of digits[i], so a position where all
    // four digits are zero costs one load.
    let mut digits = [0u32; MAX_DIGITS];
    wnaf(&mut digits, 0, &g.magnitude, WINDOW_G, length);
    wnaf(&mut digits, 1, &lambda_g.magnitude, WINDOW_G, length);
    wnaf(&mut digits, 2, &r_half.magnitude, WINDOW_R, length);
    wnaf(&mut digits, 3, &lambda_r.magnitude, WINDOW_R, length);

    let g_tables = signed(&G_TABLE, &NEG_G_TABLE, &g);
    let lambda_g_tables = signed(&LAMBDA_G_TABLE, &NEG_LAMBDA_G_TABLE, &lambda_g);
    let mut scratch = point_r.clone();
    let mut acc = point_r;
    let mut infinity = true;
    for i in (0..length).rev() {
        if !infinity {
            double(&mut acc);
        }
        let d = digits[i];
        if d == 0 {
            continue;
        }
        let digit = d as i8;
        if digit != 0 {
            let q = &g_tables[(digit < 0) as usize][(digit.unsigned_abs() >> 1) as usize];
            accumulate(&mut acc, &mut infinity, q);
        }
        let digit = (d >> 8) as i8;
        if digit != 0 {
            let q = &lambda_g_tables[(digit < 0) as usize][(digit.unsigned_abs() >> 1) as usize];
            accumulate(&mut acc, &mut infinity, q);
        }
        let digit = (d >> 16) as i8;
        if digit != 0 {
            let q = signed_entry(&r_table, &mut scratch, digit, r_half.negative);
            accumulate(&mut acc, &mut infinity, q);
        }
        let digit = (d >> 24) as i8;
        if digit != 0 {
            let q = signed_entry(&lambda_r_table, &mut scratch, digit, lambda_r.negative);
            accumulate(&mut acc, &mut infinity, q);
        }
    }

    if infinity {
        return None;
    }
    acc.x().assert_reduced();
    acc.y().assert_reduced();
    let mut key = [0u8; 64];
    store_be(&mut key[..32], limbs(acc.x()));
    store_be(&mut key[32..], limbs(acc.y()));
    Some(key)
}

/// # Safety
///
/// Every non-NULL pointer must be valid for a read or write of its pointed-to
/// size. `output` is written only on success, after both inputs are read, so
/// it may overlap them.
#[no_mangle]
pub unsafe extern "C" fn bflat_secp256k1_ecrecover(
    msg: *const [u8; 32],
    sig: *const [u8; 64],
    recid: u8,
    output: *mut [u8; 64],
) -> core::ffi::c_int {
    if msg.is_null() || sig.is_null() || output.is_null() {
        return -1;
    }
    let (msg, sig) = (msg.read_unaligned(), sig.read_unaligned());
    match recover(&msg, &sig, recid) {
        Some(key) => {
            output.write_unaligned(key);
            0
        }
        None => -1,
    }
}

/// Host stand-ins for what the chips enforce, so a host build fails where the
/// guest could not be proven, and counts the curve operations.
#[cfg(not(any(openvm_intrinsics, target_os = "openvm")))]
pub mod host {
    use core::sync::atomic::{AtomicUsize, Ordering};

    use openvm_algebra_guest::{ExpBytes, IntMod};
    use openvm_ecc_guest::weierstrass::WeierstrassPoint;

    use super::{Coord, Point, SEVEN};

    pub static DOUBLES: AtomicUsize = AtomicUsize::new(0);
    pub static ADDS: AtomicUsize = AtomicUsize::new(0);

    fn check_on_curve(p: &Point) {
        assert!(p.x().is_reduced() && p.y().is_reduced(), "unreduced point");
        assert!(p.y() * p.y() == &(p.x() * p.x()) * p.x() + &SEVEN, "point off the curve or at infinity");
    }

    pub fn check_double(p: &Point) {
        check_on_curve(p);
        DOUBLES.fetch_add(1, Ordering::Relaxed);
    }

    pub fn check_add(p: &Point, q: &Point) {
        check_on_curve(p);
        check_on_curve(q);
        assert!(p.x() != q.x(), "SW_ADD_NE with equal x");
        ADDS.fetch_add(1, Ordering::Relaxed);
    }

    pub fn check_reduced(a: &Coord, b: &Coord) {
        assert!(a.is_reduced() && b.is_reduced(), "IS_EQ on an unreduced operand");
    }

    /// (p + 1) / 4, big-endian.
    const SQRT_EXPONENT: [u8; 32] = [
        0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xbf, 0xff, 0xff, 0x0c,
    ];

    pub fn sqrt(a: &Coord) -> Option<Coord> {
        let y = a.exp_bytes(true, &SQRT_EXPONENT);
        (&y * &y == *a).then_some(y)
    }

    /// The GLV halves of a big-endian scalar, each as a big-endian magnitude
    /// and a sign.
    pub fn split_be(k: &[u8; 32]) -> (([u8; 32], bool), ([u8; 32], bool)) {
        let (k1, k2) = super::split_lambda(&super::from_limbs(super::load_be(k)));
        let be = |half: &super::Half| {
            let mut bytes = [0u8; 32];
            super::store_be(&mut bytes, &half.magnitude);
            (bytes, half.negative)
        };
        (be(&k1), be(&k2))
    }
}
