fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lib_dir = std::path::Path::new(&manifest_dir)
        .join("../../native/vendor/iroh-c-ffi/target/release")
        .canonicalize()
        .unwrap_or_else(|_| {
            eprintln!("idfond: vendored dylib directory missing; run the native build once (zig build in native/)");
            std::path::PathBuf::from("/nonexistent")
        });
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=iroh_c_ffi");

    // Keep a copy of the dylib next to the built binary so
    // @executable_path/libiroh_c_ffi.dylib resolves when the binary is run
    // directly from target/<profile>/.
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let profile_dir = std::path::Path::new(&out_dir)
        .ancestors()
        .nth(3)
        .expect("OUT_DIR layout");
    let dylib = lib_dir.join("libiroh_c_ffi.dylib");
    if dylib.exists() {
        let _ = std::fs::copy(&dylib, profile_dir.join("libiroh_c_ffi.dylib"));
        println!("cargo:rerun-if-changed={}", dylib.display());
    }
}
