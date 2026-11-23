# ViaForm on MuJoCo

Crate `mujoco/` (`viaform-mujoco`, our code under MIT OR Apache-2.0). MuJoCo
([google-deepmind/mujoco](https://github.com/google-deepmind/mujoco), Apache-2.0) as a second,
selectable physics backend next to the in-house engine (`phys/`). Both engines run the same
model, the same scenario and the same JSON ops; phys stays the default. Dependencies:
viaform-phys, viaform-kin, nalgebra, rayon, serde, and `cc` (build, with the feature only);
`viaform-generative` (GPL) is a dev-dependency only, for the G3 check in the cross test.

| Piece | What it does | Code |
|---|---|---|
| MJCF export | A phys model (assembly plus scenario, built-in, or any `PhysModel`) as MJCF: bodies, hinge, slide, ball and free joints with limits, damping, dry friction, armature and springs, full inertials, box, sphere, capsule, cylinder, convex hull (mesh) and plane geoms, phys's contact pair filter as explicit `<pair>` elements with phys's geometric mean friction, servos, DC motors and effort sources as `general` and `motor` actuators, fixed and routed tendons with the tendon motor, linkages as joint equalities. Pure Rust, no MuJoCo needed. | `src/mjcf.rs` |
| Loader | `world_new` parameters to the phys world both engines start from (phys's own scenario loader: one model, one initial state, one drive schedule). | `src/load.rs` |
| Bindings | A C shim compiled against the pinned `mujoco.h` (accessors, so no `mjModel` or `mjData` layout is mirrored in Rust) and hand-written `extern "C"` declarations. | `csrc/shim.c`, `src/ffi.rs`, `src/sim.rs` |
| World | One MuJoCo environment with phys's state layout, actuator semantics and records. Servos: MuJoCo's affine PD with implicit damping; each step the control is set from phys's deadbanded error on the quantised encoder reading and the force range to phys's torque-speed box at the present speed. Records: the G3 wrench history from `cfrc_int`, `cacc` and `cvel` after `mj_rnePostConstraint`, in phys's frames and sources. | `src/world.rs` |
| Facade | phys's ops with phys's parameters and reply shapes (`world_new`, `scenario_load`, `world_step`, `world_state`, `set_controls`, `episode_record`, `wrench_history`, `batch_new`, `batch_step`, `episode_start`, `job_poll`, `job_cancel`, `model_info`), plus `mjcf_export`. Without the feature, a stub that answers `engine.unavailable` ("MuJoCo backend not built"). | `src/facade.rs`, `src/stub.rs` |

## Selecting the engine

`world_new` or `scenario_load` through `vf_phys_call` takes `"engine": "phys" | "mujoco"`, at
the top level or in the scenario file (default `phys`). The handle then sends every op and
the binary entries (`vf_phys_step`, `vf_phys_state_poses`, `vf_phys_set_controls`) to that
engine; poses keep the flat `[x, y, z, qw, qx, qy, qz]` per link layout and `wrench_history`
keeps the shape that `generative/src/solid/sim_loads.rs` (G3) reads. `viaform_phys.h` is
unchanged. `mjcf_export` `{path?}` returns the current world as MJCF on either engine, or the
model given with `builtin`, `model`, or `assembly` + `scenario`, with or without the feature.

## Building

MuJoCo **3.17.0** is pinned (GitHub release tag of 2026-10-22; the 4.0 line came out on
2026-11-06 and 2026-11-11, newer than the two-week rule and a new major). Nothing of MuJoCo is
committed. The fetch script downloads the official prebuilt release from
`github.com/google-deepmind/mujoco/releases` only, checks the SHA-256 pinned in the script, and
unpacks it into a cache outside the repository:

```sh
mujoco/scripts/fetch-mujoco.sh
#   macOS: ~/Library/Caches/viaform-mujoco/3.17.0/mujoco.framework (from the .dmg, universal2),
#          plus LICENSE, THIRD_PARTY_NOTICES and MuJoCo.app (the simulate viewer)
#   Linux: ${XDG_CACHE_HOME:-~/.cache}/viaform-mujoco/3.17.0/{include,lib} (x86_64, aarch64)
cargo test --release -p viaform-mujoco --features mujoco -- --nocapture --test-threads 1
cargo build --release -p viaform-ffi --features mujoco
```

`MUJOCO_DIR` points the build at another copy (a framework's parent folder on macOS, a folder
with `include/` and `lib/` on Linux, for example a CMake build of the same tag). `build.rs`
compiles the shim with `cc`, copies the library into `OUT_DIR` (on macOS with an absolute
install name and an ad hoc signature, so test binaries and the bridge's tests find it without
`DYLD_*` variables), and links it. Without `--features mujoco` none of this runs and
`cargo test --workspace` needs no MuJoCo.

An app that ships the bridge with the feature must ship `libmujoco` with it (on macOS embed
`mujoco.framework` and set the rpath; the `OUT_DIR` copy is for development only).

To look at a model in MuJoCo's viewer:

```sh
cargo run --release -p viaform-mujoco --example export_mjcf    # sample arm, table, cube
open ~/Library/Caches/viaform-mujoco/3.17.0/MuJoCo.app --args "$PWD/docs/samples/arm/arm-scene.mjcf.xml"
```

`docs/samples/arm/arm-scene.mjcf.xml` is that export (the kinematic MJCF that core's assembly
export writes, `docs/samples/arm/arm.xml`, has no actuators, contacts or masses from phys).

## Platforms

| Platform | Status |
|---|---|
| macOS (arm64, x86_64) | Supported: official universal2 framework. Tested here. |
| Linux (x86_64, aarch64) | Supported by the fetch script and `build.rs` (official tarball); CI job `mujoco` builds and tests it. |
| Windows | Not wired (an official zip exists; `build.rs` stops with a message). |
| iOS, iPadOS, visionOS | **Not supported.** MuJoCo publishes no iOS or iPadOS library, and `build.rs` refuses those targets. The Apple apps keep phys on device; a MuJoCo run there would need a static build of MuJoCo for iOS from source (CMake, no OpenGL, no plugins), which this crate does not do. The MJCF export works everywhere. |

## Cross-validation

`cargo test --release -p viaform-mujoco --features mujoco --test cross -- --nocapture --test-threads 1`
(Apple M-series, 2026-11-22, MuJoCo 3.17.0). Both engines run the same phys model.

| Check | phys | MuJoCo | Gap |
|---|---|---|---|
| Double pendulum, 2 s free swing from (1.2, -0.6) rad, RK4 dt 1e-4 | | | 1.2e-14 rad |
| same, default integrators (phys semi-implicit, MuJoCo implicitfast) dt 1e-3 | | | 1.5e-15 rad |
| Sample arm holding its home pose 1 s: base joint force against the weight 4.6794 N | 4.6794 N (0.000 %) | 4.6794 N (0.000 %) | 0 |
| Box on a 30 deg incline, mu 0.5, Coulomb 0.65715 m/s^2 (0.5 to 10 s) | 0.65715 (0.00 %) | 0.68821 (+4.7 %) | 4.7 % |
| Box on a 20 deg incline, mu 0.5 (sticks): slip over 9.5 s | 3.6 um | 9.3 mm | creep |
| Sample arm pick scenario, 2 s, joint angles (max / RMS) | | | 0.28 / 0.12 deg (shoulder lift), 0.27 / 0.07 deg (elbow), 0.18 / 0.07 deg (wrist pitch) |
| same, servo torques (max gap, phys peak) | | | 0.14 of 1.22 N m, 0.19 of 0.64 N m, 0.10 of 0.19 N m |
| same, base joint wrench history (200 samples) | | | 0.57 N of 9.8 N, 0.20 N m of 2.6 N m (1.46 N and 1.03 N m with the first sample, where phys's servos are still crossing their backlash) |

Throughput, sample arm pick scenario (six servos, table, cube, 26 contact pairs):

| Case | phys | MuJoCo |
|---|---|---|
| One world, one thread | 16 k steps/s | 250 k to 270 k steps/s |
| 64 worlds on rayon | 170 k to 180 k env steps/s | 1.6 M to 1.7 M env steps/s |

Where the gaps come from:

- **Contacts.** MuJoCo's soft contact has no correction for the convex model's lift-off of
  sliding bodies (phys has one), so a sliding box hops; with stiffer contacts it gets worse
  (+140 % at a 2 ms time constant). The export keeps MuJoCo's default 0.02 s contact time
  constant (`CONTACT_TIMECONST`), which gives the +4.7 % and lets a sticking box creep.
  Joint limits and linkages use two steps (2 ms).
- **Servos.** Backlash is not modelled in MuJoCo (the export lists it in `model_info.notes`).
  The PD law, deadband, encoder quantisation and torque-speed box match phys.
- **DC motors.** Armature inductance is not modelled (current follows the voltage at once).
- **Tendon cables** are one-sided through the actuator's force range; a slack cable with a
  fast pull keeps its damping term (phys clips it).
- The drone (rotors, drag, battery, motor heat) runs on phys only (`engine.unsupported`).

## Licences and notices

- MuJoCo is Apache-2.0 (copyright DeepMind Technologies Limited), which may be combined with
  GPL-3.0-or-later code (Apache-2.0 into GPLv3 is compatible) and with MIT OR Apache-2.0 code.
- The repository holds no MuJoCo code or binaries: the shim and bindings are ours, the library
  is fetched into a user cache and linked at build time.
- Anyone who **redistributes** a build with the feature (an app bundle, a package) ships MuJoCo
  in binary form and must, per Apache-2.0 section 4: include MuJoCo's `LICENSE`, keep its
  copyright notices, and pass on the notices of the libraries MuJoCo bundles, which the release
  lists in `THIRD_PARTY_NOTICES` (libccd, Qhull, TinyXML2, LodePNG and others, under MIT, BSD,
  Zlib, Apache-2.0 and similar terms; Glslang's entry carries Bison's parser skeleton under
  GPL-3.0 with the Bison exception, which allows shipping it inside a larger work under any
  terms). The 3.17.0 source tree has no `NOTICE` file, so section
  4(d) adds nothing beyond those two files; check again when the pin moves. Both files land next
  to the framework in the cache (`fetch-mujoco.sh` copies them).
- `docs/specs/LICENSING.md` lists MuJoCo among the third-party components.
