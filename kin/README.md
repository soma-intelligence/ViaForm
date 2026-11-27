# ViaForm kinematics engine

Crate `kin/` (`viaform-kin`, MIT OR Apache-2.0). Robot model, forward kinematics, geometric
Jacobians, inverse kinematics (numerical for every model, analytic for 6-axis arms with a
spherical wrist), multi-finger hand IK with linkages and tendons, drag end effector, Cartesian
line and arc paths with time scaling. Units: m, rad, s, kg, N. Frames: right-handed, Z up. Poses
are `Isometry3<f64>`. Spec: `docs/specs/RUST-ENGINES.md` section 4 (K1, K2, K3, K5, K6; the K4
binary drag entry), app side `docs/specs/VIAFORM-SPEC.md` 7.3 and 7.10.4 to 7.10.6. Model types
for other engines: [API.md](API.md).

## Method

| Piece | What it does | Code |
|---|---|---|
| Model | Tree of links and joints in topological order (joint `i` makes link `i + 1`), revolute, prismatic, continuous, wheel, fixed, spherical (quaternion, 3 DOF) and floating (7 / 6) joints, named tool frames, actuators (motor or tendon) and couplings. Uncoupled joints get a motor each (motor per joint, E-13), so actuator space is always explicit. | `model.rs` |
| Couplings and tendons | Linear map `q = M a + c` per coupling (gears, linkages such as a PIP-DIP 1 : 0.75 drive). A tendon is routed through via points on links; its length is the sum of the straight runs, its moment arms `r = -dL/dq` come from point Jacobians, and an empty matrix is filled with the minimum-norm split `q_j = r_j a / sum r^2` (equal return springs on every crossed joint). | `model.rs` |
| Forward kinematics | One pass `T_child = T_parent * origin * motion(q)`; no allocation with `fk_into`. | `fk.rs` |
| Jacobian | Geometric Jacobian by the column formula (revolute `[z x (p - o); z]`, prismatic `[z; 0]`, one column per child-frame axis for spherical and floating joints), consistent with the right-composed `integrate`. | `fk.rs` |
| Numerical IK | Damped least squares (Wampler 1986; Nakamura and Hanafusa 1986) in drive space (`J_a = J_q C`, so coupled joints stay consistent). Errors: position and the log map of `target * current^-1`, expressed in the target frame so per-axis masks free a rotation about the tool axis. Damping `lambda^2 = (1 - (sigma_min / eps)^2) lambda_max^2` below `eps` (Chiaverini 1997), faded as the residual vanishes so the last steps are Gauss-Newton. | `ik.rs` |
| Joint limits | Active set: variables a step would push out of bounds are clamped at the bound and the step is solved again without them, so the solver never leaves the limits. | `ik.rs` |
| Priorities | Task-priority DLS (Siciliano and Slotine 1991; Chiaverini 1997): each level solved in the null space of the higher ones; a lower level's step is scaled so it never saturates a joint the higher levels need (task scaling from Flacco, De Luca and Khatib 2012). Null-space posture toward a pose or mid range. | `ik.rs` |
| Robustness | Line search on the lexicographic error, Levenberg-Marquardt style damping boost on a rejected step, stall detection, seeded multi-start (ChaCha8, uniform in limits). | `ik.rs` |
| Analytic 6R | Pieper (1968) decomposition with product-of-exponentials subproblems (Paden 1985; Murray, Li and Sastry 1994): the wrist centre moves only with joints 1 to 3; the height along axis 1 and the distance to it give two equations linear in `(cos q2, sin q2)`; eliminating `q2` leaves a degree 4 trigonometric polynomial in `q3`, solved through companion matrix eigenvalues in `tan(q3 / 2)` and polished by Newton. Intersecting or parallel axes 1 and 2 drop to a first-order equation. Wrist by subproblems 2 and 1. Up to 8 solutions, each verified by FK. Applies when the last three axes meet within 1e-6 m. | `analytic.rs` |
| Drag | Warm-started IK per pointer move, 10 iterations, no restarts; the analytic solution nearest the current pose when it applies and the full pose is held; out of reach the chain stretches (least squares) and the distance left is reported. | `drag.rs` |
| Hand | One position task per fingertip with priorities, in actuator space, with a light mid-range posture. | `hand.rs` |
| Cartesian paths | Lines (SLERP rotation), arcs through a via point, circular blends tangent to both lines at corners; one path parameter that weights rotation by `v_lin / v_ang`. IK every 2 mm warm-started, rejecting branch flips (joint jump over 0.1 rad) and limit or reach failures with the sample index. Time scaling: trapezoid or double S rest to rest (Biagiotti and Melchiorri 2008, 3.4), one section per sharp corner (the tool stops there), then a uniform slow-down until joint velocity (and optional acceleration) limits hold. Output at 500 Hz with IK at every sample, finite-difference `qd`, `qdd`, actuator values. | `path.rs` |
| Facade | `Kin::call(op, params)`: `model.load` (builtin, JSON or path), `model.info`, `model.json`, `fk`, `jacobian`, `ik` (auto, analytic or numerical; `all_solutions`), `ik_hand`, `path.cartesian`, `ik_drag_begin`, `ik_drag_move`, `ik_drag_end` (cancel restores, Esc). | `facade.rs` |
| C ABI | `vf_kin_new`, `vf_kin_free`, `vf_kin_call` (JSON), `vf_kin_drag_move` (binary 60 fps entry: pose `[x y z qw qx qy qz]` in, joint values and 4x4 column-major f32 link matrices out), `vf_kin_drag_error`. | `bridge/src/kin.rs`, `bridge/include/viaform_kin.h` |

Reference models (`kin/models/`, also `viaform_kin::models`):

- `so101_class_arm.json`: an SO-101 class 6-axis desk arm. Link lengths and servo limits follow the
  public SO-101 dimensions approximately (Feetech STS3215, 2.9 N m, 300 deg/s), but the wrist is
  a 3-axis spherical wrist (roll, pitch, roll), unlike SO-101's 2-axis wrist, so it is 6-axis
  and fits the analytic solver. Masses are rough. Not a drawing of the real arm.
- `hand5.json`: a human-sized five-finger hand, 22 DOF: 2-axis wrist; thumb with a motor per
  joint; index with motors for abduction and MCP plus one motor driving PIP and DIP through a
  1 : 0.75 linkage; middle, ring and pinky each with an abduction motor and one flexor tendon
  over MCP, PIP and DIP (matrix from the routing). Approximate adult sizes.

## Validation

Run `cargo test --release -p viaform-kin -- --nocapture` (the acceptance numbers are printed by
`tests/acceptance.rs`). Numbers from that run on an M-series Mac, 2026-11-22, with other builds
running on the machine.

| Item | Check | Target | Result |
|---|---|---|---|
| K1 | Jacobian vs central differences (step 1e-7) on a tree with every joint kind, 50 configurations, 2 frames | relative error under 1e-6 | passes (worst under 1e-6) |
| K1 | Tendon moment arms vs `-dL/dq` by differences | 1e-7 | passes |
| K1 | FK + Jacobian, 6-DOF arm | under 2 us | **0.21 to 0.34 us** |
| K1 | FK + 5 fingertip Jacobians, 22-DOF hand | under 8 us | **1.6 to 2.5 us** |
| K2 | 10,000 random reachable full-pose targets (random `q` in limits), start at the neutral pose, tolerance 1e-5 m and 1e-4 rad | 99.5 % converge | **99.91 %** (9991 / 10000), median **57 us**, 36 iterations mean; never outside limits |
| K3 | Same 10,000 kind of targets: the generating configuration is among the analytic solutions | all | **10000 / 10000**, 6.8 solutions per target |
| K3 | FK error of every analytic solution | under 1e-9 m | **2.7e-12 m**, 1.3e-12 rad; median **10 us** for all solutions |
| K3 | Numerical answer (tolerance 1e-11) equals an analytic solution, regular wrists | match | **945 / 945** within 1e-6 rad |
| K3 | Intersecting and parallel first axes, non-spherical wrist refused | | passes |
| K4 | Drag move, 10 iterations warm start | arm 1 ms, hand 3 ms | arm **0.013 ms** analytic, **0.010 ms** numerical; hand **0.33 to 0.40 ms** (medians; single outliers to 18 ms while the machine was loaded by other builds) |
| K5 | 300 grasps from random closed hands, solved from the open hand, 5 fingertips | all reached | **300 / 300** within 1e-5 m, median **0.24 to 0.33 ms**; couplings exact to 1e-12, limits held |
| K5 | Priority: thumb-index pinch (1) with an unreachable pinky target (2) | pinch exact | pinch error **1e-16 m**, pinky stays 0.29 m away |
| K6 | 40 random straight lines of 3 to 12 cm, S-curve and trapezoid, 500 Hz | deviation under 0.5 mm | **3.7e-6 m** worst over 11,710 samples; no position or velocity limit violation; 3 ms per path |
| K6 | Half-circle arc, radius 4 cm | under 0.5 mm | **1.0e-6 m** |
| K6 | Corner with a 1 cm blend | length `0.1 - 2 b + b pi / 2` | exact to 1e-9; 0.78 s against 1.12 s for the sharp corner (which stops) |
| K6 | Branch flip and out-of-reach paths | error with sample index | passes |

Other tests: model validation and round trip, motor-per-joint completion, actuator round trip,
integrate and difference, locked joints, stretch toward an unreachable target, same seed same
result, drag (small moves, stretch, Esc), facade ops end to end, profile limits, and the C ABI
(`cargo test -p viaform-ffi --lib kin::`).

Notes.

- The 0.09 % of K2 targets that fail are local minima against joint limits that 32 random starts
  did not escape; the analytic solver solves all of them on this arm.
- Near the wrist singularity (`q5` near 0) a converged numerical answer can differ from the
  analytic ones by more than its tolerance suggests (q4 and q6 trade), which is why the K3
  comparison uses regular wrists.
- Slack and tendon stiffness are not modelled in kin (they are `phys`'s, PH4); kin's tendon
  coupling is the kinematic map.
- Time scaling is the simple, global form of TOPP: one slow-down factor for the whole path.
  Joint acceleration limits are checked only when `max_joint_acc` is set.
