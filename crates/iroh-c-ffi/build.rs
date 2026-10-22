fn main() {
    // The cdylib's link args live here, not in RUSTFLAGS: RUSTFLAGS is
    // fingerprinted for every crate in the graph, so per-script link flags
    // used to force a full recompile whenever two scripts were alternated.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // @executable_path install name: the app/CLI load the dylib sitting
        // next to the binary (absolute build-path install names break that).
        println!(
            "cargo:rustc-cdylib-link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib"
        );
        // x86_64 capture-stack deps autolink @rpath/libswift*; dyld resolves
        // them from the shared cache. Harmless on arm64.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libiroh_c_ffi.so");
    }
}
