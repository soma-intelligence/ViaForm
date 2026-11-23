//! Stabilization gains tuned on the realistic plant (realism.rs), half velocity tracking and half
//! disturbance rejection, with either rate loop. Retuned 2026-11-04 after the rotor-drag fix with
//! `cargo run --release -p viaform-sim --example train_stable -- [iterations]` (tune_gains on
//! realistic_scenario, rateIntMax 50). Held-out cost on 40 scenarios (lower is better): default PID
//! 32.18399, first training 3.30213, retuned PID 3.05292 (16 iterations, was 4.31616), retuned
//! INDI 1.75587 (60 iterations, was 1.76708). The 60-iteration PID scored 1.76355 but recovered
//! only 2 or 3 of 6 kicks on the stress bench, so the 16-iteration PID is kept.

use crate::control::Gains;

pub const STABLE_PID: Gains = Gains { pos_p: 2.28456, vel_p: 12.08444, vel_i: 0.8031, vel_d: 0.05655, att_p: 25.7604, yaw_p: 4.7534, rate_p: 49.21792, rate_i: 20.56047, rate_d: 0.00626, yaw_rate_p: 7.14565 };

pub const STABLE_INDI: Gains = Gains { pos_p: 2.08985, vel_p: 10.42253, vel_i: 6.33156, vel_d: 0.0693, att_p: 16.66552, yaw_p: 1.89038, rate_p: 43.65244, rate_i: 17.59295, rate_d: 0.00899, yaw_rate_p: 7.51252 };

/// Held-out cost: default PID, first training, retuned PID, retuned INDI.
pub const STABLE_SCORE: [f64; 4] = [32.18399, 3.30213, 3.05292, 1.75587];
