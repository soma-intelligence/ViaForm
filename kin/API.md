# viaform-kin public model API

For crates that build on the kinematic model (`phys` first). Everything here is public, stable
and documented in the source (`kin/src/model.rs`, `kin/src/fk.rs`, `kin/src/math.rs`). Changes to
names or meanings go through the kin owner; new optional fields may be added (serde defaults).

Depend on it with `viaform-kin.workspace = true` and use its re-exported nalgebra
(`viaform_kin::nalgebra`) so both crates share one nalgebra version (0.34).

## Math types (`viaform_kin::math`)

| Type | Meaning |
|---|---|
| `Vec3` | `nalgebra::Vector3<f64>` |
| `Mat3` | `nalgebra::Matrix3<f64>` |
| `UnitQuat` | `nalgebra::UnitQuaternion<f64>` |
| `Iso3` | `nalgebra::Isometry3<f64>`, a rigid pose, `p_world = pose * p_local` |
| `Jacobian` | `nalgebra::Matrix6xX<f64>`: rows linear velocity (x, y, z) then angular velocity (x, y, z), world frame |
| `Rng` | seeded ChaCha8 stream (`Rng::new(seed)`, `uniform`, `range`, `normal`, `rotation`) |

Helpers: `pose(pos, rot)`, `pose_xyz_rpy(xyz, rpy)` (URDF fixed-axis RPY), `pose_from7` /
`pose_to7` (`[x, y, z, qw, qx, qy, qz]`), `rot_error(target, current)` (log map of
`target * current^-1`, world frame), `skew`, `wrap_pi`, `pose_json` / `pose_from_json`.

Units: SI (m, rad, kg, s). Frames: right-handed, Z up.

## Model (`viaform_kin::Model`)

```rust
pub struct Model {
    pub name: String,
    pub links: Vec<Link>,            // links[0] = base, fixed to the world (identity pose)
    pub joints: Vec<Joint>,          // joint i joins joints[i].parent to child link i + 1
    pub actuators: Vec<Actuator>,    // motors and tendons
    pub couplings: Vec<Coupling>,    // actuator -> joint maps (gears, linkages, tendons)
    pub end_effectors: Vec<Frame>,   // named tool frames; FrameId = index here
}
pub struct Link { pub name: String, pub inertial: Option<Inertial> }
pub struct Inertial { pub mass: f64, pub com: Vec3, pub inertia: [f64; 6] } // about com, link axes: ixx iyy izz ixy ixz iyz
pub struct Joint { pub name: String, pub kind: JointKind, pub parent: usize, pub origin: Iso3, pub axis: Vec3, pub limits: Limits }
pub enum JointKind { Revolute, Prismatic, Continuous, Fixed, Spherical, Floating, Wheel }
pub struct Limits { pub lower: f64, pub upper: f64, pub velocity: f64, pub effort: f64 } // missing = infinite
pub struct Frame { pub name: String, pub link: usize, pub offset: Iso3 }
pub struct Actuator { pub name: String, pub drive: Drive, pub limits: Limits }
pub enum Drive { Motor, Tendon }   // tendon value = excursion, m, pull positive
pub struct Coupling { pub name: String, pub kind: CouplingKind, pub actuators: Vec<usize>, pub joints: Vec<usize>, pub matrix: Vec<f64>, pub offset: Vec<f64> }
pub enum CouplingKind { Linear, Tendon { routing: Vec<TendonPoint>, stiffness: f64, slack: f64 } }
pub struct TendonPoint { pub link: usize, pub pos: Vec3 }  // via point in link frame
```

Invariants after `Model::normalize()` (done by `from_json` / `from_value`):

- `links.len() == joints.len() + 1`, `joints[i].parent <= i` (topological order), so a single
  forward pass computes every link pose.
- Child pose: `T_child = T_parent * origin * motion(q_i)`. `axis` is a unit vector in the joint
  frame (`T_parent * origin`). Revolute, continuous and wheel rotate about it, prismatic slides
  along it.
- Continuous, wheel, floating and fixed joints have infinite position limits. A spherical
  joint's `limits.upper`, when finite, bounds its rotation angle.
- Every movable scalar joint (revolute, prismatic, continuous, wheel) is in exactly one
  coupling. Joints the file leaves uncoupled get a `Motor` actuator named after the joint and an
  identity `Linear` coupling (motor per joint). Spherical and floating joints are passive (no
  actuator).
- Coupling map: `q[joints[r]] = sum_c matrix[r * actuators.len() + c] * a[actuators[c]] + offset[r]`
  (row-major). A tendon coupling with an empty matrix gets it from its routing: moment arms
  `r_j = -dL/dq_j` at the neutral configuration, then `q_j = r_j a / sum r_k^2` (equal return
  springs). Slack and stiffness are for `phys`; kin does not model slack.

## Configuration and velocity layout

| Joint kind | `q` entries | `v` entries |
|---|---|---|
| Revolute, Prismatic, Continuous, Wheel | 1 (rad or m) | 1 |
| Fixed | 0 | 0 |
| Spherical | 4: unit quaternion `[w, x, y, z]` | 3: angular velocity in the child frame |
| Floating | 7: `[x, y, z]` in the joint frame, then `[qw, qx, qy, qz]` | 6: linear then angular velocity, child frame |

Stacked joint by joint. `q_offsets()` and `v_offsets()` give each joint's start.
`integrate(q, v)` composes on the right (`R * exp(w)`, `p += R v_lin`), `difference(q0, q1)` is
its inverse. `neutral()` is zeros clamped into limits, identity rotations.

## Functions

| Function | Returns |
|---|---|
| `Model::from_json(&str)`, `from_value(&Value)`, `to_json()` | load and normalise, or write |
| `nq()`, `nv()`, `q_offsets()`, `v_offsets()`, `neutral()`, `check_q(q)` | layout |
| `link_index`, `joint_index`, `frame_index`, `actuator_index` (by name) | `Option<usize>` |
| `fk(q) -> Vec<Iso3>` | world pose of every link (`[0]` = identity) |
| `fk_into(q, &mut Vec<Iso3>)` | same, no allocation, no checks |
| `joint_motion(j, q_slice) -> Iso3` | `T_joint_child` of one joint |
| `frame_pose(&poses, frame)`, `fk_frame(q, frame)` | tool frame pose |
| `jacobian(q, frame) -> Jacobian` | geometric Jacobian of the frame origin |
| `jacobian_into(&poses, link, &p_world, &mut Jacobian)` | Jacobian of any point fixed on `link` |
| `point_jacobian(&poses, link, &p_world) -> Matrix3xX` | linear part only |
| `integrate(q, v)`, `difference(q0, q1)`, `random_q(&mut Rng)` | configuration space |
| `drive_map() -> DriveMap` | IK variables: actuators then passive DOF, `dv = C dz` |
| `to_actuators(q)`, `from_actuators(a)`, `apply_actuators(a, &mut q)` | actuator space |
| `actuator_bounds()` | actuator limits intersected with single-actuator joint limits |
| `tendon_length(q, coupling)`, `tendon_moment_arms(q, coupling)` | tendon geometry for `phys` |

Jacobian columns (world frame, about the point `p`): revolute `[z x (p - o); z]`, prismatic
`[z; 0]`, spherical and floating one column per child-frame axis, matching `integrate`. Checked
against central finite differences (step 1e-7, relative error under 1e-6) on a tree with every
joint kind.

## JSON form

Same field names as the structs. Poses are `{"xyz": [..], "quat_wxyz": [..]}` (input may use
URDF `"rpy": [..]` instead), vectors `[x, y, z]`, infinite limits `null` or absent, enums
snake_case (`"revolute"`, `"motor"`, `{"type": "tendon", "routing": [...]}`). Reference files:
`kin/models/so101_class_arm.json`, `kin/models/hand5.json` (also `viaform_kin::models`).

## Errors

`KinError { code, message, index }` with stable codes in `viaform_kin::error::codes`
(`model.parse`, `model.invalid`, `name.unknown`, `vector.invalid`, ...).
