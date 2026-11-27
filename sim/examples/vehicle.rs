//! Builds the drone from the sourced components and flies it through the obstacle course:
//! `cargo run --release -p viaform-sim --example vehicle -- docs/components/drone.json [assembly.json] [frame.json]`.

use viaform_sim::api;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let read = |i: usize| args.get(i).map(|p| std::fs::read_to_string(p).expect("read"));
    let (c, a, f) = (read(0).expect("components path"), read(1), read(2));
    let req = serde_json::json!({ "components": c, "assembly": a, "frame": f });
    println!("{}", api::vehicle(&req.to_string()));
    let opts = serde_json::json!({ "mission": "course", "brain": "trained", "components": c, "assembly": a, "frame": f });
    println!("{}", api::episode(&opts.to_string()));
}
