//! PH6: batched stepping. N worlds in parallel are bitwise equal to the same worlds stepped
//! one after another, and the throughput of the 6-axis arm (servos on every joint) at 1 kHz.
//! `cargo test --release -p viaform-phys --test ph6_batch -- --nocapture` prints the numbers.

use std::time::Instant;

use viaform_kin::math::{Rng, pose_xyz_rpy};
use viaform_kin::models;
use viaform_phys::actuator::{ActuatorKind, ServoParams};
use viaform_phys::batch::Batch;
use viaform_phys::{ModelBuilder, Settings, ShapeSpec, World};

/// The SO-101 class arm (six revolute joints) with STS3215 class servos; with `cube`, a ground
/// plane and a 30 mm cube resting on it (four contact points every step).
fn arm_world(cube: bool) -> World {
    let kin = models::so101_arm();
    let na = kin.actuators.len();
    let mut b = ModelBuilder::new(kin);
    for a in 0..na {
        b.actuator(a, ActuatorKind::Servo(ServoParams::default()));
    }
    if cube {
        b.ground(0.8);
        b.free_shape("cube", ShapeSpec::Box { size: [0.03; 3] }, 0.03, pose_xyz_rpy([0.25, 0.1, 0.015], [0.0; 3]), 0.8).unwrap();
    }
    let mut w = World::new(b.build().unwrap(), Settings::default());
    w.run(10).unwrap();
    w
}

fn targets(rng: &mut Rng, n: usize, na: usize) -> Vec<f64> {
    (0..n * na).map(|_| rng.range(-0.8, 0.8)).collect()
}

#[test]
fn batch_is_deterministic() {
    let w = arm_world(true);
    let mut a = Batch::from_world(&w, 64);
    let mut b = Batch::from_world(&w, 64);
    let mut rng = Rng::new(9);
    for _ in 0..5 {
        let c = targets(&mut rng, 64, a.na());
        a.set_controls(&c).unwrap();
        b.set_controls(&c).unwrap();
        a.step(40).unwrap();
        b.step_serial(40).unwrap();
    }
    let (qa, qb) = (a.q_flat(), b.q_flat());
    assert!(qa.iter().zip(&qb).all(|(x, y)| x.to_bits() == y.to_bits()));
    // And a second parallel run gives the same bits.
    let mut c = Batch::from_world(&w, 64);
    let mut rng = Rng::new(9);
    for _ in 0..5 {
        let t = targets(&mut rng, 64, c.na());
        c.set_controls(&t).unwrap();
        c.step(40).unwrap();
    }
    assert!(c.q_flat().iter().zip(&qa).all(|(x, y)| x.to_bits() == y.to_bits()));
    println!("PH6 64 arms with a cube, 200 steps: parallel, serial and a second parallel run bitwise equal");
}

fn throughput(cube: bool, n: usize, steps: usize) -> f64 {
    let w = arm_world(cube);
    let mut batch = Batch::from_world(&w, n);
    let mut rng = Rng::new(1);
    let c = targets(&mut rng, n, batch.na());
    batch.set_controls(&c).unwrap();
    batch.step(20).unwrap();
    let t0 = Instant::now();
    let mut done = 0;
    while done < steps {
        let c = targets(&mut rng, n, batch.na());
        batch.set_controls(&c).unwrap();
        batch.step(50).unwrap();
        done += 50;
    }
    let rate = (n * done) as f64 / t0.elapsed().as_secs_f64();
    // The arms are moving: mean joint speed and mean servo effort.
    let w0 = &batch.worlds[0];
    let speed = batch.v_flat().iter().map(|x| x.abs()).sum::<f64>() / (n * w0.v.len()) as f64;
    let effort = batch.worlds.iter().flat_map(|w| w.act.iter().map(|a| a.effort.abs())).sum::<f64>() / (n * w0.act.len()) as f64;
    let iters = batch.worlds.iter().map(|w| w.stats.iterations as f64).sum::<f64>() / n as f64;
    println!("PH6   (cube {cube}: mean |v| {speed:.3}, mean servo effort {effort:.3} N m, solver iterations last step {iters:.1})");
    rate
}

#[test]
fn arm_throughput() {
    let threads = rayon::current_num_threads();
    let single = {
        let mut w = arm_world(false);
        let t0 = Instant::now();
        w.run(20000).unwrap();
        20000.0 / t0.elapsed().as_secs_f64()
    };
    let free = throughput(false, 1024, 500);
    let with_cube = throughput(true, 1024, 500);
    println!("PH6 6-axis arm, 6 servos, 1 kHz: one world on one thread {single:.0} steps/s");
    println!("PH6 1024 arms on {threads} rayon threads: {free:.0} env steps/s (free space), {with_cube:.0} env steps/s (with a resting cube, 4 contacts); target 200000");
    assert!(free > 10_000.0);
}
