use std::process::Command;

/// Records each engine's version (its submodule's tag or commit) for the About box and the
/// update check.
fn main() {
    napi_build::setup();
    for (key, dir) in [("VIAFORM_SOLIDCRAFT", "../engines/solidcraft"), ("VIAFORM_PCBCRAFT", "../engines/pcbcraft")] {
        let v = Command::new("git")
            .args(["-C", dir, "describe", "--tags", "--always", "--dirty"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|| "unknown".into());
        println!("cargo:rustc-env={key}={v}");
    }
    println!("cargo:rerun-if-changed=../engines/solidcraft/.git");
    println!("cargo:rerun-if-changed=../engines/pcbcraft/.git");
    println!("cargo:rerun-if-changed=../.git/modules");
}
