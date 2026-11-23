use super::*;

fn ids(f: &Flow) -> Vec<String> {
    f.graph().artifacts.iter().map(|a| a.id.clone()).collect()
}

fn build_all(f: &mut Flow) {
    for a in ids(f) {
        f.produce(&a, Build::default()).unwrap();
    }
}

fn b(s: &str) -> Build {
    Build::summary(s)
}

// MARK: Propagation

#[test]
fn a_new_project_is_empty() {
    let f = Flow::new();
    assert!(STAGES.iter().all(|s| f.stage_status(s.0) == Status::Empty));
}

#[test]
fn building_in_order_leaves_everything_current() {
    let mut f = Flow::new();
    build_all(&mut f);
    assert!(ids(&f).iter().all(|a| f.status(a) == Status::Current));
}

#[test]
fn a_new_frame_stales_everything_built_from_it() {
    let mut f = Flow::new();
    build_all(&mut f);
    f.produce("generate.frame", b("outcome #13")).unwrap();
    for id in ["assemble.assembly", "simulate.flight", "train.policy", "render.shots", "make.bundle"] {
        assert_eq!(f.status(id), Status::Stale, "{id}");
    }
    for id in ["design.model", "generate.frame", "electronics.board"] {
        assert_eq!(f.status(id), Status::Current, "{id}");
    }
    assert_eq!(f.downstream("generate.frame"), ["assemble.assembly", "simulate.flight", "train.policy", "render.shots", "make.bundle"]);
}

#[test]
fn staleness_carries_through_an_unrebuilt_middle() {
    let mut f = Flow::new();
    build_all(&mut f);
    f.produce("electronics.board", Build::default()).unwrap();
    assert_eq!(f.status("simulate.flight"), Status::Stale);
    f.produce("assemble.assembly", Build::default()).unwrap();
    assert_eq!(f.status("assemble.assembly"), Status::Current);
    assert_eq!(f.status("simulate.flight"), Status::Stale);
}

#[test]
fn plan_update_lists_stale_upstream_in_build_order() {
    let mut f = Flow::new();
    build_all(&mut f);
    f.produce("design.model", Build::default()).unwrap();
    assert_eq!(f.plan_update("train.policy"), ["generate.frame", "assemble.assembly", "simulate.flight", "train.policy"]);
    assert!(f.plan_update("electronics.board").is_empty());
}

#[test]
fn jobs_run_then_build_or_fail() {
    let mut f = Flow::new();
    let j = f.job_start("train.policy", "Training", "PPO, 16 envs", 0.0).unwrap();
    f.job_progress(j, Some(0.4), None, None, None).unwrap();
    assert_eq!(f.status("train.policy"), Status::Running);
    assert_eq!(f.state_at(10.0)["jobs"][0]["progress"], 0.4);
    f.job_end(j, Some("diverged"), Build::default()).unwrap();
    assert_eq!(f.status("train.policy"), Status::Failed);
    assert_eq!(f.stage_status("train"), Status::Failed);
    let j = f.job_start("train.policy", "Training", "retry", 0.0).unwrap();
    f.job_end(j, None, b("policy v2")).unwrap();
    assert_eq!(f.status("train.policy"), Status::Current);
    assert_eq!(f.state()["nodes"][5]["summary"], "policy v2");
}

#[test]
fn commands_answer_json() {
    let mut f = Flow::new();
    assert_eq!(f.command(&json!({"op": "produce", "artifact": "design.model"}))["revision"], 1);
    assert!(f.command(&json!({"op": "produce", "artifact": "nope"}))["error"].is_string());
    assert!(f.command(&json!({"op": "job_progress", "artifact": "design.model", "progress": 0.5}))["error"].is_string());
    assert!(f.command(&json!({"op": "fly"}))["error"].is_string());
    let s = f.state();
    assert_eq!(s["stages"].as_array().unwrap().len(), 8);
    assert_eq!(s["stages"][0]["status"], "current");
    // The old way of ending work with no job (a plain build by artifact) still works.
    assert_eq!(f.command(&json!({"op": "job_end", "artifact": "electronics.board", "summary": "rev"}))["revision"], 1);
}

// MARK: Revisions

#[test]
fn revisions_have_names_reasons_and_a_rerun_action() {
    let mut f = Flow::new();
    for _ in 0..11 {
        f.produce("generate.frame", Build::default()).unwrap();
    }
    for _ in 0..3 {
        f.produce("electronics.board", Build::default()).unwrap();
    }
    f.produce("assemble.assembly", Build::default()).unwrap();
    f.produce("generate.frame", b("outcome 13")).unwrap();
    let s = f.state();
    let node = |id: &str| s["nodes"].as_array().unwrap().iter().find(|n| n["id"] == id).unwrap().clone();
    assert_eq!(node("generate.frame")["revision_name"], "Frame v12");
    assert_eq!(node("electronics.board")["revision_name"], "Board rev C");
    assert_eq!(node("assemble.assembly")["reason"], "Frame v12 replaced v11");
    assert_eq!(node("assemble.assembly")["action"]["label"], "Re-run on Frame v12");
    f.produce("simulate.flight", Build::default()).unwrap();
    f.produce("assemble.assembly", Build::default()).unwrap();
    assert_eq!(f.reason("simulate.flight"), "Assembly v2 replaced v1");
    assert_eq!(f.action("simulate.flight")["label"], "Re-run on Assembly v2");
    assert_eq!(node("design.model")["action"]["label"], Value::Null, "an empty source has nothing to build from");
}

#[test]
fn promote_activate_and_diff() {
    let mut f = Flow::new();
    f.produce("design.model", Build::default()).unwrap();
    f.produce("generate.frame", Build { data: json!({"mass_g": 161, "cost": 4}), ..b("best") }).unwrap();
    f.produce("assemble.assembly", Build::default()).unwrap();
    let r = f.command(&json!({"op": "promote", "artifact": "generate.frame", "from": "Outcome 13", "data": {"mass_g": 153, "cost": 4}}));
    assert_eq!(r["revision"], 2, "{r}");
    let list = f.revisions("generate.frame").unwrap();
    assert_eq!(list["revisions"][1]["name"], "Frame v2");
    assert_eq!(list["revisions"][1]["source"], "promote");
    assert_eq!(list["revisions"][1]["from"], "Outcome 13");
    assert_eq!(list["revisions"][0]["used_by"], json!(["assemble.assembly"]));
    let d = f.diff("generate.frame", None, None).unwrap();
    assert_eq!(d["from"], "Frame v1");
    assert_eq!(d["to"], "Frame v2");
    assert_eq!(d["figures"], json!([{"key": "mass_g", "from": 161, "to": 153}]));
    assert_eq!(f.status("assemble.assembly"), Status::Stale);
    // Going back to v1 makes the assembly current again: it was built on v1.
    f.activate("generate.frame", 1).unwrap();
    assert_eq!(f.status("assemble.assembly"), Status::Current);
    assert!(f.activate("generate.frame", 9).is_err());
    // A new build after a rollback is still a new number.
    assert_eq!(f.produce("generate.frame", Build::default()).unwrap(), Built::New(3));
}

#[test]
fn undo_back_to_an_earlier_design_restores_its_revision() {
    let mut f = Flow::new();
    let fp = |s: &str| Build { fingerprint: Some(s.into()), source: Some("edit".into()), ..Build::default() };
    assert_eq!(f.produce("design.model", fp("a")).unwrap(), Built::New(1));
    f.produce("generate.frame", Build::default()).unwrap();
    assert_eq!(f.produce("design.model", fp("b")).unwrap(), Built::New(2));
    assert_eq!(f.status("generate.frame"), Status::Stale);
    // Undo: the content is v1's again.
    assert_eq!(f.produce("design.model", fp("a")).unwrap(), Built::Restored(1));
    assert_eq!(f.status("generate.frame"), Status::Current);
    // A refresh with nothing changed is not a revision.
    assert_eq!(f.produce("design.model", fp("a")).unwrap(), Built::Unchanged(1));
    assert_eq!(f.revisions("design.model").unwrap()["revisions"].as_array().unwrap().len(), 2);
}

#[test]
fn a_burst_of_edits_is_one_revision_until_something_uses_it() {
    let mut f = Flow::new();
    let edit = |s: &str| Build { fingerprint: Some(s.into()), source: Some("edit".into()), amend_within: Some(2.0), ..Build::default() };
    assert_eq!(f.produce_at("design.model", edit("a"), 100.0).unwrap(), Built::New(1));
    assert_eq!(f.produce_at("design.model", edit("b"), 101.0).unwrap(), Built::Amended(1));
    assert_eq!(f.produce_at("design.model", edit("c"), 102.5).unwrap(), Built::Amended(1));
    assert_eq!(f.produce_at("design.model", edit("d"), 110.0).unwrap(), Built::New(2));
    f.produce_at("generate.frame", Build::default(), 110.5).unwrap();
    // The frame was built on v2, so the next edit cannot fold into it.
    assert_eq!(f.produce_at("design.model", edit("e"), 111.0).unwrap(), Built::New(3));
}

// MARK: Jobs

#[test]
fn jobs_pause_resume_cancel_and_say_so() {
    let mut f = Flow::new();
    let r = f.command(&json!({"op": "job_start", "artifact": "generate.frame", "verb": "Generating", "label": "Frame study", "total": 120, "pausable": true, "now": 0.0}));
    let job = r["job"].as_u64().unwrap();
    f.command(&json!({"op": "job_progress", "job": job, "done": 74}));
    let j = f.state_at(74.0)["jobs"][0].clone();
    assert_eq!(j["caption"], "Generating 74 of 120 · 46 s left");
    assert_eq!(j["determinate"], true);
    f.command(&json!({"op": "job_pause", "job": job, "now": 74.0}));
    let j = f.state_at(300.0)["jobs"][0].clone();
    assert_eq!(j["state"], "paused");
    assert_eq!(j["control"], "pause");
    f.command(&json!({"op": "job_resume", "artifact": "generate.frame", "now": 300.0}));
    assert_eq!(f.state_at(300.0)["jobs"][0]["eta"], 46.0);
    assert_eq!(f.command(&json!({"op": "job_cancel", "job": job}))["ok"], true);
    assert_eq!(f.status("generate.frame"), Status::Empty);
    assert_eq!(f.state()["nodes"][1]["note"], "Frame study cancelled");
    // The worker's late report after a cancel is let go.
    assert_eq!(f.command(&json!({"op": "job_end", "job": job}))["ignored"], true);
    assert_eq!(f.status("generate.frame"), Status::Empty);
}

struct Counter {
    left: u64,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Worker for Counter {
    fn poll(&mut self) -> Poll {
        self.left = self.left.saturating_sub(1);
        Poll {
            done: Some(3 - self.left),
            total: Some(3),
            finished: (self.left == 0).then(|| Ok(Some("policy from the worker".into()))),
            ..Poll::default()
        }
    }
    fn cancel(&mut self) {
        self.cancelled.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

#[test]
fn rust_workers_are_polled_and_cancelled_through_the_registry() {
    let mut f = Flow::new();
    let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let j = f.job_start("train.policy", "Training", "ES", 0.0).unwrap();
    f.attach(j, Box::new(Counter { left: 3, cancelled: cancelled.clone() })).unwrap();
    assert!(f.tick().is_empty());
    assert_eq!(f.job(j).unwrap().done, Some(1));
    f.tick();
    assert_eq!(f.tick(), [j]);
    assert_eq!(f.status("train.policy"), Status::Current);
    assert_eq!(f.state()["nodes"][5]["summary"], "policy from the worker");

    let j = f.job_start("train.policy", "Training", "ES", 0.0).unwrap();
    f.attach(j, Box::new(Counter { left: 3, cancelled: cancelled.clone() })).unwrap();
    f.job_cancel(j).unwrap();
    assert!(cancelled.load(std::sync::atomic::Ordering::SeqCst));
    assert!(f.tick().is_empty());
    assert_eq!(f.revision("train.policy"), 1);
}

// MARK: Tree and selection

#[test]
fn trees_keep_eyes_and_locks_and_selection_links_stages() {
    let mut f = Flow::sample();
    let t = f.tree("design").unwrap();
    let rows = t["rows"].as_array().unwrap();
    assert_eq!(rows[0]["id"], "design.model");
    assert_eq!(rows[0]["detail"], "Model v12");
    assert_eq!(rows[1]["name"], "Frame");
    assert_eq!(rows[1]["depth"], 1);
    assert_eq!(rows[1]["selected"], true);
    // Hiding the artifact hides what is under it without touching the rows' own eyes.
    f.command(&json!({"op": "tree_set", "id": "design.model", "visible": false}));
    f.command(&json!({"op": "tree_set", "id": "body:Pods", "locked": true}));
    let rows = f.tree("design").unwrap()["rows"].as_array().unwrap().clone();
    assert_eq!(rows[1]["visible"], true);
    assert_eq!(rows[1]["shown"], false);
    assert_eq!(rows[2]["locked"], true);
    let linked = f.selection()["linked"].as_array().unwrap().clone();
    assert_eq!(linked.len(), 1, "{linked:?}");
    assert_eq!(linked[0]["stage"], "assemble");
    assert_eq!(linked[0]["names"], json!(["Frame:1"]));
    let r = f.command(&json!({"op": "select", "stage": "electronics", "ids": ["ref:U1"], "anchor": [1, 2, 3]}));
    assert_eq!(r["selection"]["linked"][0]["ids"], json!(["occ:FC"]));
    assert_eq!(r["selection"]["anchor"], json!([1.0, 2.0, 3.0]));
    assert!(f.command(&json!({"op": "select", "stage": "moon", "ids": []}))["error"].is_string());
}

#[test]
fn outputs_give_state_reason_and_action() {
    let f = Flow::sample();
    let out = f.outputs();
    let row = |id: &str| out.as_array().unwrap().iter().find(|o| o["id"] == id).unwrap().clone();
    assert_eq!(row("assemble.assembly")["status"], "stale");
    assert_eq!(row("assemble.assembly")["reason"], "Frame v12 replaced v11");
    assert_eq!(row("assemble.assembly")["action"]["label"], "Re-run on Frame v12");
    assert_eq!(row("generate.frame")["status"], "running");
    assert_eq!(row("make.bundle")["status"], "empty");
    assert_eq!(f.state()["product"], "Racer 3in");
    assert_eq!(f.state()["jobs"][0]["done"], 74);
}

// MARK: Persistence

#[test]
fn the_pipeline_round_trips_through_its_document() {
    let mut f = Flow::sample();
    f.set_flags("body:Pods", Some(false), Some(true));
    let doc = persist::to_doc(&f);
    let back = persist::from_doc(&doc).unwrap();
    assert_eq!(back.revision("generate.frame"), 12);
    assert_eq!(back.revision_name("electronics.board", back.revision("electronics.board")), "Board rev C");
    assert_eq!(back.status("assemble.assembly"), Status::Stale);
    assert_eq!(back.trees.flags("body:Pods"), Flags { visible: false, locked: true });
    assert_eq!(back.selection()["ids"], json!(["body:Frame"]));
    assert_eq!(back.graph().product, "Racer 3in");
    // The running study is not saved; its artifact says it was interrupted.
    assert!(back.state()["jobs"].as_array().unwrap().is_empty());
    assert_eq!(back.state()["nodes"][1]["note"], "Frame study, 120 outcomes was running when the project was saved");
    assert!(persist::from_doc(&json!({"format": "viaform-flow", "version": 99})).unwrap_err().contains("newer"));
    assert!(persist::from_doc(&json!({"format": "other"})).is_err());
}

#[test]
fn a_custom_graph_is_kept_per_project() {
    let mut g = Graph::drone();
    g.product = "Humanoid Hand".into();
    g.artifacts.push(ArtifactDef {
        id: "assemble.motors".into(),
        stage: "assemble".into(),
        name: "Motor per joint".into(),
        label: "Motors".into(),
        scheme: Scheme::Letter,
        inputs: vec!["assemble.assembly".into()],
    });
    let mut f = Flow::new();
    f.produce("design.model", Build::default()).unwrap();
    assert_eq!(f.command(&json!({"op": "set_graph", "graph": g}))["ok"], true);
    assert_eq!(f.revision("design.model"), 1, "revisions survive a graph change");
    let back = persist::from_doc(&persist::to_doc(&f)).unwrap();
    assert_eq!(back.graph().artifacts.len(), 9);
    assert_eq!(back.state()["stages"][2]["artifacts"], json!(["assemble.assembly", "assemble.motors"]));
}

#[test]
fn flow_json_rides_in_the_viaform_file_and_older_files_still_open() {
    let dir = std::env::temp_dir().join(format!("viaform-flow-test-{}-{}", std::process::id(), now()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("racer.viaform");
    let mut ws = crate::Workspace::new(true);
    crate::project::save(&mut ws, &path).unwrap();
    // A project saved before the pipeline existed opens on a fresh one.
    let mut f = Flow::sample();
    let r = f.command(&json!({"op": "open", "path": path}));
    assert_eq!(r["found"], false, "{r}");
    assert_eq!(f.revision("generate.frame"), 0);

    let sample = Flow::sample();
    persist::write_into(&path, &sample).unwrap();
    // Writing it twice keeps one entry, and the project itself still opens.
    persist::write_into(&path, &sample).unwrap();
    let mut again = crate::Workspace::default();
    crate::project::open(&mut again, &path).unwrap();
    let r = f.command(&json!({"op": "open", "path": path}));
    assert_eq!(r["found"], true, "{r}");
    assert_eq!(f.revision("generate.frame"), 12);
    assert_eq!(f.command(&json!({"op": "save", "path": path}))["ok"], true);
    let names: Vec<String> = zip::ZipArchive::new(std::fs::File::open(&path).unwrap()).unwrap().file_names().filter_map(|n| n.ok().map(|n| n.into_owned())).collect();
    assert_eq!(names.iter().filter(|n| *n == persist::ENTRY).count(), 1, "{names:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn search_and_the_catalog_go_through_commands() {
    let mut f = Flow::new();
    let r = f.command(&json!({"op": "search", "query": "use as frame"}));
    assert_eq!(r["results"][0]["command"]["id"], "generate.use_as_frame");
    let all = f.command(&json!({"op": "commands", "stage": "electronics"}));
    assert!(all["commands"].as_array().unwrap().iter().all(|c| c["stage"] == "electronics"));
}

#[test]
fn reasons_name_the_root_cause_only() {
    let mut f = Flow::new();
    for a in ["design.model", "generate.frame", "electronics.board", "assemble.assembly", "simulate.flight"] {
        f.produce(a, Build::default()).unwrap();
    }
    f.produce("design.model", Build::default()).unwrap();
    // Flight is built on Assembly v1, which waits on the model: no "is stale:" chain.
    assert_eq!(f.reason("assemble.assembly"), "Model v2 replaced v1");
    assert_eq!(f.reason("simulate.flight"), "Model v2 replaced v1");
    // Two inputs moved: the reason and the action name the same one.
    f.produce("electronics.board", Build::default()).unwrap();
    let reason = f.reason("assemble.assembly");
    let label = f.action("assemble.assembly")["label"].as_str().unwrap().to_owned();
    assert!(reason.starts_with("Board rev B"), "{reason}");
    assert_eq!(label, "Re-run on Board rev B");
}

#[test]
fn search_keeps_weak_hits_below_label_matches() {
    let hits = super::commands::search("extr", Some("design"), 10);
    let labels: Vec<String> = hits.iter().map(|h| h["command"]["label"].as_str().unwrap().to_lowercase()).collect();
    assert!(!labels.is_empty());
    assert!(labels[0].contains("extr"), "{labels:?}");
    let first_weak = labels.iter().position(|l| !l.contains("extr")).unwrap_or(labels.len());
    assert!(labels[first_weak..].iter().all(|l| !l.contains("extr")), "label matches come first: {labels:?}");
}

#[test]
fn a_stage_without_its_own_artifact_still_lists_what_was_reported() {
    // The hand has no generate.frame: its Generate browser lists the inserted parts from the top.
    let mut f = Flow::with_graph(graph::Graph::hand()).unwrap();
    let items: Vec<tree::TreeItem> = serde_json::from_value(json!([
        {"id": "gen:folder:generated", "name": "Generated parts", "kind": "folder"},
        {"id": "gen:part:palm", "name": "palm", "kind": "body", "parent": "gen:folder:generated"},
        {"id": "gen:part:wrist_cross", "name": "wrist_cross", "kind": "body", "parent": "gen:folder:generated"}
    ]))
    .unwrap();
    f.tree_report("generate", items).unwrap();
    let rows = f.tree("generate").unwrap()["rows"].as_array().unwrap().clone();
    assert_eq!(rows.len(), 3, "{rows:?}");
    assert_eq!(rows[0]["name"], "Generated parts");
    assert_eq!(rows[0]["depth"], 0);
    assert!(rows[0]["parent"].is_null());
    assert_eq!(rows[0]["children"], 2);
    assert_eq!(rows[1]["depth"], 1);
}
