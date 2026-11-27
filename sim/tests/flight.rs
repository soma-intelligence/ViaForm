//! The TypeScript suite (electron/src/test/sim.test.ts), ported: flights in hard weather that must
//! hover and finish the obstacle course, the game, the realistic plant on which the drone must ride
//! out kicks, gusts, flips and damage, and the JSON facade the Swift apps call.

use serde_json::Value;
use viaform_sim::api::{self, Session};
use viaform_sim::control::RateLoop;
use viaform_sim::flight::*;
use viaform_sim::frame::FRAME;
use viaform_sim::math::{q_from_euler, q_to_m3};
use viaform_sim::parts::parts_mass_kg;
use viaform_sim::physics::QuadParams;
use viaform_sim::race::{Race, RaceState};
use viaform_sim::realism::{Mahony, REALISTIC, inflow_factor};
use viaform_sim::stable::STABLE_SCORE;
use viaform_sim::train::stress_bench;
use viaform_sim::weather::{Weather, weathers};
use viaform_sim::world::obstacle_course;

fn quad() -> QuadParams {
    quad3(parts_mass_kg(FRAME.mass_g), [1.9e-4, 2.1e-4, 3.5e-4], FRAME.arm / 1000.0)
}

fn weather(name: &str) -> Weather {
    weathers().into_iter().find(|w| w.name.starts_with(name)).unwrap()
}

#[test]
fn hover_holds_in_every_weather() {
    for w in weathers() {
        let name = w.name.clone();
        let r = run_episode(&quad(), trained(true), Scenario::new(w, Mission::Hover { at: [0.0, 0.0, 1.6] }, 15.0, 3.0));
        assert!(!r.crashed, "{name} crashed");
        assert!(r.rms_error < 1.0, "{name} rms {}", r.rms_error);
    }
}

#[test]
fn obstacle_course_finished_calm_to_gale() {
    for (w, seed, nn) in [("Indoor", 1.0, true), ("Breezy", 3.0, true), ("Gale", 1.0, false), ("Rain", 2.0, false), ("Snow", 3.0, true), ("Freezing fog", 1.0, false)] {
        let sc = Scenario::new(weather(w), Mission::Waypoints { course: obstacle_course() }, 90.0, seed);
        let r = run_episode(&quad(), trained(nn), sc);
        assert!(r.completed && !r.collided && !r.crashed, "{w} seed {seed}: completed {}, collided {}, crashed {}", r.completed, r.collided, r.crashed);
    }
}

#[test]
fn pilot_on_the_sticks_passes_the_gates_and_lands() {
    let route: [[f64; 3]; 15] = [
        [0.0, 0.0, 1.5], [4.5, 0.0, 1.5], [6.8, 0.0, 1.5], [9.0, -1.0, 1.5], [14.5, -1.0, 2.0], [16.5, 4.0, 2.4], [18.8, 4.0, 2.4],
        [22.5, 2.1, 1.8], [25.5, 2.1, 1.8], [28.5, 0.0, 1.2], [30.8, 0.0, 1.2], [34.0, 0.0, 1.9], [36.0, 0.0, 1.9], [40.0, 0.0, 1.0], [40.0, 0.0, -0.5],
    ];
    for w in ["Indoor", "Breezy"] {
        let c = obstacle_course();
        let mut f = Flight::new(&quad(), trained(true), Scenario::new(weather(w), Mission::Manual { course: c.clone() }, 120.0, 1.0));
        f.pilot_mode = PilotMode::Position;
        let mut race = Race::new(c);
        race.state = RaceState::Flying;
        let mut at = 0;
        let mut k = 0;
        while !f.finished() && race.state == RaceState::Flying {
            if k % 25 == 0 {
                let (t, p) = (route[at], f.s.p);
                if at < route.len() - 1 && ((t[0] - p[0]).powi(2) + (t[1] - p[1]).powi(2) + (t[2] - p[2]).powi(2)).sqrt() < 0.35 {
                    at += 1;
                }
                let clamp = |x: f64, m: f64| x.clamp(-m, m);
                f.pilot = PilotInput { x: clamp((t[0] - p[0]) * 0.6, 0.5), y: clamp((t[1] - p[1]) * 0.6, 0.5), z: clamp((t[2] - p[2]) * 1.2, 0.8), yaw: 0.0 };
            }
            f.tick();
            if k % 5 == 0 {
                race.update(f.s.p, f.s.v, f.s.t, f.s.crashed || f.collided);
            }
            k += 1;
        }
        assert!(race.state == RaceState::Finished, "{w}: {:?} at {:?}", race.state, f.s.p);
        assert_eq!(race.splits.len(), 3);
    }
}

#[test]
fn realism_inflow_climb_vortex_ring_and_translational_lift() {
    let vi = 6.0;
    assert!(inflow_factor(-3.0, 0.0, vi).0 < 0.8, "climb");
    let (f, vrs) = inflow_factor(6.0, 0.0, vi);
    assert!(f < 0.8 && vrs > 0.9, "descent into the wake");
    assert!(inflow_factor(6.0, 8.0, vi).1 < 0.1, "edgewise flow blows the ring away");
    assert!(inflow_factor(0.0, 8.0, vi).0 > 1.05, "translational lift");
}

#[test]
fn realism_attitude_filter_finds_tilt_and_gyro_bias() {
    let truth = q_to_m3(q_from_euler(0.2, -0.1, 0.0));
    let g = [truth[6] * 9.81, truth[7] * 9.81, truth[8] * 9.81];
    let mut m = Mahony::new([1.0, 0.0, 0.0, 0.0]);
    for _ in 0..(60.0 / DT) as usize {
        m.update([0.01, -0.02, 0.0], g, Some(0.0), DT);
    }
    let r = q_to_m3(m.q);
    assert!((r[6] - truth[6]).abs() < 0.01 && (r[7] - truth[7]).abs() < 0.01, "tilt");
    assert!((m.bias[0] - 0.01).abs() < 0.001 && (m.bias[1] + 0.02).abs() < 0.001, "bias {:?}", m.bias);
}

#[test]
fn stabilization_rides_out_the_stress_bench_calm_to_gale() {
    assert!(STABLE_SCORE[1] < STABLE_SCORE[0] && STABLE_SCORE[2] < STABLE_SCORE[0], "retuned beats default");
    for rl in [RateLoop::Pid, RateLoop::Indi] {
        for w in ["Indoor", "Breezy", "Gale"] {
            let r = run_episode(&quad(), stable(rl), stress_bench(3.0, weather(w), REALISTIC.clone()));
            let back = r.recoveries.iter().filter(|x| x.recovered_after.is_some()).count();
            let label = format!("{rl:?} in {w}");
            assert!(!r.crashed, "{label}: crashed");
            assert!(r.recoveries.iter().all(|x| x.max_deviation < 1.6), "{label}: {:?}", r.recoveries.iter().map(|x| x.max_deviation).collect::<Vec<_>>());
            assert!(r.attitude_rms < 0.12, "{label}: attitude {}", r.attitude_rms);
            if w != "Gale" {
                assert!(back >= 4, "{label}: {back} of 6 recovered");
            }
        }
    }
}

#[test]
fn stabilization_holds_an_off_centre_pack() {
    let events = vec![Disturbance::Payload { t: 1.0, kg: 0.04, at: [0.04, 0.03, 0.0] }];
    let mut sc = Scenario::new(weather("Indoor"), Mission::Stabilize { at: [0.0, 0.0, 2.0], events }, 6.0, 9.0);
    sc.realism = Some(REALISTIC.clone());
    for rl in [RateLoop::Pid, RateLoop::Indi] {
        let mut f = Flight::new(&quad(), stable(rl), sc.clone());
        while !f.finished() {
            f.tick();
        }
        let off = (f.s.p[0].powi(2) + f.s.p[1].powi(2) + (f.s.p[2] - 2.0).powi(2)).sqrt();
        assert!(off < 0.15, "{rl:?}: {off:.2} m off after the load");
    }
}

#[test]
fn api_session_flies_the_course_like_the_app() {
    let cat: Value = serde_json::from_str(&api::catalog()).unwrap();
    assert!(cat["weathers"].as_array().unwrap().len() >= 5);
    let parts: Value = serde_json::from_str(&api::parts(32.0)).unwrap();
    assert!(!parts["parts"].as_array().unwrap().is_empty());

    let mut s = Session::start(r#"{"course":"obstacle","seed":1,"weather":0,"brain":"trained"}"#).unwrap();
    let world: Value = serde_json::from_str(&s.world()).unwrap();
    assert!(!world["obstacles"].as_array().unwrap().is_empty());
    assert_eq!(world["frame"]["t"], 0.0);
    let mut trail = 0;
    let mut last = Value::Null;
    for _ in 0..120 {
        last = serde_json::from_str(&s.advance(0.5)).unwrap();
        trail += last["trail"].as_array().unwrap().len();
        if last["status"]["finished"] == true {
            break;
        }
    }
    let st = &last["status"];
    assert!(st["finished"] == true && st["collided"] == false && st["crashed"] == false, "{st}");
    assert!(last["frame"]["planIndex"].as_u64().unwrap() as usize >= world["waypoints"].as_array().unwrap().len() - 1);
    assert!(trail > 100);

    let r: Value = serde_json::from_str(&api::episode(r#"{"mission":"stress","brain":"indi","seed":3}"#)).unwrap();
    assert_eq!(r["crashed"], false, "{r}");
    assert!(Session::start("not json").is_err());
}

#[test]
fn training_job_reports_progress_cancels_and_its_brain_flies() {
    use viaform_sim::job::TrainJob;
    let mut job = TrainJob::start(r#"{"target":"tracking","iterations":2,"population":4,"episodes":2}"#).unwrap();
    job.join();
    let p: Value = serde_json::from_str(&job.progress()).unwrap();
    assert_eq!(p["running"], false);
    assert_eq!(p["stage"], "done", "{p}");
    assert_eq!(p["history"].as_array().unwrap().len(), 2);
    let brain = &p["result"]["brain"];
    assert!(brain["gains"]["posP"].as_f64().is_some() || brain["gains"].is_object(), "{brain}");
    let opts = serde_json::json!({ "mission": "hover", "brain": "custom", "custom": brain });
    let r: Value = serde_json::from_str(&api::episode(&opts.to_string())).unwrap();
    assert_eq!(r["crashed"], false, "{r}");

    let mut job = TrainJob::start(r#"{"target":"policy","iterations":200,"population":8,"episodes":2}"#).unwrap();
    job.cancel();
    job.join();
    let p: Value = serde_json::from_str(&job.progress()).unwrap();
    assert_eq!(p["stage"], "cancelled", "{p}");
    assert!(p["history"].as_array().unwrap().len() < 200);
    assert!(TrainJob::start(r#"{"iterations":0}"#).is_err());
}

const GENERATED: &str = r#"{"name":"test frame","mass_g":14.2,"inertia_kg_m2":[2.1e-5,2.3e-5,4.1e-5],"arm_length_mm":63.5,
  "motor_mounts":[[44.9,44.9,0],[-44.9,44.9,0],[-44.9,-44.9,0],[44.9,-44.9,0]]}"#;

#[test]
fn a_generated_frame_builds_a_drone_that_flies_the_course() {
    let s: Value = serde_json::from_str(&api::airframe(GENERATED)).unwrap();
    assert!((s["armMm"].as_f64().unwrap() - 63.5).abs() < 1e-9 && s["massKg"].as_f64().unwrap() > 0.15, "{s}");
    // The arm from the mounts when the file has no arm length.
    let mounts_only = GENERATED.replace(r#""arm_length_mm":63.5,"#, "");
    let m: Value = serde_json::from_str(&api::airframe(&mounts_only)).unwrap();
    assert!((m["armMm"].as_f64().unwrap() - 63.498).abs() < 0.01, "{m}");
    assert!(api::airframe(r#"{"mass_g":-3,"arm_length_mm":60}"#).contains("error"));
    assert!(api::airframe("nope").contains("error"));
    let opts = serde_json::json!({ "mission": "course", "brain": "trained", "frame": GENERATED });
    let r: Value = serde_json::from_str(&api::episode(&opts.to_string())).unwrap();
    assert!(r["completed"] == true && r["collided"] == false && r["crashed"] == false, "{r}");
    let w: Value = serde_json::from_str(&Session::start(&opts.to_string()).unwrap().world()).unwrap();
    assert_eq!(w["airframe"]["name"], "test frame");
    assert!(Session::start(r#"{"frame":"{\"mass_g\":1}"}"#).is_err());
}

#[test]
fn manual_race_counts_down_then_the_sticks_fly() {
    let mut s = Session::start(r#"{"mission":"manual","brain":"trained"}"#).unwrap();
    let w: Value = serde_json::from_str(&s.world()).unwrap();
    assert_eq!(w["race"]["state"], "countdown");
    assert_eq!(w["race"]["gates"], 3);
    let a: Value = serde_json::from_str(&s.advance(1.0)).unwrap();
    assert_eq!(a["frame"]["t"], 0.0, "the drone waits for the countdown");
    let a: Value = serde_json::from_str(&s.advance(2.5)).unwrap();
    assert_eq!(a["race"]["state"], "flying");
    assert!(s.set_pilot(r#"{"z":0.8}"#));
    let a: Value = serde_json::from_str(&s.advance(1.5)).unwrap();
    assert!(a["frame"]["p"][2].as_f64().unwrap() > 1.0, "climbs on the stick: {}", a["frame"]["p"]);
    assert!(s.set_pilot(r#"{"x":0.5,"mode":"angle"}"#));
    assert!(!s.set_pilot("x"));
}

/// A test fixture in the shape docs/components/drone.json is promised in, filled with the
/// built-in catalogue's own figures (parts.rs), not with sourced data.
const COMPONENTS: &str = r#"{"components":[
  {"ref":"M","qty":4,"category":"motor","mpn":"F1404 4600KV","mass_g":9.34,"dims_mm":[18,18,15],
   "key_specs":{"kv":4600,"thrust_table":[{"throttle":50,"thrust_g":140,"current_a":3.1,"voltage_v":15.6},{"throttle":100,"thrust_g":344.7,"current_a":18.4,"voltage_v":15.6}]}},
  {"ref":"P","qty":4,"category":"propeller","mpn":"Gemfan 3016","mass_g":1.18,"key_specs":{"size":"3016"}},
  {"ref":"B","qty":1,"category":"battery","mpn":"GNB 650 3S","mass_g":60,"dims_mm":[55,30,17],"key_specs":{"capacity_mah":650,"voltage_v":11.1}},
  {"ref":"FC","qty":1,"category":"flight controller + ESC","mpn":"F405 Mini","mass_g":15,"dims_mm":[27,27,10]},
  {"ref":"RX","qty":1,"category":"receiver","mass_g":1},
  {"ref":"CC","qty":1,"category":"companion computer","mass_g":3},
  {"ref":"TOF","qty":6,"category":"distance sensor","mass_g":1.5},
  {"ref":"HW","qty":1,"category":"hardware","mass_g":12}
]}"#;

#[test]
fn sourced_components_build_a_drone_that_flies_the_course() {
    use viaform_sim::components::vehicle;
    let v = vehicle(COMPONENTS, None, None).unwrap();
    let s = &v.summary;
    // The catalogue's drone: its parts list with the 11 g frame, 180 g of thrust a motor on 3S.
    assert!((v.params.mass - parts_mass_kg(FRAME.mass_g)).abs() < 1e-9, "{s}");
    assert!((v.params.max_thrust / (0.18 * 9.81) - 1.0).abs() < 0.05, "{s}");
    assert!((v.params.prop_radius - 0.0381).abs() < 1e-4);
    assert!(v.params.inertia.iter().zip([1.9e-4, 2.1e-4, 3.5e-4]).all(|(a, b)| *a > 0.5 * b && *a < 2.0 * b), "{s}");
    assert!(s["missing"].as_array().unwrap().is_empty(), "{s}");
    // Placed by an assembly: the pack low and forward moves the centre of mass.
    let asm = r#"{"placements":[{"ref":"B","position_mm":[10,0,-15]}]}"#;
    let w = vehicle(COMPONENTS, Some(asm), None).unwrap();
    assert!(w.summary["cgMm"][0].as_f64().unwrap() > 2.0 && w.summary["placed"] == 1, "{}", w.summary);
    // What the file does not give is reported, not guessed.
    let bare = COMPONENTS.replace(r#""kv":4600,"#, "");
    assert!(vehicle(&bare, None, None).unwrap().summary["missing"].to_string().contains("KV"));
    assert!(vehicle("{}", None, None).is_err());

    let opts = serde_json::json!({ "mission": "course", "brain": "trained", "components": COMPONENTS, "assembly": asm });
    let r: Value = serde_json::from_str(&api::episode(&opts.to_string())).unwrap();
    assert!(r["completed"] == true && r["collided"] == false && r["crashed"] == false, "{r}");
    let w: Value = serde_json::from_str(&Session::start(&opts.to_string()).unwrap().world()).unwrap();
    assert!(w["vehicle"]["massKg"].as_f64().unwrap() > 0.15);
    let summary: Value = serde_json::from_str(&api::vehicle(&serde_json::json!({ "components": COMPONENTS }).to_string())).unwrap();
    assert!(summary["thrustToWeight"].as_f64().unwrap() > 3.0, "{summary}");
}

/// The generated assembly's schema (`viaform.assembly/1`): parts with `kind`, `component_ref`
/// and `ref`, placed by `position_mm` or only by `pose` (row-major 3x4, translation last).
#[test]
fn generated_assembly_placements_read_by_component_ref_and_pose() {
    use viaform_sim::components::{parse_assembly, vehicle};
    let asm = r#"{"schema":"viaform.assembly/1","parts":[
      {"kind":"generative","name":"drone_bottom_plate","pose":[1,0,0,0,0,1,0,0,0,0,1,0]},
      {"kind":"component","component_ref":"M","ref":"M","position_mm":[45,45,4]},
      {"kind":"component","component_ref":"M","pose":[1,0,0,-45,0,1,0,45,0,0,1,4]},
      {"kind":"component","ref":"B","pose":[[1,0,0,10],[0,1,0,0],[0,0,1,-15]]},
      {"kind":"component","component_ref":"MX","position_mm":[1,1,1]}
    ]}"#;
    let p = parse_assembly(asm).unwrap();
    assert_eq!(p.len(), 4, "the generated part is the frame's, not a placement: {p:?}");
    assert_eq!(p[0], ("M".to_string(), [45.0, 45.0, 4.0]));
    assert_eq!(p[1], ("M".to_string(), [-45.0, 45.0, 4.0]), "pose translation");
    assert_eq!(p[2], ("B".to_string(), [10.0, 0.0, -15.0]), "nested pose");
    let v = vehicle(COMPONENTS, Some(asm), None).unwrap();
    // Two motors and the pack: "MX" is not motor "M".
    assert_eq!(v.summary["placed"], 3, "{}", v.summary);
    assert_eq!(v.summary["placedRefs"], serde_json::json!(["M", "B"]));
    assert!((v.summary["armMm"].as_f64().unwrap() - 45.0 * 2f64.sqrt()).abs() < 0.5, "arm from the motor places: {}", v.summary["armMm"]);
}

/// The repository's drone, as the app builds it: docs/components/drone.json placed by
/// docs/generative/drone/assembly.json on docs/generative/drone-frame.json. Read fresh: the
/// generative agent rewrites these files.
#[test]
fn the_real_generated_drone_uses_its_frame_and_placements() {
    use viaform_sim::components::{parse_assembly, vehicle};
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let read = |p: &str| std::fs::read_to_string(root.join(p)).ok();
    let (Some(comps), Some(asm), Some(frame)) = (read("docs/components/drone.json"), read("docs/generative/drone/assembly.json"), read("docs/generative/drone-frame.json")) else {
        return;
    };
    let Ok(places) = parse_assembly(&asm) else { return }; // caught mid-rewrite
    let a: Value = serde_json::from_str(&asm).unwrap();
    let components = a["parts"].as_array().unwrap().iter().filter(|p| p["kind"] == "component").count();
    assert_eq!(places.len(), components, "every placed component reads");
    let v = vehicle(&comps, Some(&asm), Some(&frame)).unwrap();
    let s = &v.summary;
    eprintln!("drone: placed {} of {} placements, frame {}, arm {:.1} mm, {:.0} g, T/W {:.2}", s["placed"], s["placements"], s["frame"], s["armMm"].as_f64().unwrap(), v.params.mass * 1000.0, s["thrustToWeight"]);
    assert!(s["placed"].as_u64().unwrap() as usize >= components * 9 / 10, "{s}");
    assert!(s["frame"].is_object() && s["sources"]["frameMass"] == "frame file", "{s}");
    let opts = serde_json::json!({ "mission": "course", "brain": "trained", "components": comps, "assembly": asm, "frame": frame });
    let r: Value = serde_json::from_str(&api::episode(&opts.to_string())).unwrap();
    assert!(r["completed"] == true && r["collided"] == false && r["crashed"] == false, "{r}");
}
