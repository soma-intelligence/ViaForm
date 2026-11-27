//! Velocity sets: D3Q19 for the flow, D3Q7 for the passive scalar.

/// Number of D3Q19 directions.
pub const Q: usize = 19;

/// D3Q19 velocities. Pairs (1,2), (3,4), ... are opposite.
pub const C: [[i32; 3]; Q] = [
    [0, 0, 0],
    [1, 0, 0],
    [-1, 0, 0],
    [0, 1, 0],
    [0, -1, 0],
    [0, 0, 1],
    [0, 0, -1],
    [1, 1, 0],
    [-1, -1, 0],
    [1, -1, 0],
    [-1, 1, 0],
    [1, 0, 1],
    [-1, 0, -1],
    [1, 0, -1],
    [-1, 0, 1],
    [0, 1, 1],
    [0, -1, -1],
    [0, 1, -1],
    [0, -1, 1],
];

/// The same velocities as `f64`.
pub const CF: [[f64; 3]; Q] = {
    let mut out = [[0.0; 3]; Q];
    let mut i = 0;
    while i < Q {
        out[i] = [C[i][0] as f64, C[i][1] as f64, C[i][2] as f64];
        i += 1;
    }
    out
};

/// D3Q19 weights.
pub const W: [f64; Q] = [
    1.0 / 3.0,
    1.0 / 18.0,
    1.0 / 18.0,
    1.0 / 18.0,
    1.0 / 18.0,
    1.0 / 18.0,
    1.0 / 18.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
    1.0 / 36.0,
];

/// Opposite direction of each D3Q19 direction.
pub const OPP: [usize; Q] = [
    0, 2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15, 18, 17,
];

/// Lattice speed of sound squared (D3Q19 and D3Q7 as used here).
pub const CS2: f64 = 1.0 / 3.0;

/// Number of D3Q7 directions.
pub const Q7: usize = 7;
/// D3Q7 velocities (rest, then +-x, +-y, +-z).
pub const C7: [[i32; 3]; Q7] = [
    [0, 0, 0],
    [1, 0, 0],
    [-1, 0, 0],
    [0, 1, 0],
    [0, -1, 0],
    [0, 0, 1],
    [0, 0, -1],
];
/// D3Q7 weights (w0 = 1/4, so the scalar's lattice speed of sound squared is 1/4).
pub const W7: [f64; Q7] = [0.25, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125];
/// D3Q7 opposite directions.
pub const OPP7: [usize; Q7] = [0, 2, 1, 4, 3, 6, 5];
/// D3Q7 speed of sound squared for the weights above.
pub const CS2_7: f64 = 0.25;

/// Second-order equilibrium `w_i rho (1 + 3 c.u + 4.5 (c.u)^2 - 1.5 u^2)`.
#[inline(always)]
pub fn equilibrium(rho: f64, u: [f64; 3], out: &mut [f64; Q]) {
    let uu = 1.5 * (u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
    for i in 0..Q {
        let cu = CF[i][0] * u[0] + CF[i][1] * u[1] + CF[i][2] * u[2];
        out[i] = W[i] * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - uu);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lattice_moments() {
        let s: f64 = W.iter().sum();
        assert!((s - 1.0).abs() < 1e-15);
        for a in 0..3 {
            for b in 0..3 {
                let m: f64 = (0..Q).map(|i| W[i] * CF[i][a] * CF[i][b]).sum();
                let want = if a == b { CS2 } else { 0.0 };
                assert!((m - want).abs() < 1e-15);
            }
        }
        for i in 0..Q {
            for a in 0..3 {
                assert_eq!(C[OPP[i]][a], -C[i][a]);
            }
        }
        for i in 0..Q7 {
            for a in 0..3 {
                assert_eq!(C7[OPP7[i]][a], -C7[i][a]);
            }
        }
    }
}
