use super::*;
use crate::Material;
use crate::solid::Support;

fn noise(i: usize) -> f64 {
    let mut z = (i as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    z ^= z >> 29;
    z = z.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z ^= z >> 32;
    (z >> 11) as f64 / (1u64 << 53) as f64
}

fn boxr(min: [f64; 3], max: [f64; 3]) -> Region {
    Region::Box { min, max }
}

/// A study of a bar along x, `l` long, `b` square, with the thermal block `th`.
fn bar(l: f64, b: f64, voxel: f64, th: Thermal) -> Study {
    Study { min: [0.0; 3], max: [l, b, b], voxel, thermal: Some(th), ..Study::default() }
}

fn solve(study: &Study, phys: &[f64]) -> (Problem, Vec<f64>, SolveStats) {
    let th = study.thermal.as_ref().unwrap();
    let grid = Grid::new(study.min, study.max, study.voxel);
    let prob = Problem::new(study, th, grid).unwrap();
    let (kappa, _) = prob.interpolate(phys, th.penal, th.kmin);
    let mg = Multigrid::new(&prob.op, &kappa);
    let mut t = vec![prob.reference; grid.nodes()];
    let stats = prob.temperature(&kappa, &mg, &mut t, 1e-11).unwrap();
    (prob, t, stats)
}

#[test]
fn element_matrix_matches_its_closed_form() {
    for h in [1.0, 0.37, 2.5] {
        let k = element_conduction(h);
        let g = Grid::new([0.0; 3], [1.0; 3], 1.0);
        let pos: Vec<[usize; 3]> = g.element_nodes(0).iter().map(|&v| g.node_ijk(v)).collect();
        for a in 0..8 {
            for b in 0..8 {
                // h Σ_axes (±1) Π_other (1/3 or 1/6).
                let same = |ax: usize| pos[a][ax] == pos[b][ax];
                let want: f64 = h * (0..3)
                    .map(|ax| {
                        let s = if same(ax) { 1.0 } else { -1.0 };
                        let (o1, o2) = others(ax);
                        s * [o1, o2].iter().map(|&o| if same(o) { 1.0 / 3.0 } else { 1.0 / 6.0 }).product::<f64>()
                    })
                    .sum::<f64>();
                assert!((k[a][b] - want).abs() < 1e-14, "{a} {b}: {} vs {want}", k[a][b]);
                let shared = (0..3).filter(|&ax| same(ax)).count();
                let named = match shared {
                    3 => 1.0 / 3.0,
                    2 => 0.0,
                    _ => -1.0 / 12.0,
                };
                assert!((k[a][b] - h * named).abs() < 1e-14);
            }
            assert!(k[a].iter().sum::<f64>().abs() < 1e-14, "a constant carries no heat");
        }
    }
}

#[test]
fn products_match_a_dense_assembly() {
    let g = Grid::new([0.0; 3], [3.0, 2.0, 2.0], 0.5);
    let n = g.nodes();
    let fixed: Vec<bool> = (0..n).map(|v| noise(v + 77) > 0.8).collect();
    let film: [Vec<f64>; 3] = std::array::from_fn(|a| {
        let d = face_dims(g.n, a);
        (0..d[0] * d[1] * d[2]).map(|i| if noise(i + 1000 * a) > 0.5 { noise(i + 50 + 1000 * a) } else { 0.0 }).collect()
    });
    let op = Conduction::new(g, fixed.clone(), film.clone());
    let kappa: Vec<f64> = (0..g.elements()).map(|e| 0.01 + noise(e + 9)).collect();
    let mut k = vec![vec![0.0; n]; n];
    let ke = element_conduction(g.h);
    for e in 0..g.elements() {
        let nodes = g.element_nodes(e);
        for a in 0..8 {
            for b in 0..8 {
                k[nodes[a]][nodes[b]] += kappa[e] * ke[a][b];
            }
        }
    }
    for a in 0..3 {
        let d = face_dims(g.n, a);
        let (b, c) = others(a);
        for f2 in 0..d[2] {
            for f1 in 0..d[1] {
                for f0 in 0..d[0] {
                    let f = [f0, f1, f2];
                    let hf = film[a][face_index(d, f)];
                    let corners: Vec<[usize; 3]> = (0..4)
                        .map(|q| {
                            let mut p = f;
                            p[b] += q & 1;
                            p[c] += q >> 1;
                            p
                        })
                        .collect();
                    for p in &corners {
                        for q in &corners {
                            let w = (if p[b] == q[b] { 2.0 } else { 1.0 }) * (if p[c] == q[c] { 2.0 } else { 1.0 });
                            k[g.node(p[0], p[1], p[2])][g.node(q[0], q[1], q[2])] += hf * g.h * g.h / 36.0 * w;
                        }
                    }
                }
            }
        }
    }
    let t: Vec<f64> = (0..n).map(|v| noise(v + 3) - 0.5).collect();
    let mut out = vec![0.0; n];
    op.apply_raw(&kappa, &t, &mut out);
    for v in 0..n {
        let want: f64 = (0..n).map(|x| k[v][x] * t[x]).sum();
        assert!((out[v] - want).abs() < 1e-12 * (1.0 + want.abs()), "row {v}: {} vs {want}", out[v]);
    }
    // The stencil the multigrid assembles is the same operator on the free nodes.
    let clean: Vec<f64> = t.iter().zip(&fixed).map(|(&x, &f)| if f { 0.0 } else { x }).collect();
    let st = op.stencil(&kappa);
    let mut a = vec![0.0; n];
    stencil_apply([g.n[0] + 1, g.n[1] + 1, g.n[2] + 1], &st, &clean, &mut a);
    let mut b = vec![0.0; n];
    op.apply_free(&kappa, &clean, &mut b);
    for v in 0..n {
        assert!((a[v] - b[v]).abs() < 1e-12 * (1.0 + b[v].abs()), "stencil row {v}");
    }
    // Cross energy: Σ κ aᵀK₁a is the conduction's quadratic form.
    let mut ce = vec![0.0; g.elements()];
    op.cross(&t, &t, &mut ce);
    let quad: f64 = (0..g.elements()).map(|e| kappa[e] * ce[e]).sum();
    let mut want = 0.0;
    for e in 0..g.elements() {
        let nodes = g.element_nodes(e);
        for x in 0..8 {
            for y in 0..8 {
                want += kappa[e] * t[nodes[x]] * ke[x][y] * t[nodes[y]];
            }
        }
    }
    assert!((quad - want).abs() < 1e-12 * want.abs());
}

#[test]
fn a_slab_between_two_temperatures_is_linear() {
    let th = Thermal {
        conductivity: Some(50.0),
        fixed: vec![
            FixedTemperature { region: boxr([-0.1, -1.0, -1.0], [0.1, 9.0, 9.0]), temperature: 100.0 },
            FixedTemperature { region: boxr([9.9, -1.0, -1.0], [10.1, 9.0, 9.0]), temperature: 20.0 },
        ],
        ..Thermal::default()
    };
    let s = bar(10.0, 3.0, 0.5, th);
    let g = Grid::new(s.min, s.max, s.voxel);
    let (_, t, _) = solve(&s, &vec![1.0; g.elements()]);
    for v in 0..g.nodes() {
        let x = g.node_position(v)[0];
        let want = 100.0 - 8.0 * x;
        assert!((t[v] - want).abs() < 1e-8, "x {x}: {} vs {want}", t[v]);
    }
}

#[test]
fn a_slab_with_uniform_heat_is_parabolic() {
    // T(x) = T0 + q x (L - x) / (2 k); peak q L² / (8 k) over T0 at mid-length. Linear
    // elements with the consistent load are exact at the nodes.
    let (l, b, k_si, q) = (20.0, 2.0, 50.0, 0.01); // mm, mm, W/(m K), W/mm³
    let th = Thermal {
        conductivity: Some(k_si),
        sources: vec![HeatSource { region: boxr([-1.0; 3], [l + 1.0, b + 1.0, b + 1.0]), power: q * l * b * b }],
        fixed: vec![
            FixedTemperature { region: boxr([-0.1, -1.0, -1.0], [0.1, 9.0, 9.0]), temperature: 20.0 },
            FixedTemperature { region: boxr([l - 0.1, -1.0, -1.0], [l + 0.1, 9.0, 9.0]), temperature: 20.0 },
        ],
        ..Thermal::default()
    };
    let s = bar(l, b, 0.5, th);
    let g = Grid::new(s.min, s.max, s.voxel);
    let (prob, t, _) = solve(&s, &vec![1.0; g.elements()]);
    let k = conductivity_mm(k_si);
    for v in 0..g.nodes() {
        let x = g.node_position(v)[0];
        let want = 20.0 + q * x * (l - x) / (2.0 * k);
        assert!((t[v] - want).abs() < 1e-8 * want, "x {x}: {} vs {want}", t[v]);
    }
    let peak = t.iter().copied().fold(0.0, f64::max);
    let want = 20.0 + q * l * l / (8.0 * k);
    assert!((peak - want).abs() < 1e-8 * want, "{peak} vs {want}");
    assert!((prob.power - q * l * b * b).abs() < 1e-12);
}

/// The straight fin: base held at T_b, the four sides cooled at h to T_amb, the tip insulated.
/// One-dimensional fin theory: θ/θ_b = cosh(m (L - x)) / cosh(m L), m = √(h P / (k A)). Answers
/// the largest error along the axis over θ_b (cross-section mean at each node plane).
fn fin_error(voxel: f64) -> f64 {
    let (l, b, k_si, h_si, tb, ta) = (40.0, 2.0, 167.0, 1000.0, 85.0, 25.0);
    let th = Thermal {
        conductivity: Some(k_si),
        ambient: ta,
        convection: vec![Convection { region: Some(boxr([0.0, -1.0, -1.0], [l - 0.01, b + 1.0, b + 1.0])), h: h_si, ambient: None }],
        fixed: vec![FixedTemperature { region: boxr([-0.01, -1.0, -1.0], [0.01, b + 1.0, b + 1.0]), temperature: tb }],
        ..Thermal::default()
    };
    let s = bar(l, b, voxel, th);
    let g = Grid::new(s.min, s.max, s.voxel);
    let (_, t, _) = solve(&s, &vec![1.0; g.elements()]);
    let m = (film_mm(h_si) * 4.0 * b / (conductivity_mm(k_si) * b * b)).sqrt();
    let per = (g.n[1] + 1) * (g.n[2] + 1);
    (0..=g.n[0])
        .map(|i| {
            let x = i as f64 * g.h;
            let mean: f64 = (0..=g.n[2]).flat_map(|k| (0..=g.n[1]).map(move |j| (j, k))).map(|(j, k)| t[g.node(i, j, k)]).sum::<f64>() / per as f64;
            let want = ta + (tb - ta) * (m * (l - x)).cosh() / (m * l).cosh();
            (mean - want).abs() / (tb - ta)
        })
        .fold(0.0, f64::max)
}

#[test]
fn a_straight_fin_follows_the_cosh_profile() {
    let errs: Vec<f64> = [1.0, 0.5, 0.25].iter().map(|&h| fin_error(h)).collect();
    eprintln!("fin errors (max |dT| / dT_base) at h = 1, 0.5, 0.25 mm: {errs:?}");
    assert!(errs[2] < 0.01, "{errs:?}");
    assert!(errs[0] > errs[1] && errs[1] > errs[2], "converges: {errs:?}");
}

#[test]
fn units_convert_at_the_boundary() {
    assert!((conductivity_mm(167.0) - 0.167).abs() < 1e-15);
    assert!((film_mm(100.0) - 1e-4).abs() < 1e-18);
    // Fourier through a 10 mm cube of aluminium, 10 K across: Q = k A ΔT / L = 167 W/(m K) x
    // 1e-4 m² x 10 K / 0.01 m = 16.7 W, read as the heat the cold face takes.
    let th = Thermal {
        conductivity: Some(167.0),
        fixed: vec![
            FixedTemperature { region: boxr([-0.1, -1.0, -1.0], [0.1, 11.0, 11.0]), temperature: 30.0 },
            FixedTemperature { region: boxr([9.9, -1.0, -1.0], [10.1, 11.0, 11.0]), temperature: 20.0 },
        ],
        ..Thermal::default()
    };
    let s = Study { max: [10.0; 3], voxel: 1.0, thermal: Some(th), ..Study::default() };
    let g = Grid::new(s.min, s.max, s.voxel);
    let (prob, t, _) = solve(&s, &vec![1.0; g.elements()]);
    let kappa = vec![prob.k0; g.elements()];
    let mut r = vec![0.0; g.nodes()];
    prob.op.apply_raw(&kappa, &t, &mut r);
    let q: f64 = (0..g.nodes()).filter(|&v| g.node_ijk(v)[0] == 0).map(|v| r[v]).sum();
    assert!((q - 16.7).abs() < 1e-9, "{q} W");
    // Newton: 1 W into a near-isothermal 10 mm cube cooled on its 100 mm² base at 100 W/(m² K)
    // rises ΔT = P / (h A) = 1 / (100 x 1e-4) = 100 K over the ambient.
    let th = Thermal {
        conductivity: Some(1e7),
        ambient: 20.0,
        sources: vec![HeatSource { region: boxr([-1.0; 3], [11.0; 3]), power: 1.0 }],
        convection: vec![Convection { region: Some(boxr([-1.0, -1.0, -0.01], [11.0, 11.0, 0.01])), h: 100.0, ambient: None }],
        ..Thermal::default()
    };
    let s = Study { max: [10.0; 3], voxel: 1.0, thermal: Some(th), ..Study::default() };
    let (_, t, _) = solve(&s, &vec![1.0; g.elements()]);
    let mean = t.iter().sum::<f64>() / t.len() as f64;
    assert!((mean - 120.0).abs() < 1e-3, "{mean}");
}

#[test]
fn materials_carry_thermal_properties() {
    let k = |name: &str| Material { name: name.into(), ..Material::default() }.thermal().map(|p| p.conductivity);
    assert_eq!(Material::default().thermal().unwrap().conductivity, 167.0);
    assert_eq!(k("PLA"), Some(0.13));
    assert_eq!(k("PETG"), Some(0.20));
    assert_eq!(k("PA12 (SLS)"), Some(0.25));
    assert_eq!(k("PA12 carbon filled (SLS)"), Some(0.25));
    assert_eq!(k("steel"), Some(50.0));
    assert_eq!(k("Titanium Ti6Al4V"), Some(6.7));
    assert_eq!(k("Copper C110"), Some(390.0));
    assert_eq!(k("Carbon fibre plate, quasi-isotropic T700"), Some(4.0));
    assert_eq!(k("AlSi10Mg (laser powder bed)"), Some(130.0));
    assert_eq!(k("unobtainium"), None);
    let steel = Material { name: "steel".into(), ..Material::default() }.thermal().unwrap();
    assert_eq!(steel.expansion, 11.7e-6);
    // A study without a thermal block still reads, and a thermal block takes its defaults.
    let s: Study = serde_json::from_str(r#"{"max": [10, 10, 10]}"#).unwrap();
    assert!(s.thermal.is_none());
    let s: Study = serde_json::from_str(r#"{"thermal": {"sources": [{"region": {"shape": "box", "min": [0,0,0], "max": [1,1,1]}, "power": 5}], "convection": [{"h": 50}]}}"#).unwrap();
    let th = s.thermal.unwrap();
    assert_eq!((th.ambient, th.penal, th.kmin, th.convection[0].region), (25.0, 3.0, 1e-3, None));
}

/// A cube `n` voxels a side: uniform heat, a sink patch on the bottom, convection on top.
fn cube(n: usize) -> Study {
    let l = n as f64;
    Study {
        max: [l; 3],
        voxel: 1.0,
        thermal: Some(Thermal {
            conductivity: Some(1.0),
            sources: vec![HeatSource { region: boxr([-1.0; 3], [l + 1.0; 3]), power: 1.0 }],
            fixed: vec![FixedTemperature { region: boxr([0.25 * l, 0.25 * l, -0.01], [0.5 * l, 0.5 * l, 0.01]), temperature: 25.0 }],
            convection: vec![Convection { region: Some(boxr([-1.0, -1.0, l - 0.01], [l + 1.0, l + 1.0, l + 1.0])), h: 10.0, ambient: None }],
            ..Thermal::default()
        }),
        ..Study::default()
    }
}

#[test]
fn multigrid_iterations_hold_as_the_grid_doubles() {
    let mut uniform = Vec::new();
    let mut simp = Vec::new();
    for n in [16, 32, 64] {
        let s = cube(n);
        let g = Grid::new(s.min, s.max, s.voxel);
        let (_, _, st) = solve(&s, &vec![1.0; g.elements()]);
        uniform.push(st.iterations);
        // A random 0/1 layout: contrast 1e-3.
        let phys: Vec<f64> = (0..g.elements()).map(|e| if noise(e) > 0.5 { 1.0 } else { 0.0 }).collect();
        let (_, _, st) = solve(&s, &phys);
        simp.push(st.iterations);
        assert!(st.residual <= 1e-11);
    }
    eprintln!("MG-PCG iterations to 1e-11, 16^3 / 32^3 / 64^3: uniform {uniform:?}, random 0/1 {simp:?}");
    let flat = |v: &[usize]| *v.iter().max().unwrap() <= v.iter().min().unwrap() + 6;
    assert!(flat(&uniform), "{uniform:?}");
    assert!(flat(&simp) || simp[2] <= simp[0] * 2, "{simp:?}");
    assert!(uniform[2] <= 20, "{uniform:?}");
}

fn check_gradients(s: &Study) {
    let mut ev = Evaluator::new(s, 0.4).unwrap();
    let n = ev.variables();
    let x: Vec<f64> = (0..n).map(|k| 0.25 + 0.5 * noise(k)).collect();
    let base = ev.evaluate(&x, 2.0, 0, 1e-12, true).unwrap();
    let h = 1e-5;
    for k in [1usize, n / 3, n / 2 + 1, n - 7] {
        let mut xp = x.clone();
        xp[k] += h;
        let p = ev.evaluate(&xp, 2.0, 1, 1e-12, false).unwrap();
        let mut xm = x.clone();
        xm[k] -= h;
        let m = ev.evaluate(&xm, 2.0, 1, 1e-12, false).unwrap();
        let fd = (p.f0 - m.f0) / (2.0 * h);
        let ad = base.df0[k];
        let scale = base.df0.iter().map(|v| v.abs()).fold(0.0, f64::max);
        assert!((fd - ad).abs() <= 1e-5 * scale + 1e-4 * fd.abs(), "compliance, variable {k}: adjoint {ad:.6e}, differences {fd:.6e}");
        for c in 0..base.g.len() {
            let fd = (p.g[c] - m.g[c]) / (2.0 * h);
            let ad = base.dg[c][k];
            let scale = base.dg[c].iter().map(|v| v.abs()).fold(0.0, f64::max);
            assert!((fd - ad).abs() <= 1e-5 * scale + 1e-4 * fd.abs(), "limit {c}, variable {k}: adjoint {ad:.6e}, differences {fd:.6e}");
        }
    }
}

#[test]
fn gradients_match_finite_differences() {
    // Homogeneous (sink and ambient both 25 C: the compliance is self-adjoint) and not (the
    // ambient at 40 C, so the compliance needs its own adjoint solve), each with the
    // temperature p-norm limit; projection on, a keep-in pad and a mirror plane.
    for amb in [25.0, 40.0] {
        let pad = boxr([5.0, 5.0, 2.0], [7.0, 7.0, 3.0]);
        let s = Study {
            max: [12.0, 12.0, 3.0],
            voxel: 1.0,
            keep_in: vec![pad],
            min_member: 2.0,
            symmetry: [true, false, false],
            thermal: Some(Thermal {
                conductivity: Some(100.0),
                sources: vec![HeatSource { region: pad, power: 2.0 }, HeatSource { region: boxr([-1.0; 3], [13.0, 13.0, 4.0]), power: 0.5 }],
                fixed: vec![FixedTemperature { region: boxr([4.0, -0.01, -1.0], [8.0, 0.01, 4.0]), temperature: 25.0 }],
                convection: vec![Convection { region: Some(boxr([-1.0, -1.0, -0.01], [13.0, 13.0, 0.01])), h: 200.0, ambient: Some(amb) }],
                max_temperature: Some(200.0),
                ..Thermal::default()
            }),
            ..Study::default()
        };
        check_gradients(&s);
    }
}

/// Runs of density 0.5 and over along x at row `j` (middle layer).
fn crossings(grid: &Grid, density: &[f32], j: usize) -> usize {
    let k = grid.n[2] / 2;
    let mut runs = 0;
    let mut inside = false;
    for i in 0..grid.n[0] {
        let solid = density[grid.element(i, j, k)] >= 0.5;
        if solid && !inside {
            runs += 1;
        }
        inside = solid;
    }
    runs
}

#[test]
fn volume_to_point_grows_a_tree() {
    let s = volume_to_point(40, 1, 0.3, 80);
    let layout = optimize(&s).unwrap();
    let h = &layout.history;
    let best = h.iter().copied().fold(f64::INFINITY, f64::min);
    eprintln!("volume to point 40x40: compliance {:.4e} -> {:.4e} ({} its)", h[0], h[h.len() - 1], h.len());
    assert!(h[h.len() - 1] < 0.2 * h[0], "compliance drops: {} to {}", h[0], h[h.len() - 1]);
    assert!(h[h.len() - 1] <= 1.01 * best, "and ends at its lowest");
    // Steady: after the first iterations no step raises it by more than 2 %.
    assert!(h.windows(2).skip(5).all(|w| w[1] <= 1.02 * w[0]), "{h:?}");
    // Branches: several separate conductors cross a line across the plate away from the sink.
    let g = layout.grid;
    let far = crossings(&g, &layout.density, 3 * g.n[1] / 4);
    let mid = crossings(&g, &layout.density, g.n[1] / 2);
    eprintln!("branches crossing y = 0.5 L: {mid}, y = 0.75 L: {far}");
    assert!(far >= 3 && mid >= 2, "tree: {mid} and {far} branches");
    let vol = layout.density.iter().map(|&d| d as f64).sum::<f64>() / g.elements() as f64;
    assert!((vol - 0.3).abs() < 0.01, "{vol}");
}

#[test]
fn heat_sink_keeps_five_watts_under_the_limit_with_less_mass() {
    let s = heat_sink(1.0, 150.0, 60);
    let out = generate(&s).unwrap();
    eprintln!(
        "heat sink: block {:.1} g at {:.2} C, optimised {:.1} g at {:.2} C ({:.1} s)",
        out.block.mass_g, out.block.max_temperature, out.analysis.mass_g, out.analysis.max_temperature, out.seconds
    );
    assert!(out.block.max_temperature <= 60.0, "the plain block holds the limit too: {}", out.block.max_temperature);
    assert!(out.feasible && out.analysis.max_temperature <= 60.0, "{}", out.analysis.max_temperature);
    assert!(out.analysis.mass_g < 0.8 * out.block.mass_g, "{} g vs {} g", out.analysis.mass_g, out.block.mass_g);
    assert!((out.analysis.power - 5.0).abs() < 1e-12);
    assert!(iso::is_closed(&out.mesh));
}

/// Rollers on the three planes x = 0, y = 0, z = 0 (and on x = L when `clamped`).
fn rollers(l: f64, b: f64, clamped: bool) -> Vec<Support> {
    let mut s = vec![
        Support { region: boxr([-0.01, -1.0, -1.0], [0.01, b + 1.0, b + 1.0]), fix: [true, false, false] },
        Support { region: boxr([-1.0, -0.01, -1.0], [l + 1.0, 0.01, b + 1.0]), fix: [false, true, false] },
        Support { region: boxr([-1.0, -1.0, -0.01], [l + 1.0, b + 1.0, 0.01]), fix: [false, false, true] },
    ];
    if clamped {
        s.push(Support { region: boxr([l - 0.01, -1.0, -1.0], [l + 0.01, b + 1.0, b + 1.0]), fix: [true, false, false] });
    }
    s
}

#[test]
fn thermal_stress_free_expansion_and_clamped_bar() {
    let (l, b, alpha, dt) = (10.0, 2.0, 11.7e-6, 100.0);
    let steel = Material { name: "steel".into(), e: 210_000.0, nu: 0.3, density: 7.85e-3, allowable: 250.0, color: String::new() };
    let theta_of = |g: &Grid| vec![dt; g.nodes()];
    // Free: u = α ΔT x on every axis, no stress.
    let s = Study { max: [l, b, b], voxel: 0.5, material: steel.clone(), supports: rollers(l, b, false), ..Study::default() };
    let g = Grid::new(s.min, s.max, s.voxel);
    let (u, vm) = thermal_stress(&s, &g, &vec![1.0; g.elements()], alpha, &theta_of(&g)).unwrap();
    for v in 0..g.nodes() {
        let p = g.node_position(v);
        for a in 0..3 {
            assert!((u[3 * v + a] - alpha * dt * p[a]).abs() < 1e-9, "node {v} axis {a}: {} vs {}", u[3 * v + a], alpha * dt * p[a]);
        }
    }
    assert!(vm.iter().all(|&s| s < 1e-6), "free expansion is stress free: {}", vm.iter().copied().fold(0.0, f64::max));
    // Clamped along x: σxx = -E α ΔT (uniaxial, the sides free), von Mises E α ΔT.
    let s = Study { supports: rollers(l, b, true), ..s };
    let (u, vm) = thermal_stress(&s, &g, &vec![1.0; g.elements()], alpha, &theta_of(&g)).unwrap();
    let want = steel.e * alpha * dt;
    for &sv in &vm {
        assert!((sv - want).abs() < 1e-6 * want, "{sv} vs {want} MPa");
    }
    let nu = steel.nu;
    let far = g.node(0, g.n[1], g.n[2]);
    assert!((u[3 * far + 1] - (1.0 + nu) * alpha * dt * b).abs() < 1e-9, "the sides swell by (1 + nu) alpha dT");
    // The sign: compressive. σxx at an element centre from the same pieces.
    let smat = fem::stress_matrix(nu, g.h);
    let dofs = fem::lex_dofs(&g, 0);
    let sxx = steel.e * ((0..24).map(|j| smat[0][j] * u[dofs[j]]).sum::<f64>() - alpha * dt * fem::thermal_stress_unit(nu));
    assert!((sxx + want).abs() < 1e-6 * want, "sigma_xx {sxx} vs {}", -want);
}
