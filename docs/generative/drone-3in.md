# 3-inch FPV quad: structure generated in 3D

Engineering specification for a 3-inch freestyle quad whose every structural part is a 3D generative
study (`generative/src/solid/mod.rs`) and whose assembly, checks and motion are built in SolidCraft.
Goal: as strong and stiff as possible for the mass, with the electronics fully enclosed. Every number
here is meant to be typed into a `Study` or asserted by the build test; where a number is a
judgement, the reasoning is beside it.

## 0. Summary

| Item | Value |
|---|---|
| Motor-to-motor diagonal | 140.0 mm (motor axes at x, y = ±49.497) |
| Props | 76.2 mm tri-blade, 1.6 g; prop-to-prop gap 22.8 mm; prop-to-frame >= 3.0 mm (3D) |
| Motors | T-Motor F1404 KV4600 (docs/components/drone.json M1), 9 x 9 M2 (UNCONFIRMED), 9.34 g; design thrust 290 g each (4S, sagged; maker table 345 g at 15.64 V) |
| Stack | 20 x 20 M2: 4-in-1 ESC, FC, 20 x 20 VTX on one bolt set, soft-mounted |
| Structural parts (studies) | P1 unibody bottom plate, P2 top plate, P3 electronics tub, P4 standoff (x4) |
| Frame mass target | 52.0 g hard limit (owner decision 2026-11-07, accepts the measured 51.3 g with closed tub); was 33.9 g target, 35.0 g limit |
| AUW | 195.7 g with 4S 650 mAh (78 g); 172.7 g with 4S 450 mAh (55 g) |
| Thrust to weight | 5.93 (650), 6.72 (450); required > 5.0, asserted >= 5.8 |
| Arm first bending mode (with motor and prop) | >= 350 Hz (k_z >= 57.1 N/mm per arm); design ~ 75 N/mm, ~ 400 Hz |
| Enclosure | 4.0 mm ball cannot reach any electronic body; every opening <= 3.2 mm least dimension; mean ray escape <= 6 % |
| Clearance electronics to structure | >= 1.0 mm asserted (1.5 mm designed, 1.0 at the camera sides), except two named camera pivot contacts |
| Voxel counts | P1 302 848, P2 112 000, P3 348 480, P4 44 000 (all under 400 000) |

## 1. Conventions

- Units: mm, N, N·mm, MPa, g/mm³ in `Material.density`, s, Hz. Accelerations in mm/s² as the engine
  takes them (300 g = 2 943 000 mm/s²).
- Assembly frame: origin at the centroid of the four motor axes, z = 0 on the underside of the
  bottom plate. +x forward (camera), +y left, +z up. Every study's `min`/`max` and every region is in
  this frame, so meshes insert without transforms.
- Motor numbering (Betaflight, props in): M1 rear right (−49.497, −49.497) CW, M2 front right
  (49.497, −49.497) CCW, M3 rear left (−49.497, 49.497) CCW, M4 front left (49.497, 49.497) CW, all
  seen from above. `C_FL` = (49.497, 49.497), `C_RL` = (−49.497, 49.497), and so on.
- Region notation (maps one to one on `Region`):
  - `Box[x0..x1, y0..y1, z0..z1]` is `Box { min, max }`.
  - `Cyl(base; axis; r; L)` is `Cylinder { base, axis, radius: r, length: L }`.
  - `Tube(base; axis; ri..ro; L)` is `Tube { base, axis, inner: ri, outer: ro, length: L }`.
  - "and mirror" means a second, separate entry with y negated (and axis y negated). The engine does
    not mirror regions; only design variables follow `symmetry`.
- Camera axis `a` = (0.9063, 0, 0.4226) (25° nose up), camera up `u` = (−0.4226, 0, 0.9063), camera
  pivot `K` = (22.0, 0, 18.85). A point "K + p·a + q·u" is written `K[p, q]`.
- Engine behaviours this spec relies on (read from the code, not assumed):
  - keep-out wins over keep-in (`optimize.rs:159` to `:168`);
  - a voxel is in a region when its centre is (`grid.rs:99`); the grid keeps one cubic edge and
    rounds counts (`grid.rs:17`), so every domain below is an exact multiple of its voxel;
  - `Extrusion` makes one design variable per column along the direction, so the part is prismatic
    and its thickness is the domain's extent along that axis;
  - `symmetry` mirrors design variables through the domain centre, so symmetric domains are centred on
    y = 0;
  - with `Objective::Compliance` the stress limit applies only when `max_stress` is set; with
    `Objective::Mass` it always applies (`optimize.rs` `Evaluator::new`);
  - `max_displacement` is one global limit over every case and impact (`optimize.rs:595`); per-case
    limits are asserted by the test from `Analysis.max_displacement[c]`;
  - impacts apply the case's full nodal force (applied plus body load) as a half-sine and integrate
    with the part's own mass only (`optimize.rs:975`, `fem.rs:409`).

## 2. Product layout and non-generative parts

### 2.1 Stack-up in z

| z (mm) | What |
|---|---|
| 0.0 to 4.0 | P1 bottom plate, carbon, 4.0 mm |
| 4.0 to 5.2 | P3 tub floor (PA12-CF, 1.2 mm) |
| 4.0 to 16.5 | motors on the arm pads (bell top 16.5) |
| 6.7 to 11.7 | ESC (soft mount grommet 5.2 to 6.7) |
| 14.2 to 19.2 | FC |
| 17.0 to 21.5 | prop blades (swept volume r 38.1) |
| 21.7 to 26.7 | VTX |
| 4.0 to 31.19 | P3 tub walls (45 voxel layers); 0.31 mm foam tape to the roof |
| 4.0 to 31.5 | P4 standoffs, 27.5 mm |
| 31.5 to 32.7 | P2 top plate, carbon, 1.2 mm |
| 32.7 to 34.2 | battery pad, TPU foam 1.5 mm |
| 34.2 to 62.2 | battery 4S 650 mAh (450 mAh: 34.2 to 54.2) |

### 2.2 Parts that are not generated

Each is a SolidCraft primitive, or, when it is rotated or lies on its side, a mesh written by the
build test and inserted with `file.insert_mesh` (SolidCraft's `solid.cylinder` stands on z and
`solid.move` turns about the origin, so turned bodies are made as meshes at their final place).
Each gets its own material whose density makes the primitive weigh what the real part weighs.

| Body | Geometry (assembly frame) | Mass g | Density g/cm³ |
|---|---|---|---|
| Motor M1..M4 | `solid.cylinder` Ø18.6 x 12.5, base (C_i, 4.0) | 9.2 each | 2.709 |
| Prop P1..P4 (mesh) | hub Ø7.0 x 4.5 at z 17.0 to 21.5; 3 blades r 3.5 to 38.1, 8.0 wide, 1.2 thick, centred z 19.25, 120° apart | 1.6 each | 1.368 |
| ESC 4-in-1 (incl. internal leads) | box 27 x 27 x 5, centre (−4.5, 0, 9.2), 4 holes Ø2.2 at the 20 x 20 pattern cut through | 9.0 | 2.522 |
| FC (incl. USB-C extension) | box 27 x 27 x 5, centre (−4.5, 0, 16.7), holes as ESC; USB-C extension with a flush receptacle in the −y wall slot, centred x −4.5, z 16.7 | 4.0 | 1.121 |
| VTX 20 x 20 | box 27 x 27 x 5, centre (−4.5, 0, 24.2), holes as ESC | 4.5 | 1.261 |
| Camera 19 mm micro (mesh) | body local x −8..4, y ±9.5, z ±9.5; lens Ø14 local x 4..11; pivot K, tilt 25° nose up (lens points to a) | 5.8 | 1.072 |
| Receiver (ELRS nano) | box 10 x 13 x 3.5, x −31.0..−21.0, y ±6.5, z 16.5..20.0 | 0.8 | 1.758 |
| RX antennas | 2 x `solid.cylinder` Ø1.4 x 30, base (−30.0, ±5.0, 20.0), through the roof | 0.4 total | 4.33 |
| VTX antenna | `solid.cylinder` Ø3.0 x 40, base (−30.0, 0, 27.0), through the roof | 2.5 | 8.84 |
| Capacitor 220 µF 35 V (mesh) | cylinder Ø8 x 12 on y, centre (−24.5, 0, 10.7) | 1.8 | 2.984 |
| XT30 and pigtail | box x −50.5..−34.5, y ±5.0, z 5.2..13.2 | 5.0 | 3.906 |
| Battery 4S 650 | box 60 x 31 x 28, centre (x_b, 0, 48.2) | 78.0 | 1.498 |
| Battery 4S 450 (variant) | box 57 x 29 x 20, centre (x_b, 0, 44.2) | 55.0 | 1.664 |
| Battery pad and strap | box 60 x 31 x 1.5, centre (x_b, 0, 33.45) | 2.0 | 0.717 |
| Stack bolts, Ti M2 x 30 FH | 4 x `solid.cylinder` Ø2.0 x 30, base (H_j, 0.0) | 0.42 each | 4.43 |
| Fastener allowance | not a body: 3.1 g added in the mass sum at (−4.5, 0, 16.0) | 3.1 | |

Fastener allowance: 16 motor screws Ti M2 x 6 FH (1.33 g), 8 standoff screws Ti M2 x 5 (0.64 g;
countersunk FH under the bottom plate, low head on top under the battery pad, pad relieved), nuts,
grommets and spacers (1.0 g), 2 camera screws (0.1 g).

Hole positions: stack `H` = (5.5, ±10.0), (−14.5, ±10.0). Standoffs `S` = (13.8, ±14.5),
(−22.8, ±11.4). Motor screws at C_i + (±4.5, ±4.5) (9 x 9 square).

Battery position `x_b` is not fixed by hand: the build computes it so that the centre of mass lies on
the motor centroid (estimate +4.3 mm for the 650, +6.1 mm for the 450) and asserts it falls inside
the pad's adjustment window 0.0 to 9.0.

### 2.3 Geometry decisions that fix the layout

- Diagonal 140 rather than 125 to 135: the 19 mm camera tilted 25° spans 24.0 mm in x and 23.0 mm in
  z; in front of a 27 mm stack, with 1.5 mm clearances and 1.2 mm walls, the camera bay reaches x 37.
  Between the front props the bay may only be 23.4 mm wide (cheeks |y| <= 11.7) within 3 mm of the
  prop discs. At 140 mm the face plate's lower cheek corner (z 15 to 16.5) sits 0.85 mm outside the
  stepped 3 mm envelope, the smallest margin in the layout; each 2 mm off the diagonal removes 0.94 mm
  there, so 138 mm fails. Prop-to-prop gap at 140 mm: 98.99 − 76.2 = 22.8 mm.
- Stack moved back 4.5 mm (centre x −4.5) so the camera's back-top corner (10.73, 24.08) clears the
  VTX front edge (x 9.0) by 1.73 mm.
- Camera tilt fixed at 25° per tub print (see 3.3): a closed face plate around the lens is the only
  way to enclose the camera bay; 15° and 35° are separate P3 runs with the camera transform changed,
  not adjustable on one part.
- Standoff height 27.5 mm: the tilted camera needs 23.0 mm in z plus 1.5 mm to the tub floor and
  above; floor top 5.2, camera z 6.86 to 29.84, roof 31.5.
- Battery on top: it shields the roof, keeps the LiPo off the ground in belly landings, and its pad
  is the only part that overhangs the hood (hood top 32.80, battery bottom 34.2: 1.4 mm).

## 3. Architecture and materials, part by part

### 3.1 P1 unibody bottom plate with arms: carbon plate, `Extrusion` along z, 4.0 mm

Candidates per mass for the governing modes:

| Material | E GPa | ρ g/cm³ | E/ρ (axial) | E^(1/3)/ρ (plate bending) | Working stress MPa |
|---|---|---|---|---|---|
| T700 quasi-isotropic carbon plate | 50 | 1.55 | 32.3 | 2.38 | 300 (450 / 1.5) |
| PA12-CF SLS | 5.5 | 1.10 | 5.0 | 1.60 | 30 |
| Ti-6Al-4V LPBF lattice | 110 | 4.43 | 24.8 | 1.08 | 300 |

The arms are bending plates (thrust, corner drop, frequency) and in-plane beams (crash): carbon wins
both columns by 1.5x to 5x and is the only one that keeps stiffness at 60 to 80 °C next to a motor.
Titanium lattice only pays where loads are concentrated and volume is free, which an arm is not.

Thickness: for a cantilever arm of out-of-plane stiffness k, mass ∝ 1/t². With the 350 Hz floor the
4.0 mm arm needs about 432 mm² of plate per arm (root 12, tip 6 over 48 mm, k = 74.9 N/mm, 10.7 g
for four arms); the 30 cm corner drop independently asks for a 12 mm root at 4 mm. 3.0 mm would need
2.4x the width and more mass. 5.0 mm is about 1.2 g lighter on paper, but its arms narrow to about
3 mm at the pad, where the bell-height torsion of a sideways hit then governs and eats the gain;
5 mm sheet is also a special order and lifts the whole stack 1 mm. 4.0 mm it is; a 5.0 mm P1 run
(domain z 0..5, voxel 0.625, 190 x 190 x 8 = 288 800) is a listed follow-up, not baseline.

Motor mounts are integral pads (keep-in), not separate parts: a separate mount adds a joint, four
screws and about 0.5 g per arm, and the mount-to-arm joint becomes the weakest point in a crash.
Motor screws are countersunk M2 from below so nothing protrudes under the plate; no skids (skids
make the arms the first contact in a flat 3 m drop, see 4.4).

### 3.2 P2 top plate: carbon plate, `Extrusion` along z, 1.2 mm

It is the enclosure's roof and the battery seat, so most of it is keep-in. By beam estimate (32 mm
wide, 36.6 mm between standoffs, tub rim support ignored) 1.2 mm carries the inverted-drop load
(322.9 N) at about 190 MPa against 225 and deflects 0.9 mm against 1.0. 1.0 mm deflects 1.55 mm and
fails; 1.5 mm adds 0.9 g. 1.2 mm it is, with little margin: P2 is the study most likely to come back
infeasible, and its fallback is the taped tub rim as a second support (a P2 support region over the
rim, then re-run).

### 3.3 P3 electronics tub: PA12-CF, SLS, one part

One tub encloses ESC, FC, VTX, receiver, capacitor and camera: walls, floor, a tilted face plate with
the lens hole and a lens hood. One shell shares walls between bays and is lighter than separate
cage, camera mount and VTX shell. SLS carbon-filled PA12 (Windform XT 2.0 class): printable thin
closed walls, no supports, tolerant of impacts, electrically insulating around the boards (carbon
plate is conductive: a carbon cage would short pads). Properties entered are the weak build (z)
direction at 60 °C: E 5 500 MPa, allowable 45 MPa. Manufacturing `Free` (SLS needs no overhang
rule); the open top lets powder out.

### 3.4 P4 standoffs: Ti-6Al-4V, LPBF, build along z, 4 identical parts

Metal standoffs take bolt preload (PA under preload creeps and loosens). Ti over AlSi10Mg: 1.8x the
fatigue strength per mass. Ends tapped M2 x 5 after printing; one study at the front-left position,
the result inserted at all four positions (its loads envelope the others).

### 3.5 Prop guards: not in the baseline

A ring guard per prop in PA12-CF that survives the same post crash weighs about 4.5 g (ring 1.6 x
4.0 section on r 41, plus two struts); four add 18 g, the frame becomes 52 g and AUW 214 g (T/W 5.4),
and a 3 mm guard-to-tip gap costs thrust without the gains of a real duct. For an indoor variant only:
four ring studies (domain per motor Box[C ± 46, z 14..24], keep-in ring Tube(C, z 15; +z;
41.5..43.0; 6.0), keep-out the prop envelope of 4.2), excluded from the frame mass and from the
baseline test.

## 4. Loads, derived

AUW m = 0.195 kg (650 pack). Yaw inertia I_z = 3.01e-4 kg·m², inertia about the horizontal axis
across a diagonal I_d = 2.06e-4 kg·m² (motors and props 2 x 10.8 g at 70 mm dominate; battery CG
at z 48.2, quad CG at z 27.5). Effective mass at a motor for a hit through the arm tip:
m_eff = m / (1 + m r² / I) with r = 70 mm.

| Event | Physics | Peak | Pulse |
|---|---|---|---|
| Full thrust | 290 g sagged (bench 345 g at 16 V) = 2.85 N; punch factor 3 | 9.0 N per motor, +z | static |
| Motor reaction torque | 150 W at 3 770 rad/s = 40 N·mm steady; spin-up 0 to 3 770 rad/s in 20 ms with J = 4.5e-7 kg·m² gives 85 N·mm; punch case | 120 N·mm per motor | static |
| Post hit, radial, at a motor | full mass, v = 6 m/s, crush d = 10 mm (prop, bell, post): F = (π/2)·(½mv²)/d | 550 N toward the centre | half-sine, T = 2d/v = 3.33 ms |
| Post hit, sideways | m_eff = 46.8 g (r²·m/I_z = 3.17), v = 6 m/s, d = 10 mm | 130 N tangential | 3.33 ms |
| Bell height lever | post contacts the bell at z 10.25, plate mid-plane z 2.0: lever 8.25 mm | radial 4 540 N·mm (pitches the pad), sideways 1 070 N·mm (twists the arm) | with the force |
| Belly drop 3 m onto turf | v = 7.67 m/s, stop 15 mm, T = 2d/v = 4.0 ms, a = πv/(2T) = 307 g | 300 g | 4.0 ms |
| Inverted drop 3 m | ground on the battery; everything below the roof (109.7 g) at 300 g | 322.9 N on the roof | 4.0 ms |
| Corner drop 30 cm onto concrete | v = 2.43 m/s, m_eff = 34.6 g (r²·m/I_d = 4.64), E = 0.1018 J, arm is the spring: F = √(2kE) | 150 N for k <= 110 N/mm | π√(m_eff/k) ≈ 2.0 ms |
| Side swipe on the tub | full mass, 3 m/s, d = 10 mm | 140 N on a Ø10 patch | 6.67 ms |
| Nose hit on the hood | full mass, 4 m/s (props usually hit first), d = 8 mm | 310 N, −x | 4.0 ms |
| Deceleration in the radial post hit | 550 N / 0.195 kg | 2 821 m/s² (288 g), +x inertia | with the hit |
| Battery on the roof, horizontal | friction-limited: strap preload 2 x 50 N, rubber pad μ = 1.0; beyond that the pack slides (accepted) | 100 N | |
| Battery, sideways swipe | 80 g at 718 m/s² | 57.4 N, +y | |

Design speeds: 6 m/s elastic with the safety factor below means about 7.3 m/s to first failure
(force ∝ v² in the crush model, SF 1.5). Hits at freestyle speed (15 to 25 m/s) break props and
motors first; the frame is not meant to survive them elastically and no 30 g frame does.

Concrete belly drops from 3 m (stop under 2 mm, over 1 000 g) are outside the elastic design; the
turf case is the design point.

Load factors: P1 uses safety factor 1.5 on rare events (crashes, 3 m drops). Frequent events (punch,
30 cm corner drop) are entered at 4/3 of their peak so that they see an effective factor of 2.0
(fatigue of carbon at about 50 % of static strength over a few hundred drops). Entered values:
punch 12.0 N and 160 N·mm, corner drop 200 N.

Vibration: hover at 48.8 g per motor runs the rotor at about 15 600 rpm (260 Hz), cruise up to
370 Hz, full throttle 670 Hz. An arm mode above full throttle is out of reach at this mass. The floor
is 350 Hz (1.35 x hover, above the D-term filter band and the hover fundamental); the design lands near
400 Hz. With motor and prop m_eq = 10.8 g + 0.24 x 4.2 g of arm = 11.8 g: k_z >= (2π·350)²·0.0118 =
57.1 N/mm per arm. Battery on the roof: >= 250 Hz needs k >= 197 N/mm for 80 g. Camera on its
bosses: >= 400 Hz needs k >= 36.6 N/mm for 5.8 g.

## 5. Studies

Common to all: `method: topology`, `seed: 1`, units as in section 1. Region lists name every entry;
counts are given so a build that drops one fails the region audit (T3).

### 5.1 P1 `bottom_plate`

| Field | Value |
|---|---|
| name | `bottom_plate` |
| objective | `compliance` (stiffest for the mass), stress limit set explicitly |
| min, max | (−59.4286, −59.4286, 0.0), (59.4286, 59.4286, 4.0) |
| voxel | 0.571429 (4/7): grid 208 x 208 x 7 = 302 848 |
| material | `Carbon T700 QI plate`: e 50 000, nu 0.30, density 1.55e-3, allowable 450, colour `#2b2d30` |
| safety_factor | 1.5 |
| max_stress | 300.0 |
| max_displacement | 3.0 (pad never moves more than the prop clearance) |
| min_frequency | none (no motor mass in the engine; see T6) |
| symmetry | [false, true, false] |
| min_member | 2.5 (CNC web in carbon) |
| manufacturing | `extrusion`, direction (0, 0, 1) |
| volume_fraction | set by the build: vf = (16.5 / 1.55e-3 − V_keep_in) / V_design, with V from the grid |
| variants | 3 (0.7 vf, vf, 1.3 vf); the test keeps the lightest that passes every criterion |
| iterations | 120 |
| smoothing | 4 |
| dynamics.modes | 6 |

Supports (8): `Tube(S_k, 0; +z; 1.1..3.5; 4.0)` for the 4 standoffs and `Tube(H_j, 0; +z; 1.1..3.0;
4.0)` for the 4 stack bolts, all fixed. The stack, tub, roof and battery bear on these points; fixing
them is inertia relief at the hub, valid while 72 % of the mass sits there.

Keep-in (per motor 5, plus hub 8 = 28): pad ring `Tube(C_i, 0; +z; 5.6..7.2; 4.0)`; four screw bosses
`Tube(C_i + (±4.5, ±4.5), 0; +z; 1.1..3.0; 4.0)`; hub bosses `Tube(S_k, 0; +z; 1.1..3.5; 4.0)` and
`Tube(H_j, 0; +z; 1.1..3.0; 4.0)`.

Keep-out (per motor 9, plus hub 16 = 52): shaft clearance `Cyl((C_i, −0.1); +z; 2.5; 4.2)`; four
screw holes `Cyl((C_i ± 4.5, ±4.5, −0.1); +z; 1.1; 4.2)` and their countersinks `Cyl(same; +z; 1.9;
1.0)`; at each S_k and H_j a hole `Cyl(−0.1; +z; 1.1; 4.2)` and a countersink `Cyl(−0.1; +z; 1.9;
1.0)`. (The countersink is 1.0 deep on a 4 mm prism: in an extruded part it becomes a through hole of
Ø3.8 in the voxel model. This is deliberate: it makes the analysis see the weakest section; the
countersink is cut afterwards in CAM.)

Load cases (`pad_k` = `Tube(C_k, 0; +z; 5.6..7.2; 4.0)`; torques centred at (C_k, 2.0)):

| # | name | loads | acceleration | weight |
|---|---|---|---|---|
| 0 | `punch` | on each pad: Force (0, 0, 12.0); Torque axis (0, 0, 1), moment +160 at M1 and M4, −160 at M2 and M3 | none | 1 / C0 |
| 1 | `stiffness_probe` | on each pad: Force (0, 0, 10.0) | none | 3 / C1 |
| 2 | `crash_radial_FL` | pad_FL: Force (−388.9, −388.9, 0); Torque axis (0.7071, −0.7071, 0), 4 540 | none | 1 / C2 |
| 3 | `crash_side_FL` | pad_FL: Force (−91.9, 91.9, 0); Torque axis (−0.7071, −0.7071, 0), 1 070 | none | 1 / C3 |
| 4 | `crash_radial_RL` | pad_RL: Force (388.9, −388.9, 0); Torque axis (0.7071, 0.7071, 0), 4 540 | none | 1 / C4 |
| 5 | `crash_side_RL` | pad_RL: Force (−91.9, −91.9, 0); Torque axis (0.7071, −0.7071, 0), 1 070 | none | 1 / C5 |
| 6 | `corner_FL` | pad_FL: Force (0, 0, 200.0) | none | 1 / C6 |
| 7 | `corner_RL` | pad_RL: Force (0, 0, 200.0) | none | 1 / C7 |
| 8 | `belly_300g` | each pad: Force (0, 0, −31.8) (motor and prop, 10.8 g at 300 g) | (0, 0, −2 943 000) | 1 / C8 |

`C_c` is case c's compliance on the uniform layout at density vf, computed by the build with
`optimize::analyse_full` before the run (`optimize.rs:928`), so every case pulls equally and the
stiffness probe three times as hard. The y mirror turns the front-left and rear-left cases into
both senses on all four arms.

Impacts: `{case 2, 0.00333, window 0.008, steps 160, damping 0.02}`, same for 3, 4 and 5;
`{6, 0.0020, 0.005, 150, 0.02}`, `{7, ...}`; `{8, 0.0040, 0.010, 160, 0.02}`.

### 5.2 P2 `top_plate`

| Field | Value |
|---|---|
| name | `top_plate` |
| objective | `mass` |
| min, max | (−36.0, −21.0, 31.5), (24.0, 21.0, 32.7) |
| voxel | 0.3: grid 200 x 140 x 4 = 112 000 |
| material | carbon as P1 |
| safety_factor | 2.0 (max_stress 225.0) |
| max_displacement | 1.0 (keeps >= 3.8 mm to the VTX; battery mode surrogate, T6) |
| min_frequency | none |
| symmetry | [false, true, false] |
| min_member | 2.0 |
| manufacturing | `extrusion`, (0, 0, 1) |
| volume_fraction | 0.6 |
| variants, iterations, smoothing | 1, 80, 2 |
| dynamics.modes | 4 |

Supports (4): `Tube(S_k, 31.5; +z; 1.1..3.5; 1.2)`, fixed.

Keep-in (10), the roof over every cavity plus the battery seat:
`Box[−20.7..11.7, −16.2..16.2, 31.5..32.7]` (stack bay), `Box[11.7..24.0, −11.7..11.7, ...]` (camera
bay), `Box[−33.7..−20.7, −9.2..9.2, ...]` (rear bay), `Box[−25.7..24.0, −15.5..15.5, ...]` (battery
footprint at x_b = 4.3), four standoff bosses `Tube(S_k, 31.5; +z; 1.1..3.5; 1.2)`, strap frames
`Box[−3.2..10.8, 15.0..20.5, ...]` and mirror.

Keep-out (9): standoff holes `Cyl((S_k, 31.4); +z; 1.1; 1.4)` x4, VTX antenna hole `Cyl((−30.0, 0,
31.4); +z; 1.6; 1.4)`, RX antenna holes `Cyl((−30.0, ±5.0, 31.4); +z; 1.1; 1.4)` x2, strap slots
`Box[−1.7..9.3, 16.5..19.0, 31.4..32.8]` and mirror.

Load cases (`seat` = `Box[−25.7..24.0, −15.5..15.5, 32.6..32.8]`, projected area 1 540.7 mm²):

| # | name | loads | acceleration |
|---|---|---|---|
| 0 | `inverted_drop` | Pressure on seat, direction (0, 0, −1), 0.2096 MPa (322.9 N) | (0, 0, +2 943 000) |
| 1 | `front_crash` | Force (100.0, 0, 0) on seat; Torque centre (4.3, 0, 32.1), axis (0, 1, 0), 1 610 | (2 821 000, 0, 0) |
| 2 | `strap` | Force (0, 0, 40.0) on `Box[−1.7..9.3, 19.0..20.5, 31.5..32.7]` and on its mirror; Pressure on seat (0, 0, −1), 0.0519 MPa (80 N) | none |
| 3 | `side_swipe` | Force (0, 57.4, 0) on seat; Torque centre (4.3, 0, 32.1), axis (−1, 0, 0), 924 | (0, 718 000, 0) |

Weights all 1. Impacts: `{0, 0.0040, 0.010, 160, 0.02}`, `{1, 0.00333, 0.008, 160, 0.02}`.

The seat and footprint regions are written for x_b = 4.3. The build places the real battery at the
computed x_b (T10); a difference up to ±2 mm is inside the seat's margins and does not require a
re-run, more than that does.

### 5.3 P3 `electronics_tub`

| Field | Value |
|---|---|
| name | `electronics_tub` |
| objective | `mass` |
| min, max | (−34.2, −18.125, 4.0), (38.904, 18.125, 33.0) |
| voxel | 0.6041667 (29/48): grid 121 x 60 x 48 = 348 480 |
| material | `PA12-CF SLS (z, 60 °C)`: e 5 500, nu 0.35, density 1.10e-3, allowable 45, colour `#3a3f45` |
| safety_factor | 1.5 (max_stress 30.0) |
| max_displacement | 0.8 (wall never reaches a board: 1.5 clearance − 0.5 grommet travel − 0.2 margin) |
| min_frequency | none (camera surrogate, T6) |
| symmetry | [false, true, false] |
| min_member | 1.2 |
| manufacturing | `free` (SLS, build along z; properties already the z-weak ones) |
| volume_fraction | 0.35 (cap) |
| variants, iterations, smoothing | 2, 120, 6 |
| dynamics.modes | 6 |

Every wall below is exactly two voxel centres thick on this grid (checked: 1.2 mm boxes at these
coordinates hold two centres, the cavities' edges are the adjacent centres, no gap, no third layer).
Walls end at layer 45, z 31.19; the 0.31 mm gap to the roof is filled by foam tape.

Keep-out, cavities (electronics plus 1.5 mm; the camera's sides 1.0 mm):
- stack: `Box[−19.5..10.5, −15.0..15.0, 5.2..33.1]`;
- rear bay (receiver, capacitor, antennas): `Box[−32.5..−19.5, −8.0..8.0, 5.2..33.1]`;
- camera, staircase of 27 slabs: for z0 = 5.2, 6.2, ... 30.2 with z1 = z0 + 1.0 (last z1 = 31.5),
  `Box[10.5..(36.859 − 0.4663·z1), −9.5..9.5, z0..z1]`, and the side bands the same in x but
  `y 9.5..10.5` and mirror, except where x 18.5..25.5 and z 15.35..22.35 (window for the pivot
  bosses). The x bound is the face plate's rear surface at the slab top, so the camera keeps >= 1.03
  mm to the face plate everywhere;
- lens aperture: `Cyl(K[4.0, 0] = (25.625, 0, 20.540); a; 8.0; 9.5)`;
- roof and above: `Box[−36.0..24.0, −21.0..21.0, 31.45..33.1]`;
- standoffs: `Cyl((S_k, 4.0); +z; 2.6; 27.5)` x4; stack bolts through the floor `Cyl((H_j, 3.9); +z;
  1.1; 1.4)` x4; camera screw holes `Cyl((22.0, 9.4, 18.85); +y; 1.1; 2.4)` and mirror;
- outside the camera bay: `Box[17.5..38.904, 11.7..18.125, 4.0..33.0]` and mirror; trim in front of
  the face plate: for z0 = 4.0, 5.0, ... 30.0, `Box[(38.845 − 0.4663·z0)..38.904, 9.85..11.7,
  z0..z0+1]` and mirror;
- outside the rear bay: `Box[−34.2..−26.2, 9.2..18.125, 4.0..33.0]` and mirror;
- prop clearance, per motor six stacked cylinders (the 3 mm Minkowski envelope of the swept disc,
  stepped conservatively): `Cyl((C_i, 16.5); +z; 41.10; 5.5)`, `Cyl((C_i, 16.0); +z; 41.06; 6.5)`,
  `Cyl((C_i, 15.5); +z; 40.93; 7.5)`, `Cyl((C_i, 15.0); +z; 40.70; 8.5)`, `Cyl((C_i, 14.5); +z;
  40.34; 9.5)`, `Cyl((C_i, 14.0); +z; 39.76; 10.5)` (24 regions);
- openings, each least dimension <= 3.2 mm:
  - USB-C (−y wall): `Box[−9.2..0.2, −16.3..−14.9, 15.1..18.3]`;
  - XT30 lead: `Box[−33.8..−32.4, −2.3..2.3, 5.2..7.8]`;
  - motor wires: `Box[5.0..8.2, 14.9..16.3, 5.2..7.0]`, `Box[−18.5..−15.3, 14.9..16.3, 5.2..7.0]` and
    mirrors;
  - intakes in the face plate (forward facing, 29 mm²): `Box[31.0..37.5, 2.0..4.0, 5.4..12.0]` and
    mirror;
  - side intakes (80 mm²): `Box[2.0..4.0, 14.9..16.3, 12.0..22.0]`, `Box[6.0..8.0, ...]` and mirrors;
  - exhausts (72 mm²): `Box[−33.8..−32.4, 3.5..5.5, 10.0..18.0]` and mirror, `Box[−31.0..−29.0,
    7.9..9.3, 10.0..20.0]` and mirror.

Keep-in (skin):
- floor: `Box[−20.7..11.7, −16.2..16.2, 4.0..5.2]`, `Box[11.7..37.0, −11.7..11.7, 4.0..5.2]`,
  `Box[−33.7..−20.7, −9.2..9.2, 4.0..5.2]`;
- stack bay sides `Box[−20.7..11.7, 15.0..16.2, 4.0..31.5]` and mirror; rear shoulders
  `Box[−20.7..−19.5, 8.0..16.2, 4.0..31.5]` and mirror; front shoulders `Box[10.5..11.7, 10.5..16.2,
  4.0..31.5]` and mirror; cheeks `Box[10.5..38.0, 10.5..11.7, 4.0..31.5]` and mirror; rear bay sides
  `Box[−33.7..−20.7, 8.0..9.2, 4.0..31.5]` and mirror; rear wall `Box[−33.7..−32.5, −9.2..9.2,
  4.0..31.5]`;
- face plate: `Tube(K[5.5, 0] = (26.985, 0, 21.174); a; 8.0..23.0; 1.8)` (the outer radius spills;
  the keep-outs above trim it to the bay);
- lens hood: `Tube(K[7.3, 0] = (28.616, 0, 21.935); a; 8.0..9.8; 4.7)` (front at K[12, 0], 1.0 mm
  ahead of the lens; top at (28.73, 0, 32.80), 1.4 mm under the battery);
- camera pivot bosses: `Tube((22.0, 9.5, 18.85); +y; 1.1..3.5; 2.2)` and `Tube((22.0, −11.7, 18.85);
  +y; 1.1..3.5; 2.2)` (inner faces touch the camera sides: the only declared contact);
- standoff bosses: `Tube((S_k, 4.0); +z; 2.6..3.2; 27.19)` x4.

Supports: floor at the stack bolts `Tube((H_j, 4.0); +z; 1.1..3.0; 1.2)` x4, fixed; standoff bosses
`Tube((S_k, 4.0); +z; 2.6..3.2; 27.19)` x4, fix [true, true, false]; top rim (taped to the roof)
`Box[−33.7..24.0, −16.2..16.2, 30.9..31.2]` fix [true, true, false] (it holds the top node layer,
z 31.1875; inside the cavities those nodes belong to void voxels and carry nothing).

Load cases:

| # | name | loads | acceleration |
|---|---|---|---|
| 0 | `nose_hit` | Force (−310, 0, 0) on `Tube(K[11.4, 0] = (32.332, 0, 23.668); a; 8.0..9.8; 0.6)` | none |
| 1 | `side_swipe` | Force (0, −140, 0) on `Cyl((−4.5, 15.0, 18.0); +y; 5.0; 1.2)` | none |
| 2 | `belly_300g` | Force (0, 0, −8.55) on each pivot boss; (0, 0, −2.35) on `Box[−31.0..−21.0, −6.5..6.5, 4.0..5.2]` (RX); (0, 0, −5.30) on `Box[−28.5..−20.5, −6.0..6.0, 4.0..5.2]` (capacitor) | (0, 0, −2 943 000) |
| 3 | `crash_inertia` | Force (8.18, 0, 0) on each pivot boss; (2.26, 0, 0) on the RX box; (5.08, 0, 0) on the capacitor box | (2 821 000, 0, 0) |
| 4 | `camera_probe_z` | Force (0, 0, 5.0) on each pivot boss | none |
| 5 | `camera_probe_x` | Force (5.0, 0, 0) on each pivot boss | none |

Weights: 1 for cases 0 to 3, 0.2 for 4 and 5. Impacts: `{0, 0.0040, 0.010, 160, 0.03}`,
`{1, 0.00667, 0.015, 160, 0.03}`, `{2, 0.0040, 0.010, 160, 0.03}`.

### 5.4 P4 `standoff`

| Field | Value |
|---|---|
| name | `standoff` (inserted 4 times: the build translates the mesh to each S_k before writing it) |
| objective | `mass` |
| min, max | (11.3, 12.0, 4.0), (16.3, 17.0, 31.5) (front left, axis (13.8, 14.5)) |
| voxel | 0.25: grid 20 x 20 x 110 = 44 000 |
| material | `Ti-6Al-4V LPBF HIP`: e 110 000, nu 0.34, density 4.43e-3, allowable 450, colour `#8d8f91` |
| safety_factor | 1.5 (max_stress 300.0) |
| max_displacement | 0.3 |
| symmetry | [true, true, true] (about its axis and mid-height: a column fixed at both plates) |
| min_member | 0.6 |
| manufacturing | `additive`, build (0, 0, 1), overhang 45 |
| volume_fraction | 0.3 (cap) |
| variants, iterations, smoothing | 1, 80, 6 |
| dynamics.modes | 3 |

Keep-in: end rings `Tube((13.8, 14.5, 4.0); +z; 0.8..2.5; 1.0)` and `Tube((13.8, 14.5, 30.5); +z;
0.8..2.5; 1.0)`; mid core `Cyl((13.8, 14.5, 17.5); +z; 1.2; 0.5)`.
Keep-out: tapped bores `Cyl((13.8, 14.5, 3.9); +z; 0.8; 5.1)` and `Cyl((13.8, 14.5, 26.5); +z; 0.8;
5.1)`; envelope `Tube((13.8, 14.5, 3.9); +z; 2.5..4.5; 27.7)` (Ø5.0 maximum).
Supports: `Tube((13.8, 14.5, 4.0); +z; 0.8..2.5; 0.3)`, fixed.
Load regions: top ring `Tube((13.8, 14.5, 31.2); +z; 0.8..2.5; 0.3)`, mid core as above.

| # | name | loads | acceleration |
|---|---|---|---|
| 0 | `inverted_drop` | top ring (0, 0, −81.0) (322.9 N over 4) | (0, 0, 2 943 000) |
| 1 | `belly_300g` | top ring (0, 0, −64.0) (86.4 g at 300 g, over 4) | (0, 0, −2 943 000) |
| 2 | `front_crash` | top ring (0, 0, −23.0) (overturning 1 670 N·mm over 36.6 mm, per standoff); mid core (30.0, 0, 0) | (2 821 000, 0, 0) |
| 3 | `lateral_y` | top ring (0, 0, −23.0); mid core (0, 30.0, 0) | none |

Lateral force at mid-height on a column fixed at the base and mirrored about mid-height gives the end
moment of a fixed-guided column under sway (F·L/2), which is what four standoffs tied by a stiff
roof see. The tub bosses that wrap each standoff take part of the shear in reality; ignored here.
Impacts: `{0, 0.0040, 0.010, 120, 0.02}`.

## 6. Assembly in SolidCraft

Reference for command shapes: `electron/src/test/drone.ts`. Order:

1. `material.create` for every material in 2.2 and 5 (name, `density_g_cm3`, colour).
2. Run P1 to P4 (`solid::generate`), write each best candidate as 3MF (`export::three_mf`), P4 four
   times translated to S_k; `file.insert_mesh {path, name}` for `BottomPlate`, `TopPlate`,
   `ElectronicsTub`, `Standoff1..4`; `material.assign`.
3. Primitives of 2.2: `solid.cylinder` and `solid.box` with `body_name`; board holes by
   `solid.combine` cut; camera, props and capacitor written as meshes by the test and inserted.
4. `component.from_bodies` for all bodies; `joint.rigid_group` for everything except the props;
   `joint.create` revolute per prop, a at (C_i, 16.5), b at the prop hub, x (1, 0, 0).
5. Checks: `assembly.mass_properties`, `inspect.interference`, `motion.study` (props one turn, M1 and
   M4 −360°, M2 and M3 +360°) and `motion.interference` of the props against every other body; then
   the geometric checks of section 7 run in Rust on the inserted meshes.

## 7. Verification the build test must assert

Every threshold below is a hard assert unless marked "report". The test fails on the first miss and
prints the measured value. Measurements are taken on the delivered meshes (after smoothing and
export), never on the optimiser's internal densities, unless stated.

### T0 Engine calibration (before any part)
- Carbon cantilever 60 x 10 x 4 (voxel 4/7, 7 layers), clamped, 10 N tip load: tip deflection within
  3 % of Timoshenko (EI = 2.667e6 N·mm², shear included); first mode within 3 % of 1.875² √(EI/ρA)
  /(2πL²).
- PA12-CF strip 30 x 10 x 1.2 at voxel 0.6041667 (2 layers): deflection error reported. If over
  10 %, P3's displacement results are scaled by the measured factor before T5 (two-layer hex walls
  can be over-stiff; the tub's 0.8 mm limit must not be met by locking).

### T1 Studies run
- `generate` returns Ok for P1 to P4; grid element counts exactly 302 848, 112 000, 348 480, 44 000.
- `best` candidate `feasible == true` for each.
- Region audit: every support, load, keep-in and keep-out region touches its grid
  (`optimize::touches`); region counts: P1 supports 8, keep-in 28, keep-out 52, cases 9, impacts 7;
  P2 4, 10, 9, 4, 2; P3 cases 6, impacts 3; P4 cases 4, impacts 1.
- Load audit: for every case, the sum of `loads::applied` (`loads.rs:34`) equals the specified
  resultant within 0.5 %, and its moment about the region centre equals the specified torque within
  1 % (catches loads that land on no node or on void nodes).

### T2 Meshes
- Each part closed and manifold (`iso::is_closed`, `iso::is_manifold`), one connected component
  (a part in two pieces is not a part), no triangle with area under 1e-6 mm².
- Mass from `iso::volume` x density within 2 % of `Candidate.mass_g`.

### T3 Keep-in and keep-out honoured on the mesh
- For every keep-in region, 200 deterministic sample points inside it (and inside the domain): at
  least 98 % inside the mesh (winding number).
- For every keep-out region: at most 0.5 % of 200 samples inside the mesh.

### T4 Mass
- P1 <= 16.5 g, P2 <= 3.5 g, P3 <= 11.5 g, each P4 <= 0.6 g (5 % over a budget fails).
- Frame (P1 + P2 + P3 + 4 P4) <= 52.0 g (owner decision 2026-11-07; the original 34.5 g assert and 35.0 g limit are superseded).
- `assembly.mass_properties` total plus the 3.1 g allowance within 0.5 % of the sum of section 2.2
  and the part masses; AUW with the 650 pack <= 198.0 g.

### T5 Strength, statics and impacts, on the delivered geometry
- Re-voxelise each exported mesh on its study grid (element solid when its centre is inside) and run
  `optimize::analyse_full` with the study: `Analysis.safety_factor` >= the study's factor x 0.95
  (smoothing may not thin a member by more than that).
- Every impact's `amplification` in [0.8, 2.5] (outside that, the integration or the pulse is
  suspect); report each peak stress and peak displacement.
- Per-case displacement limits from `Analysis.max_displacement[c]`: P1 punch <= 0.25 mm, P1 crash
  cases <= 3.0 mm; P2 every case <= 1.0 mm; P3 every case and impact <= 0.8 mm (after T0 scaling);
  P4 <= 0.3 mm.

### T6 Stiffness and frequency surrogates (no lumped masses in the engine)
- P1: k_z = 10 N / `max_displacement[1]` >= 57.1 N/mm, so f_arm = √(k_z / 0.0118 kg) / 2π >= 350 Hz.
  Report f_arm.
- P1 corner-drop consistency: F = √(2 k_z · 0.1018 J) <= 150 N. If not, scale case 6 and 7 stresses
  by F / 150 (linear) and require them still under 300 MPa.
- P2: k = 322.9 N / `max_displacement[0]` >= 197 N/mm (battery on the roof >= 250 Hz).
- P3: k = 10 N / displacement of case 4, and of case 5, each >= 36.6 N/mm (camera >= 400 Hz).
- Report `modes[0..]` of each bare part (they must be finite and positive).

### T7 Enclosure (assembly, on meshes)
Electronic bodies: ESC, FC, VTX, receiver, capacitor, camera. Structure: P1, P2, P3, P4 x4.
- E1 Clearance: minimum distance from each electronic body to each structural mesh >= 1.0 mm, except
  the camera's two side faces inside 3.5 mm of the pivot axis (declared contact).
  `inspect.interference` count 0 over all pairs (stack bolts pass board holes with 0.1 mm; grommets
  touch with zero overlap).
- E2 Ball probe: voxelise the structure plus the camera plus the stack bolts at 0.25 mm over the
  tub's box grown by 10 mm (battery, antennas and wires excluded, so the roof must close on its own);
  erode free space by r = 2.0 mm, flood from the box faces, dilate by 2.0 mm. The reached set must
  not touch ESC, FC, VTX, receiver or capacitor, and may touch the camera only where its local x >=
  10.5 (lens front).
- E3 Ray escape: from each vertex of ESC, FC, VTX, receiver and capacitor (at most 2 000 per body),
  512 Fibonacci directions; a ray escapes when it meets no structural mesh. Mean escape per body <=
  6 %, any vertex <= 40 %. (A cage of bars with 3.9 mm gaps passes E2 and fails here at over 50 %.)
- E4 Vents open: a ray through each declared opening's centre along its wall normal meets no tub
  triangle; sum of declared vent areas >= 150 mm², forward-facing >= 25 mm².
- E5 Lens behind the hood: for every direction d within 60° of a, max over tub vertices of v·d >=
  max over lens vertices of v·d + 0.5 mm (a flat obstacle meets the hood before the glass).
- E6 Trapped powder: in P3's voxel model every void connects to the outside (SLS).

### T8 Props
- 3D distance from each prop's swept volume (cylinder r 38.1, z 17.0 to 21.5 at C_i) to every body
  except its own motor and hub >= 3.0 mm; to the battery >= 3.0 mm. Report the smallest (expected
  about 0.9 to 1.0 mm over the limit at the camera cheek, z 15 to 16.5).
- Adjacent discs: centre distance − 76.2 >= 5.0 mm.
- `motion.interference` clear over 13 samples, not truncated.

### T9 Thrust to weight
- 4 x 290 g / AUW(650) >= 5.8 (spec value 5.93; hard product floor 5.0).

### T10 Balance
- Computed x_b in [0.0, 9.0]; after placing the battery, |CG_x| <= 0.5 mm, |CG_y| <= 0.5 mm, for the
  650 and the 450 pack.

### T11 Manufacturability
- P1, P2 prismatic: at least 99 % of triangle area has |n_z| > 0.98 or |n_z| < 0.2; every vertex z
  within 0.05 mm of the plate's faces or between them.
- P1, P2 minimum web: in the density slice (k = 0), eroding the solid mask by 1.0 mm (P1) or 0.9 mm
  (P2) leaves every connected component non-empty (no web under 2.0 mm or 1.8 mm).
- P3: eroding the solid by 0.45 mm leaves the skin one connected component (walls >= 0.9 mm after
  smoothing).
- P4: a ray along the axis inside r 0.75 meets no triangle over the tapped lengths; one component.

### T12 Symmetry and determinism
- P1, P2, P3: symmetric Hausdorff distance between the mesh and its y mirror <= 0.6 mm, excluding
  5 mm around the USB slot.
- Running P1 twice with seed 1 gives masses within 0.1 %.
- Report wall time per study (release build, all cores); budget 600 s each on a 10-core Apple
  silicon Mac.

## 8. Mass, balance, thrust

| Group | g |
|---|---|
| Motors 4 x 9.2 | 36.8 |
| Props 4 x 1.6 | 6.4 |
| Frame: P1 16.5, P2 3.5, P3 11.5, P4 2.4 | 33.9 |
| ESC 9.0, FC 4.0, VTX 4.5 | 17.5 |
| Camera | 5.8 |
| Receiver and antennas | 1.2 |
| VTX antenna | 2.5 |
| Capacitor | 1.8 |
| XT30 and pigtail | 5.0 |
| Battery pad and strap | 2.0 |
| Stack bolts | 1.7 |
| Fastener allowance | 3.1 |
| Dry total | 117.7 |
| AUW, 4S 650 (78 g) | 195.7 |
| AUW, 4S 450 (55 g) | 172.7 |

CG z about 27.5 with the 650 pack (battery on top). Thrust 4 x 290 g = 1 160 g: T/W 5.93 and 6.72.

## 9. Engine gaps and the workarounds used here

| Gap | Where | Effect | Workaround here |
|---|---|---|---|
| No non-structural (lumped) masses | `mod.rs:109` `LoadCase`, `fem.rs:409` | modes and impacts ignore motors, battery, camera; bare-arm modes read ~1 kHz | stiffness probes and T6 surrogates; inertia entered as forces at mounts. Requested: `Study.masses: Vec<{ region, mass_g }>` added to the lumped mass and to body loads |
| No oriented box | `mod.rs:59` `Region` | tilted camera keep-out | staircase of 1 mm slabs (<= 0.47 mm teeth, accounted in clearances) |
| One global displacement limit | `optimize.rs:595` | crash and thrust cannot have separate limits | per-case asserts in T5 |
| One safety factor for static and dynamic | `mod.rs:182` | rare and frequent events differ | frequent events entered x 4/3 |
| Iso smoothing not extrusion-aware | `iso.rs:42` | carbon plates may round their faces | prismatic assert T11; a 2D profile export (DXF) for CAM is requested |
| Linear, isotropic, no buckling or contact | engine-wide | carbon interlaminar shear, PA anisotropy, column buckling unchecked | hand checks below; z-weak PA properties |
| Free-flying body has no inertia relief | `loads.rs` supports | reactions forced at the hub | hub supports; 72 % of mass is there |

Hand checks (values at the design point): interlaminar shear at the arm root in the corner drop,
1.5 x 200 N / (12 x 4) = 6.3 MPa against about 60 MPa; motor screw bearing in the radial hit,
137.5 N per screw on Ø2 x 4 mm = 17 MPa against about 400 MPa; Euler buckling of a Ø2.4 Ti standoff
core, fixed-fixed over 27.5 mm, 9 370 N against 81 N; arm in axial compression at 550 N, free end,
over 1 000 N for any arm section that passes T6.

## 10. Hostile review: what was wrong in earlier drafts and the inputs, and what changed

1. The TypeScript loads (`electron/src/shared/sim/generative.ts:21`) take 0.18 x 9.81 = 1.77 N of
   thrust per motor. The F1404 KV4600 (M1) on 4S makes 2.85 to 3.4 N. Raised to 2.85 N, x3 punch.
2. Same file: a 0.12 mm tip deflection at 1.77 N is k = 14.75 N/mm, which with a 10.8 g motor and
   prop rings at about 178 Hz, not "well above 200 to 300 Hz" as its comment says. Replaced by
   k_z >= 57.1 N/mm per arm.
3. Same file: crash loads of 110 and 70 N split "half straight in, a third sideways" have no
   mechanics behind them. Replaced by crush-distance and effective-mass derivations: 550 N radial,
   130 N sideways, plus the bell-height moments, which twist and pitch the arm and were missing.
4. The engine cannot see the motor mass, so `min_frequency` on the bare plate would pass a wet
   noodle. Frequency is now a stiffness surrogate asserted by the test.
5. Skids under the motors looked protective; in a flat 3 m drop they make the arms the springs that
   stop the whole quad (over 500 N per arm). Removed; screws countersunk; the plate lands flat.
6. A sealed box cooks a 35 A ESC. Vents added (181 mm², 29 mm² ram-fed through the face plate), all
   2.0 mm wide; estimated rise about 12 K at 7 W.
7. A 6 mm opening criterion lets in prop shards and gravel. Tightened to a 4 mm ball and <= 3.2 mm
   openings, and a ray-escape fraction so a bar cage cannot pass.
8. Designing the roof and standoffs for the battery's full 288 g crash inertia was fiction: the pack
   is held by friction. Horizontal transfer capped at 100 N; the pack may slide, and the hood sits
   under its overhang with 1.4 mm.
9. The inverted 3 m drop puts 322.9 N through the roof, more than the upright one (235 N); it now
   sizes P2 and P4.
10. An adjustable camera tilt cannot coexist with a closed face; tilt is fixed per tub print.
11. Prop clearance as a flat cylinder over-restricted the cheeks; the true 3 mm envelope of the disc
    is rounded. Replaced by six stepped cylinders; the layout then fits at 140 mm with 0.85 mm margin.
12. Boards on grommets move about 0.5 mm in a crash: the tub's displacement limit is 0.8 mm against a
    1.5 mm designed gap.
13. Two-voxel walls in linear hexahedra can lock in bending: T0 measures it and scales P3.
14. Carbon plate in contact with board pads shorts them: the enclosure is nylon, the carbon plates
    face the tub floor and the roof tape, never a board.
15. The sample study `docs/generative/drone/studies/drone_bottom_plate.json` (written separately)
    uses 125 mm, 3 mm plate, x and y symmetry and allowable 600; it is not this product and should
    not be used to validate it.
16. A USB-C plug cannot reach a receptacle 2.7 mm behind a wall, and a slot big enough for its
    overmold breaks the 3.2 mm rule. The FC carries a short USB-C extension whose receptacle sits
    flush in the wall slot and fills it.
17. A 1.2 mm roof under a 322.9 N inverted landing is only just adequate on a beam estimate
    (190 MPa, 0.9 mm); flagged as the likeliest infeasible study with a defined fallback (3.2).

## 11. Open risks

- Mass margin is 1.1 g under 35.0 (0.6 g under the asserted 34.5). If P3 lands heavy, the levers are
  1.0 mm walls (needs voxel 0.5, over 400 000 voxels unless the engine accepts y-half domains) and a
  1.0 mm roof with the tub rim as a second support.
- The arm's 350 Hz holds only in the surrogate; a real tap test on the first frame is required.
- Battery ejection in nose-first crashes is accepted, not designed out.
- Concrete drops from 3 m are not survivable elastically and are not claimed.

## 12. As generated (run of 2026-11-06 evening, `cargo run --release --example drone`)

The example builds two generated parts, not the four of section 3: a unibody bottom plate (P1) and
one PA12-CF cage that takes the roles of P2, P3 and P4. Both are written to `drone/parts` and
summed in `drone-frame.json`; the example asserts that the frame mass equals the two parts' masses
and that the all-up mass equals made plus placed parts (51.35 g made, 221.69 g all up, in both files).

| Part | Mass | Stress / allowable | SF | f1 | Voxels | Time |
|---|---|---|---|---|---|---|
| `drone_bottom_plate`, carbon 4.0 mm | 37.60 g | 193.4 / 300 MPa (post hit peak 203.9) | 2.21 | 351 Hz with motors | 263 452 | 1 055 s |
| `drone_cage`, PA12-CF | 13.75 g | 33.6 / 36.7 MPa | 1.64 | 1 497 Hz | 914 634 | 483 s |

Plate:
- Free-body loads. Each spec case (punch, 30 cm corner drop, 550 N radial post hit with its bell
  lever, 130 N sideways hit, belly drop at 300 g) is balanced by the inertia of every part in
  translation and rotation (inertia relief about the centre of mass, 203.3 g at z 26.6), the
  plate held only at the hub, which then takes only the error of the plate's assumed 18 g.
- Motor and prop masses (11.32 g per pad) now sit on the pads in the modes: f1 351 Hz against the
  350 Hz floor, so the floor is the real arm-with-motor mode, no longer a surrogate.
- The pad moves at most 1.94 mm statically (radial hit) and 2.76 mm at the peak of the 3.33 ms
  post hit, under the 3.0 mm prop clearance. The static limit is set at 1.95 because the peak ran
  1.52 times the static value; the peak is checked against 3.0 (`max_impact_displacement`).
- Holes exact as before; one body; plate 4.000 mm thick.

Cage: a closed tub. Walls are 1.0 mm (two voxels), the floor on the plate is 0.5 mm and the tray is
the roof, round the stack, VTX, receiver, XIAO, capacitor, XT30 and camera, 0.5 mm clear of each.
They are cut only by the props' rounded 3 mm envelopes, the lens's view, a 3.2 mm antenna hole and
a 3.0 x 6 mm XT30 lead slot. A hood closes the down ToF off from the rear bay. The engine adds 1.8 g
of ribs to the standoffs' feet. The camera moved up 1.0 mm off the front ToF board, which it used to
overlap (6.2 mm3). Its side screws now sit at the body's middle (position UNCONFIRMED). The rear ToF
moved down 0.5 mm.

Checks on the written meshes (probes in the session scratchpad: `encl2.py`, `propclr.py`, `interf.py`):
- E2, 4 mm ball at 0.25 mm: reaches no ESC, FC, VTX, receiver, XIAO, capacitor or XT30; the camera
  only in its last 0.8 mm at the lens.
- E3 ray escape, 512 directions from about 300 surface points per body: mean 0.3 % (stack), 0.5 % (VTX),
  1.5 % (receiver), 1.8 % (XIAO), 0.0 % (capacitor); worst point 5.5 %.
- Prop discs: smallest distance 3.18 mm (cage), camera screws 3.25, rear ToF 3.40, standoffs 3.56.
- Interference: only screws in their threads and the camera screws in their pads.
- One closed shell per part; no trapped powder pocket (one between the XIAO and camera bays was
  opened into the cavity).

Mass: 51.3 g against the 35.0 g target of section 8, not met. The cage's fixed tub alone is
11.97 g (1.0 mm walls round the parts that must be enclosed), which leaves at most 23 g for the
plate. Under the spec's loads the least plate the optimiser finds is 27.5 g, and that one is
already at the static 3.0 mm limit and runs to 4.44 mm at the post hit's peak. The one that keeps
the peak under 3.0 mm is 37.6 g. The 35 g target therefore needs lighter loads (the 550 N radial
post hit with its 8.25 mm lever sizes the arms) or a different arm section (5 mm sheet, see
section 3); neither is a free choice here.

Decision (owner, 2026-11-07): 51.3 g is accepted. The frame limit is now 52.0 g, the loads and the
4.0 mm sheet stay as specified. All up 221.69 g gives thrust to weight 4 x 290 / 221.69 = 5.23: above
the required 5.0, below the 5.8 that section 8 asserted with the old frame.

Still open: the motor screws are button heads, not countersunk as item 5 of section 10 asks; ESC
vents (E4) are not cut; ToF wire holes are not drawn; the boards have 0.5 mm of air, not 1.0 mm (E1).
