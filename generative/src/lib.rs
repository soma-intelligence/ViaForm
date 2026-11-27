//! ViaForm's generative design engine.
//!
//! A [`Spec`] describes a plate-shaped design space: where it is held, how it is loaded, what
//! must stay empty or solid, the material and how much of the space the part may fill. The engine
//! answers with candidates ([`Outcome`]), each a shape, its mass, stiffness, stress and outline,
//! and turns a candidate into SolidCraft commands ([`emit::commands`]) so every front end builds
//! it through the same command API as the rest of the design.
//!
//! Two methods:
//! - [`Method::Topology`]: SIMP topology optimisation on plane-stress elements ([`topology`]).
//! - [`Method::Frame`]: a ground structure of beams sized by an evolution strategy ([`frame`]).

pub mod emit;
pub mod frame;
pub mod geometry;
pub mod solid;
pub mod spec;
pub mod topology;

pub use spec::*;

/// Runs a study: one solver per variant, in parallel, then geometry and figures per candidate.
pub fn generate(spec: &Spec) -> Result<Outcome, String> {
    spec.validate()?;
    let n = spec.variants;
    let solved: Vec<Result<Solved, String>> = std::thread::scope(|scope| {
        let jobs: Vec<_> = (0..n)
            .map(|k| {
                scope.spawn(move || match spec.method {
                    Method::Topology => topology::solve(spec, variant_fraction(spec.volume_fraction, k, n)),
                    Method::Frame => frame::solve(spec, spec.seed.wrapping_add(k as u64 * 0x9E37_79B9)),
                })
            })
            .collect();
        jobs.into_iter().map(|j| j.join().unwrap_or_else(|_| Err("a solver panicked".into()))).collect()
    });
    let mut candidates = Vec::with_capacity(n);
    for (id, s) in solved.into_iter().enumerate() {
        let s = s?;
        let area = geometry::solid_area(&s.shape, spec);
        candidates.push(Candidate {
            id,
            method: spec.method,
            mass_g: area * spec.thickness * spec.material.density,
            compliance: s.compliance,
            max_stress: s.max_stress,
            max_displacement: s.max_displacement,
            volume_fraction: s.volume_fraction,
            feasible: s.max_stress.is_finite() && s.max_stress <= spec.material.allowable,
            history: s.history,
            outlines: geometry::outlines(&s.shape, spec),
            shape: s.shape,
        });
    }
    let best = best(&candidates);
    Ok(Outcome { candidates, best })
}

/// The volume fraction variant `k` of `n` aims for: spread ±30 % around the asked fraction.
fn variant_fraction(vf: f64, k: usize, n: usize) -> f64 {
    if n <= 1 {
        return vf;
    }
    let t = k as f64 / (n - 1) as f64;
    (vf * (0.7 + 0.6 * t)).clamp(0.05, 0.95)
}

/// The lightest feasible candidate, else the least stressed.
fn best(c: &[Candidate]) -> usize {
    let feasible = c.iter().filter(|c| c.feasible).min_by(|a, b| a.mass_g.total_cmp(&b.mass_g));
    feasible.or_else(|| c.iter().min_by(|a, b| a.max_stress.total_cmp(&b.max_stress))).map_or(0, |c| c.id)
}
