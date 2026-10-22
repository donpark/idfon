fn main() {
    // Always link the release dylib, even for debug builds: the release dylib
    // is rebuilt unconditionally by native/build.sh and scripts/test-*.sh, so
    // this keeps debug idfond on the freshest code with no profile-matching
    // ceremony. Debug daemon debugging would need a profile-matched debug
    // dylib (plus a Swift-stdlib rpath; the debug dylib links @rpath/
    // libswift_Concurrency.dylib, release does not) — only do that if you
    // start debugging daemon code under lldb regularly.
    //
    // The dylib is the `iroh-c-ffi` workspace member's cdylib output, built
    // by `cargo build --release -p iroh-c-ffi` (every consumer script does
    // this first).
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let workspace_target = std::path::Path::new(&manifest_dir).join("../../target");
    // Cross builds (--target <triple>) place the dylib under
    // target/<triple>/release; host builds (native/build.zig,
    // scripts/test-*.sh, host build-cli.sh) use target/release.
    let target = std::env::var("TARGET").unwrap();
    let host = std::env::var("HOST").unwrap();
    let lib_dir = if target == host {
        workspace_target.join("release")
    } else {
        workspace_target.join(&target).join("release")
    }
    .canonicalize()
    .unwrap_or_else(|_| {
        eprintln!(
            "idfond: iroh-c-ffi dylib for {target} missing; build it first (scripts/build-cli.sh {target} or zig build in native/)"
        );
        std::path::PathBuf::from("/nonexistent")
    });
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=iroh_c_ffi");

    // Keep a copy of the dylib next to the built binary so
    // @executable_path/libiroh_c_ffi.dylib (macOS) / $ORIGIN (Linux) resolves
    // when the binary is run directly from target/<profile>/. Host release
    // builds already have it there (same dir), so only debug/cross builds
    // copy.
    let dylib_name = if target.contains("apple") {
        "libiroh_c_ffi.dylib"
    } else {
        "libiroh_c_ffi.so"
    };
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let profile_dir = std::path::Path::new(&out_dir)
        .ancestors()
        .nth(3)
        .expect("OUT_DIR layout");
    let dylib = lib_dir.join(dylib_name);
    let profile_canon = std::fs::canonicalize(profile_dir).unwrap_or_else(|_| profile_dir.to_path_buf());
    // fs::copy onto itself would truncate the dylib — compare canonical paths.
    if dylib.exists() && lib_dir != profile_canon {
        let _ = std::fs::copy(&dylib, profile_dir.join(dylib_name));
    }
    println!("cargo:rerun-if-changed={}", dylib.display());

    // $ORIGIN rpath: the daemon finds the dylib shipped next to it in bin/.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
    }
}
