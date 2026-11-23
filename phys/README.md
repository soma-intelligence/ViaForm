# ViaForm physics engine

Crate `phys/` (`viaform-phys`, MIT OR Apache-2.0). Articulated rigid bodies on viaform-kin's
model, convex compliant contact with friction, servos, DC motors, tendons, the drone with its
battery and motor heat, scenarios, batched stepping, and the per-body wrench history for loads
from simulation (RUST-ENGINES G3). Units: SI, Z up, f64. Dependencies: nalgebra 0.34,
parry3d-f64 0.25.3 (Apache-2.0, pure Rust, no C build step), rayon, serde. `viaform-sim` (GPL)
is a dev-dependency only, for the parity test.

## Method

| Piece | What it does | Code |
|---|---|---|
| Model | kin's `Model` (links, joints, couplings, tendons) plus spatial inertias, motion subspaces, per-joint damping, dry friction, armature, springs, collision shapes, actuators, rotors and drag. Free objects are links on floating joints, so one tree holds the whole world. | `model.rs` |
| Dynamics | Featherstone's articulated-body algorithm (forward), recursive Newton-Euler (inverse) and composite-rigid-body algorithm (mass matrix), with scalar, spherical and floating joints (Featherstone 2008, ch. 5 to 7). Damping, springs and reflected rotor inertia are implicit through the ABA armature `I_a + dt d + dt^2 k`. | `dynamics.rs`, `spatial.rs` |
| Integration | Semi-implicit Euler with one convex constraint solve per step (default, 1 ms). RK4 on the smooth dynamics for validation and free flight (falls back to semi-implicit while constraints are active). | `world.rs` |
| Collision | parry3d-f64 contact manifolds (polygon clipping for boxes and hulls), with a margin. A plane against a polyhedron takes every vertex within the margin (parry's polygon features stop at four vertices, so a 12-sided prism used to land on four of its twelve corners and spin up). The cylinder spec is along z (parry's is along y: turned at build). Fixed pair filter, deterministic order. | `contact.rs` |
| Contact | Convex compliant contact (Todorov 2014; the SAP model of Castro, Permenter and Han 2023): per point a normal stiffness and dissipation time scale, a near-rigid floor `beta^2 w / 4 pi^2` on the regularisation, friction regularisation `sigma w`, Coulomb cone projection in the R-norm. A "gliding" correction `mu |v_t|` on the normal target removes the convex model's lift-off of sliding bodies (so a box sliding down an incline keeps Coulomb's acceleration). | `world.rs`, `solver.rs` |
| Solver | Newton on the primal problem with exact Hessian blocks, Cholesky, Armijo backtracking, warm start; projected Gauss-Seidel on the dual as the fallback when Newton does not converge. Joint limits, linkage equalities (a hundredth of the SAP floor: near rigid), joint dry friction, servo PD rows and tendon rows are rows of the same problem. | `solver.rs` |
| Servo | STS3215 class position servo: PD treated implicitly as a box row `R = 1 / (dt (kd + dt kp))`, `vhat = kp e / (kd + dt kp)`, clipped to the motor's torque-speed line times efficiency and the current limit; gear ratio and reflected rotor inertia; backlash as a gap the motor crosses on its own inertia at no more than no-load speed; deadband; encoder quantisation. Stable at any gain on light links. | `actuator.rs` |
| DC motor | Back-EMF as implicit damping `eta N^2 kt ke / R`, voltage term explicit, current limit, optional armature inductance (exact first-order current). | `actuator.rs` |
| Tendons | kin's couplings: fixed tendons from the coupling matrix (`r = m / |m|^2`), routed tendons from via points (length and moment arms `-dL/dq` match kin's `tendon_length` and `tendon_moment_arms` to 1e-17). Cable `T = k max(0, s) + c ds/dt`, `s = a - (L0 - L) - slack`, unilateral, clipped to the actuator's tension limit, one implicit row. Linear multi-joint linkages are equality rows. | `tendon.rs`, `world.rs` |
| Drone | sim's quad (same `QuadParams` JSON): airframe as a free body, four rotors with first-order spin-up, thrust `k_t w^2`, reaction torque `spin k_q w^2`, Cheeseman and Bennett (1955) ground effect, linear plus quadratic body drag against the wind, air density scaling. | `drone.rs`, `aero.rs` |
| Battery | Equivalent circuit (Plett 2015): OCV(soc) (sim's LiPo curve), `R0(T)` Arrhenius, two RC pairs updated exactly for the step's current. Heat by Bernardi, Pawlikowski and Newman (1985): `q = I (U - V) - I T dU/dT`, integrated exactly over the step. Two-state cell thermal model, core and surface (Lin et al. 2014). Rotor speed capped by the loaded voltage over 3.8 V per cell (sim's `volts / 11.4` on 3S). | `power.rs` |
| Motor and ESC heat | Lumped networks (Boglietti et al. 2009): winding, stator, housing nodes, copper loss `I^2 R(T)` (0.393 % per K) and iron loss `k_fe w^1.5`; ESC node with conduction and switching loss. Stepped exactly through the eigen decomposition of `C^-1/2 G C^-1/2`. Motor current follows sim's thrust law, so both simulators draw the same current for the same thrust. | `power.rs` |
| Batch | N worlds sharing one `Arc` model, stepped with rayon. Each world owns its state and scratch, so a parallel run is bitwise equal to a serial one. | `batch.rs` |
| Scenario | `assembly.json` (mm, deg) plus a `viaform-scenario` file to a world: core's `kin_model` mapping (link frame at the parent joint origin, world axes at home), masses as core's `component_inertial` without design bodies, proxy boxes as collision shapes, motors as servos, shared `tendon.actuator` as one tendon. World: ground, table, objects (`random_in:[a,b]x[c,d]`), initial pose, drives (target or timeline, sampled at `control_hz`, applied after the sampled latency), randomise (mass, friction, latency, backlash; seeded). | `scenario.rs` |
| Wrench history | Per recorded body: the wrench at its parent joint, the reaction at each child joint and the resultant of its contacts (centre of pressure as `at`), each a G3 `WrenchHistory` (`body, source, t, force, torque, at, accel`) in the body frame, from an RNEA pass with the step's contact forces; `accel` is the body's linear and angular acceleration without gravity. | `record.rs` |

## Validation

`cargo test --release -p viaform-phys -- --nocapture` prints every number below (Apple M-series,
18 cores, 2026-11-22).

| Check | Reference | ViaForm | Target |
|---|---|---|---|
| ABA against the CRBA solve, 600 random states, three trees (floating, spherical, prismatic, fixed, branch) | `H qdd = tau - C` | worst 2.2e-13 | 1e-10 |
| RNEA(ABA(tau)) | tau | worst 5.8e-13 | 1e-10 |
| Double pendulum energy, 10 s, RK4 dt 1e-4 | conserved | 2.7e-14 of the swing energy | 1e-6 |
| Double pendulum energy, 60 s, RK4 dt 1e-3 | conserved | 1.6e-9 | 1e-3 |
| same, semi-implicit dt 1e-5 / 1e-3 | conserved | 1.6e-4 / 1.4e-1 (first order, chaotic swing) | reported |
| Free body, 1 s ballistic with spin, RK4 | analytic | position 6.4e-11 m, energy 2.9e-13 | |
| Joint limit at -0.3 rad, falling link | no overshoot | lowest -0.29999 rad | |
| Viscous damping decay | `d / I` = 0.07500 1/s | 0.07500 1/s | |
| Box resting on a plane, 10 s (Newton / PGS) | no drift | 1.7e-16 m / 1.7e-6 m, 2.5 um penetration | 0.1 mm |
| Stack of five boxes, 10 s | no drift | 7.7e-10 m, 24 us per step (20 contacts) | 0.1 mm |
| Incline mu 0.5 at 20 deg (sticks, atan mu = 26.6 deg) | no slip | 3.6e-6 m over 9.5 s | 0.1 mm |
| Incline mu 0.5 at 30 deg (slides) | Coulomb 0.65715 m/s^2 | 0.65715 m/s^2 | 1 % |
| Two-finger grasp, 30 g cube, 5 N, mu 1, 5 s still / 2 Hz 1 cm shake | no slip | 2.8e-6 m / 2.8e-6 m | 0.1 mm |
| Heap of 9 bodies (boxes, cylinder, 12-sided prism, hull), 3 s, two runs | bitwise equal, settled | equal, max speed 5.6e-8 | |
| Servo step 0.1 rad, 1 ms (linear range) | fine RK4 of the continuous servo: rise 22.85 ms | 24.33 ms (+6.5 %), overshoot 3.2 % vs 4.0 % | 10 % |
| Servo step 1 rad (speed limited) | rise 169.50 ms, top speed 4.720 rad/s | 169.49 ms, 4.720 rad/s | 10 % |
| Servo holding 0.98 N m | sag `tau / kp` 0.04905 rad | 0.04899 rad | 2 % |
| Servo against 3.92 N m, limit 2.65 N m | falls, effort at the limit | falls, effort 2.646 N m | |
| Backlash 2 deg, reversal | lost motion | 5 ms later than without | |
| Deadband 2 counts | a 1.5 count step does not move | 0 rad; settles within 1.5e-4 rad | |
| DC gearmotor, 4 V, dt 1e-4 / 1e-3 | `w = V/(N ke) (1 - exp(-t/tau))` | 0.12 % / 1.2 % of top speed | 1 % |
| DC start at 12 V, 3 A limit | `eta N kt I / J` = 800 rad/s^2 | 800.00 | |
| Linkage 0.6 under 0.3 to 0.5 N m load | ratio 0.6 | 0.6 within 1e-4 % | 1 % |
| Fixed tendon with return springs, loaded | statics `k q = r T + tau`, `sum r q = a - T/kc` | 0.0000 % | 1 % |
| Routed tendon path length and moment arms, 50 configurations | kin | 0 m / 6.9e-18 m | |
| Routed tendon statics | `k q_j = r_j(q) T` | residual 0.0000 % | 1 % |
| Tendon slack, limit, push | no tension in slack, 1.5 N cap, no push | 0 N, 1.5000 N, 0 N | |
| Drone parity, hover 10 s from a 10 cm offset, sim's cascade on both | `sim::physics` | 0.009 mm, 0.0004 deg | 1 mm |
| Drone parity, 5 waypoints in 5 s (5.1 m flown) | `sim::physics` | 1.14 mm, 0.023 deg | 5 cm |
| Battery 6 A for 240 s: energy out plus irreversible heat | chemical energy, Simpson on OCV | 9.7e-12 relative | 1e-6 |
| Two-node motor network, 4 W | closed form | 1.0e-14 of the rise | 1e-6 |
| Hover on 3S 650 mAh to cutoff | sim's battery model 344 s | 337 s; 12.67 V loaded at start, 9.90 V at cutoff; cell core 33.2 C, winding 30.9 C, ESC 25.3 C | 25 % |
| Batch of 64 arms with a cube, 200 steps | serial run | bitwise equal, twice | |
| Sample arm assembly at rest | base joint carries the weight 4.6794 N | 4.6794 N (0.000 %) | 1 % |
| Scenario, same seed twice / another seed | identical / different | identical / different | |

## Performance

| Case | Rate |
|---|---|
| SO-101 class 6-axis arm, six servos, 1 kHz, one world, one thread | 0.44 to 0.51 M steps/s |
| 1024 arms on 18 rayon threads, free space | 4.1 to 4.7 M env steps/s |
| 1024 arms with a cube resting on the ground (4 contacts each) | 2.4 to 2.7 M env steps/s |
| Stack of five boxes (20 contacts, Newton) | 24 us per step |

RUST-ENGINES 6.3 asks 200 k env steps/s for 1024 arms at 500 Hz. The arm here has no collision
shapes on its links (the built-in kin model has none), so it measures dynamics, servos and the
constraint solve, plus the cube's contacts in the second row; an arm with link shapes touching
objects costs more per contact.

## C ABI

`bridge/include/viaform_phys.h`: `vf_phys_new`, `vf_phys_free`, `vf_phys_call(h, op, json)`
(ops in `facade.rs`: `world_new`, `scenario_load`, `world_step`, `world_state`,
`set_controls`, `episode_record`, `wrench_history`, `batch_new`, `batch_step`,
`episode_start`, `job_poll`, `job_cancel`, `model_info`), and the 60 fps path without JSON:
`vf_phys_step(h, steps, out, n)` and `vf_phys_state_poses(h, out, n)` write `[x, y, z, qw, qx,
qy, qz]` per link, `vf_phys_set_controls(h, controls, n)`.

## Limits

- Semi-implicit Euler is first order: energy of a chaotic swing drifts at 1 ms (RK4 is there
  for smooth validation runs). A free body spinning at hundreds of rad/s gains energy in the
  body-frame velocity update; keep spins physical or use a smaller step.
- A plane meets polyhedra vertex by vertex; between two polyhedra, faces with more than four
  vertices still go through parry's four-point features.
- Cable damping acts for one step when a slack tendon is pulled fast (a 1e-6 rad twitch).
- Recording runs on the semi-implicit path (RK4 steps are not recorded).
- Servo, DC and cell parameters are class values, not measured: replace them from bench data
  (phase 7).

## References

- Featherstone, R. Rigid Body Dynamics Algorithms. Springer, 2008.
- Todorov, E., Erez, T., Tassa, Y. MuJoCo: a physics engine for model-based control. IROS 2012.
- Todorov, E. Convex and analytically-invertible dynamics with contacts and constraints. ICRA 2014.
- Castro, A. M., Permenter, F. N., Han, X. An unconstrained convex formulation of compliant
  contact. IEEE Transactions on Robotics 39(2), 1301 to 1320, 2023.
- Cheeseman, I. C., Bennett, W. E. The effect of the ground on a helicopter rotor in forward
  flight. ARC R and M 3021, 1955.
- Bernardi, D., Pawlikowski, E., Newman, J. A general energy balance for battery systems.
  Journal of the Electrochemical Society 132, 5 to 12, 1985.
- Plett, G. L. Battery Management Systems, Volume I: Battery Modeling. Artech House, 2015.
- Lin, X. et al. A lumped-parameter electro-thermal model for cylindrical batteries. Journal of
  Power Sources 257, 1 to 11, 2014.
- Boglietti, A. et al. Evolution and modern approaches for thermal analysis of electrical
  machines. IEEE Transactions on Industrial Electronics 56(3), 871 to 882, 2009.
