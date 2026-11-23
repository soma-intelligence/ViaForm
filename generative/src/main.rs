//! `viaform-gen [spec.json] [--commands]`: runs a study and prints the outcome as JSON (the spec
//! comes from the file or standard input). `--commands` prints the best candidate's SolidCraft
//! commands instead.

use std::io::Read;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let commands = args.iter().any(|a| a == "--commands");
    let mut text = String::new();
    let read = match args.iter().find(|a| !a.starts_with("--")) {
        Some(path) => std::fs::read_to_string(path).map(|t| text = t),
        None => std::io::stdin().read_to_string(&mut text).map(drop),
    };
    if let Err(e) = read {
        eprintln!("viaform-gen: {e}");
        std::process::exit(2);
    }
    let run = || -> Result<serde_json::Value, String> {
        let spec: viaform_generative::Spec = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let outcome = viaform_generative::generate(&spec)?;
        if commands {
            let best = &outcome.candidates[outcome.best];
            let list = viaform_generative::emit::commands(&spec, best);
            return Ok(serde_json::json!(list.into_iter().map(|(id, p)| serde_json::json!({"id": id, "params": p})).collect::<Vec<_>>()));
        }
        serde_json::to_value(outcome).map_err(|e| e.to_string())
    };
    match run() {
        Ok(v) => println!("{v}"),
        Err(e) => {
            eprintln!("viaform-gen: {e}");
            std::process::exit(1);
        }
    }
}
