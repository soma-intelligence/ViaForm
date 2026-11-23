//! With the `mujoco` feature: finds the pinned MuJoCo release (MUJOCO_DIR, or the cache that
//! `scripts/fetch-mujoco.sh` fills), compiles the small C shim against its headers, and links
//! the library. Without the feature it does nothing (the crate is the exporter plus a stub).
//!
//! The library is copied into OUT_DIR (inside the target directory) so test binaries of this
//! crate and of its dependents find it at run time: on macOS the copy gets an absolute install
//! name (and an ad hoc signature, since the id change invalidates the original one); on Linux
//! Cargo adds OUT_DIR to the loader path for `cargo test` and `cargo run`.

/// The pinned release (keep in step with `scripts/fetch-mujoco.sh` and `src/lib.rs`).
#[cfg_attr(not(feature = "mujoco"), allow(dead_code))]
const VERSION: &str = "3.17.0";

fn main() {
    println!("cargo:rerun-if-env-changed=MUJOCO_DIR");
    println!("cargo:rerun-if-changed=csrc/shim.c");
    println!("cargo:rerun-if-changed=build.rs");
    #[cfg(feature = "mujoco")]
    real::build();
}

#[cfg(feature = "mujoco")]
mod real {
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use super::VERSION;

    fn default_dir(os: &str) -> Option<PathBuf> {
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        match os {
            "macos" => Some(home.join("Library/Caches/viaform-mujoco").join(VERSION)),
            "linux" => Some(std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".cache")).join("viaform-mujoco").join(VERSION)),
            _ => None,
        }
    }

    fn fail(msg: &str) -> ! {
        panic!("\n\nviaform-mujoco: {msg}\nRun mujoco/scripts/fetch-mujoco.sh (MuJoCo {VERSION} from github.com/google-deepmind), or set MUJOCO_DIR, or build without --features mujoco.\n\n");
    }

    fn run(cmd: &mut Command) {
        let st = cmd.status().unwrap_or_else(|e| fail(&format!("cannot run {cmd:?}: {e}")));
        if !st.success() {
            fail(&format!("{cmd:?} failed"));
        }
    }

    pub fn build() {
        let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        if os == "ios" || os == "tvos" || os == "visionos" || os == "watchos" {
            fail("MuJoCo ships no prebuilt library for iOS or iPadOS; the mujoco feature is macOS and Linux only");
        }
        let dir = std::env::var_os("MUJOCO_DIR").map(PathBuf::from).or_else(|| default_dir(&os)).unwrap_or_else(|| fail(&format!("no default MuJoCo location for target OS {os}")));
        let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
        let lib_out = out.join("lib");
        std::fs::create_dir_all(&lib_out).unwrap();
        let mut cc = cc::Build::new();
        cc.file("csrc/shim.c").warnings(false).opt_level(2);
        match os.as_str() {
            "macos" => {
                let fw = dir.join("mujoco.framework");
                let dylib = fw.join(format!("Versions/A/libmujoco.{VERSION}.dylib"));
                if !dylib.exists() {
                    fail(&format!("{} not found", dylib.display()));
                }
                cc.flag(format!("-F{}", dir.display()));
                let copy = lib_out.join(format!("libmujoco.{VERSION}.dylib"));
                if !copy.exists() {
                    std::fs::copy(&dylib, &copy).unwrap();
                    run(Command::new("install_name_tool").arg("-id").arg(&copy).arg(&copy));
                    run(Command::new("codesign").args(["--force", "--sign", "-"]).arg(&copy));
                }
                let link = lib_out.join("libmujoco.dylib");
                let _ = std::fs::remove_file(&link);
                std::os::unix::fs::symlink(&copy, &link).unwrap();
            }
            "linux" => {
                let inc = dir.join("include");
                let lib = dir.join("lib");
                if !inc.join("mujoco/mujoco.h").exists() {
                    fail(&format!("{} has no include/mujoco/mujoco.h", dir.display()));
                }
                cc.include(&inc);
                for e in std::fs::read_dir(&lib).unwrap_or_else(|_| fail(&format!("{} not found", lib.display()))).flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if name.starts_with("libmujoco.so") {
                        copy_link(&e.path(), &lib_out.join(&name));
                    }
                }
                println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_out.display());
            }
            other => fail(&format!("target OS {other} is not supported (macOS and Linux only)")),
        }
        cc.compile("viaform_mujoco_shim");
        println!("cargo:rustc-link-search=native={}", lib_out.display());
        println!("cargo:rustc-link-lib=dylib=mujoco");
        println!("cargo:root={}", dir.display());
        println!("cargo:libdir={}", lib_out.display());
    }

    fn copy_link(src: &Path, dst: &Path) {
        let _ = std::fs::remove_file(dst);
        std::fs::copy(src, dst).unwrap();
    }
}
