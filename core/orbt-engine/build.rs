//! Compiles both Stockfish flavours: `light` with its small net built in, and `full`, which
//! loads the big net from the file the app downloads (`EvalFile`). Each is in its own C++
//! namespace, so they link into one binary.

use std::path::{Path, PathBuf};

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .expect("vendored sources")
        .map(|e| e.expect("directory entry").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "cpp") {
            out.push(path);
        }
    }
}

fn flavour(name: &str, dir: &str, function: &str, embedded_net: bool) {
    let root = Path::new("vendor").join(dir);
    let mut files = Vec::new();
    sources(&root.join("src"), &mut files);

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++17")
        .warnings(false)
        .files(&files)
        .file("vendor/sfio/sfio.cpp")
        .file("bridge/bridge.cpp")
        .include(&root)
        .include(root.join("src"))
        .include("vendor/sfio")
        .define("ORBT_SF_MAIN", function)
        .define("NDEBUG", None)
        .define("USE_PTHREADS", None)
        .define("IS_64BIT", None)
        .define("USE_POPCNT", None)
        .flag("-fno-exceptions")
        .flag("-funroll-loops")
        // Speed matters even in debug builds of the app; never LTO (`.incbin`, see UPDATING-light.md).
        .opt_level(3);
    if embedded_net {
        // `.incbin` finds the net through the include path.
        build.include("vendor/nnue");
    } else {
        build.define("NNUE_EMBEDDING_OFF", None);
    }
    let apple = std::env::var("CARGO_CFG_TARGET_VENDOR").is_ok_and(|v| v == "apple");
    match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        // Every device iOS 26 and macOS 26 run on (A13, M1 and later) has the dot product.
        Ok("aarch64") if apple => {
            build
                .define("USE_NEON", "8")
                .define("USE_NEON_DOTPROD", None)
                .flag("-march=armv8.2-a+dotprod");
        }
        // Android phones before ARMv8.2 lack it: Stockfish's armv8.
        Ok("aarch64") => {
            build.define("USE_NEON", "8").flag("-march=armv8-a");
        }
        // The Intel Macs macOS 26 supports all have AVX2 (Stockfish's x86-64-avx2).
        Ok("x86_64") if apple => {
            build
                .define("USE_AVX2", None)
                .define("USE_SSE41", None)
                .define("USE_SSSE3", None)
                .define("USE_SSE2", None)
                .flag("-mavx2")
                .flag("-mbmi")
                .flag("-msse4.1")
                .flag("-mssse3")
                .flag("-msse2")
                .flag("-mpopcnt");
        }
        // Android's x86_64 ABI guarantees SSE4.2 and POPCNT, and every PC since 2008 has them:
        // Stockfish's x86-64-sse41-popcnt.
        Ok("x86_64") => {
            build
                .define("USE_SSE41", None)
                .define("USE_SSSE3", None)
                .define("USE_SSE2", None)
                .flag("-msse4.1")
                .flag("-mssse3")
                .flag("-msse2")
                .flag("-mpopcnt");
        }
        _ => {}
    }
    build.compile(name);
}

fn main() {
    println!("cargo:rerun-if-changed=vendor");
    println!("cargo:rerun-if-changed=bridge");
    flavour(
        "orbt_stockfish_light",
        "stockfish-light",
        "orbt_sf_light_main",
        true,
    );
    flavour(
        "orbt_stockfish_full",
        "stockfish",
        "orbt_sf_full_main",
        false,
    );
}
