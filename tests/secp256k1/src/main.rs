// SPDX-FileCopyrightText: 2026 Demerzel Solutions Limited
// SPDX-License-Identifier: MIT

//! Host harness for src/accel-rs/src/ecrecover.rs.
//!
//! stdin, one command per line:
//!   recover <msg hex32> <sig hex64> <recid>
//!       -> "ok <pubkey hex64> <doubles> <adds>" or "fail <doubles> <adds>"
//!   split <k hex32>
//!       -> "<k1 hex32> <neg1> <k2 hex32> <neg2>"

#[path = "../../../src/accel-rs/src/ecrecover.rs"]
mod ecrecover;
#[path = "../../../src/accel-rs/src/secp256k1_tables.rs"]
mod secp256k1_tables;

use std::io::{BufRead, Write};
use std::sync::atomic::Ordering;

use ecrecover::host::{ADDS, DOUBLES};

fn parse_hex<const N: usize>(text: &str) -> [u8; N] {
    assert_eq!(text.len(), 2 * N, "expected {N} hex bytes");
    core::array::from_fn(|i| u8::from_str_radix(&text[2 * i..2 * i + 2], 16).unwrap())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn main() {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let fields: Vec<&str> = line.split_whitespace().collect();
        match fields.as_slice() {
            ["recover", msg, sig, recid] => {
                let msg = parse_hex::<32>(msg);
                let sig = parse_hex::<64>(sig);
                let recid: u8 = recid.parse().unwrap();
                DOUBLES.store(0, Ordering::Relaxed);
                ADDS.store(0, Ordering::Relaxed);
                let untouched = [0x55u8; 64];
                let mut key = untouched;
                let status = unsafe { ecrecover::bflat_secp256k1_ecrecover(&msg, &sig, recid, &mut key) };
                let (doubles, adds) = (DOUBLES.load(Ordering::Relaxed), ADDS.load(Ordering::Relaxed));
                match status {
                    0 => writeln!(out, "ok {} {doubles} {adds}", hex(&key)),
                    -1 => {
                        assert_eq!(key, untouched, "output written on failure");
                        writeln!(out, "fail {doubles} {adds}")
                    }
                    other => panic!("status {other}"),
                }
                .unwrap();
            }
            ["split", k] => {
                let (k1, k2) = ecrecover::host::split_be(&parse_hex::<32>(k));
                writeln!(out, "{} {} {} {}", hex(&k1.0), k1.1 as u8, hex(&k2.0), k2.1 as u8).unwrap();
            }
            _ => panic!("bad command: {line}"),
        }
    }
}
