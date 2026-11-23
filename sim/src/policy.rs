//! The learned part of the controller: a small neural network that adds a correction to the
//! acceleration the PID cascade asks for. It sees what the PID loops see plus an estimate of the
//! outside force (what the accelerometer measures minus what the motors were told to push), so it
//! can learn to cancel gusts before the integrator catches up. Trained by evolution strategies
//! (train.rs), the reinforcement learning method of Salimans et al. 2017: no gradients of the
//! simulator needed, and the same reward as any RL setup.

use crate::math::*;

pub const POLICY_INPUTS: usize = 17;
pub const POLICY_HIDDEN: usize = 16;
pub const POLICY_OUTPUTS: usize = 3;
pub const POLICY_SIZE: usize = POLICY_INPUTS * POLICY_HIDDEN + POLICY_HIDDEN + POLICY_HIDDEN * POLICY_OUTPUTS + POLICY_OUTPUTS;
/// Largest correction (m/s²) the network may add on each axis.
pub const POLICY_AUTHORITY: f64 = 4.0;

#[derive(Clone, Debug)]
pub struct Policy {
    pub theta: Vec<f64>,
}

impl Policy {
    pub fn new(theta: Vec<f64>) -> Self {
        assert_eq!(theta.len(), POLICY_SIZE);
        Policy { theta }
    }

    /// All inputs in the heading frame (yaw removed), so what it learns does not depend on which
    /// way the drone faces.
    pub fn act(&self, x: &[f64; POLICY_INPUTS]) -> V3 {
        let th = &self.theta;
        let mut h = [0.0; POLICY_HIDDEN];
        let mut k = 0;
        for hj in h.iter_mut() {
            let mut s = 0.0;
            for xi in x {
                s += th[k] * xi;
                k += 1;
            }
            *hj = s;
        }
        for hj in h.iter_mut() {
            *hj = (*hj + th[k]).tanh();
            k += 1;
        }
        let mut out = [0.0; 3];
        for o in out.iter_mut() {
            let mut s = 0.0;
            for hj in &h {
                s += th[k] * hj;
                k += 1;
            }
            *o = s;
        }
        for o in out.iter_mut() {
            *o = POLICY_AUTHORITY * (*o + th[k]).tanh();
            k += 1;
        }
        out
    }
}

pub struct PolicyIn {
    pub vel_err: V3,
    pub v: V3,
    pub force: V3,
    pub tilt: [f64; 2],
    pub w: V3,
    pub vel_int: V3,
    pub heading: f64,
}

/// The network's input vector. Everything rotated into the heading frame (c, s: cos and sin of
/// the heading) and scaled to about unit size.
pub fn policy_input(o: &PolicyIn) -> [f64; POLICY_INPUTS] {
    let (c, s) = (o.heading.cos(), o.heading.sin());
    let h = |a: V3, k: f64| [clamp((c * a[0] + s * a[1]) * k, -3.0, 3.0), clamp((-s * a[0] + c * a[1]) * k, -3.0, 3.0), clamp(a[2] * k, -3.0, 3.0)];
    let mut x = [0.0; POLICY_INPUTS];
    let parts: [&[f64]; 6] = [&h(o.vel_err, 0.5), &h(o.v, 0.25), &h(o.force, 0.2), &[o.tilt[0] * 2.0, o.tilt[1] * 2.0], &o.w.map(|v| clamp(v * 0.3, -3.0, 3.0)), &h(o.vel_int, 0.3)];
    let mut i = 0;
    for p in parts {
        for v in p {
            x[i] = *v;
            i += 1;
        }
    }
    x
}
