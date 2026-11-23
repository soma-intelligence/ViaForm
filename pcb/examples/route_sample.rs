//! Routes the drone flight controller sample and prints the router report and the checks.
use serde_json::json;
fn main() {
    let mut s = viaform_pcb::Session::sample();
    let t = std::time::Instant::now();
    let r = s.call("route.auto", &json!({})).unwrap();
    println!("route: {} in {:?}", r["result"], t.elapsed());
    println!("tracks {} vias {}", s.project.board.tracks.len(), s.project.board.vias.len());
    println!("checks: {}", s.checks());
}
