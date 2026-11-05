//! Compiles both Stockfish flavours: `light` with its small net built in, and `full`, which
//! loads the big net from the file the app downloads (`EvalFile`). Each is in its own C++
//! namespace, so they link into one binary.
//!
//! On Android's arm64 each flavour is compiled twice, Stockfish's `armv8` and `armv8-dotprod`,
//! and `src/lib.rs` picks one when the engine starts (`getauxval(AT_HWCAP)`), as upstream's
//! `arm64-universal` build does (see `vendor/PATCHES.md`). Apple and x86_64 get one copy.
//!
//! Compiled copies are kept in a cache shared by every checkout of the repository (worktrees,
//! clones), keyed by the contents of `vendor/`, `bridge/` and this file, the compiler, its
//! version and its every argument: a new worktree links them in a second instead of compiling
//! Stockfish again (about 40 s a copy). Nothing in them depends on the checkout's path but debug
//! info. `ORBT_STOCKFISH_CACHE` sets another folder, or `off`.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;

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

/// The instruction set one copy of Stockfish is compiled for (Stockfish's `ARCH`).
#[derive(Clone, Copy, PartialEq)]
enum Isa {
    /// Stockfish's `armv8`: every arm64 CPU.
    Armv8,
    /// Stockfish's `armv8-dotprod`: ARMv8.2 with the dot product.
    Armv8Dotprod,
    /// Stockfish's `x86-64-avx2`.
    X86Avx2,
    /// Stockfish's `x86-64-sse41-popcnt`.
    X86Sse41,
    /// Whatever the compiler targets by default.
    Generic,
}

fn configure(dir: &str, function: &str, embedded_net: bool, isa: Isa) -> cc::Build {
    let root = Path::new("vendor").join(dir);
    let mut files = Vec::new();
    sources(&root.join("src"), &mut files);

    let mut build = cc::Build::new();
    if windows_gnu() {
        // Linked statically in main(): cc's own directive would link it as a DLL.
        build.cpp_link_stdlib(None);
    }
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
    match isa {
        Isa::Armv8 => {
            build.define("USE_NEON", "8").flag("-march=armv8-a");
        }
        Isa::Armv8Dotprod => {
            build
                .define("USE_NEON", "8")
                .define("USE_NEON_DOTPROD", None)
                .flag("-march=armv8.2-a+dotprod");
        }
        Isa::X86Avx2 => {
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
        Isa::X86Sse41 => {
            build
                .define("USE_SSE41", None)
                .define("USE_SSSE3", None)
                .define("USE_SSE2", None)
                .flag("-msse4.1")
                .flag("-mssse3")
                .flag("-msse2")
                .flag("-mpopcnt");
        }
        Isa::Generic => {}
    }
    build
}

/// The one copy of Stockfish this target gets, or Android arm64's baseline.
fn isa() -> Isa {
    let apple = std::env::var("CARGO_CFG_TARGET_VENDOR").is_ok_and(|v| v == "apple");
    match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        // Every device iOS 26 and macOS 26 run on (A13, M1 and later) has the dot product.
        Ok("aarch64") if apple => Isa::Armv8Dotprod,
        // Android phones before ARMv8.2 lack it: Stockfish's armv8 (the dot product copy is
        // added by `dotprod_copy`).
        Ok("aarch64") => Isa::Armv8,
        // The Intel Macs macOS 26 supports all have AVX2 (Stockfish's x86-64-avx2).
        Ok("x86_64") if apple => Isa::X86Avx2,
        // Android's x86_64 ABI guarantees SSE4.2 and POPCNT, and every PC since 2008 has them:
        // Stockfish's x86-64-sse41-popcnt.
        Ok("x86_64") => Isa::X86Sse41,
        _ => Isa::Generic,
    }
}

/// Windows with MinGW (`x86_64-pc-windows-gnu`).
fn windows_gnu() -> bool {
    std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").is_ok_and(|env| env == "gnu")
}

/// Android's arm64: both copies in one library, chosen at run time.
fn runtime_dispatch() -> bool {
    std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "android")
        && std::env::var("CARGO_CFG_TARGET_ARCH").is_ok_and(|arch| arch == "aarch64")
}

/// A tool of the NDK's LLVM next to the compiler cc found (`aarch64-linux-android29-clang++`).
fn llvm_tool(build: &cc::Build, name: &str) -> PathBuf {
    let compiler = build.get_compiler();
    let tool = compiler
        .path()
        .parent()
        .map(|dir| dir.join(name))
        .filter(|tool| tool.exists());
    tool.unwrap_or_else(|| PathBuf::from(name))
}

fn run(command: &mut Command) {
    let status = command
        .status()
        .unwrap_or_else(|e| panic!("cannot run {command:?}: {e}"));
    assert!(status.success(), "{command:?} failed: {status}");
}

/// The `armv8-dotprod` copy of a flavour, the way upstream's universal build makes one
/// (Makefile, section 6): its own namespace and entry point, linked into one relocatable
/// object whose symbols are all local but the entry point, with its static initializers
/// moved out of `.init_array` so they run only when that copy is chosen (bridge.cpp).
///
/// - The namespace keeps its symbols apart from the baseline's in a debugger or a crash log.
/// - Local symbols and no COMDAT groups: inline functions both copies instantiate (the C++
///   library's templates) must not be shared, or the baseline could call one compiled for
///   ARMv8.2 (upstream: `objcopy -R .group`; LTO makes its symbols local).
/// - Deferred initializers: the library is loaded on every phone, and they are ARMv8.2 code.
/// - The light copy reads the net the baseline embeds (`UNIVERSAL_BINARY` in network.cpp).
fn dotprod_copy(name: &str, dir: &str, function: &str, embedded_net: bool) {
    let init_section = format!("{}_init", function.trim_end_matches("_main"));
    let mut build = configure(dir, function, embedded_net, Isa::Armv8Dotprod);
    build
        .define("Stockfish", "StockfishDotprod")
        .define("StockfishLight", "StockfishLightDotprod")
        .define("ORBT_SF_INIT", init_section.as_str());
    if embedded_net {
        // network.cpp declares the baseline's gEmbeddedNNUEData instead of embedding it again.
        build.define("UNIVERSAL_BINARY", None);
    }
    let objects = cached_objects(&build, name, || {
        vec![dotprod_object(&build, name, &init_section, function)]
    });
    archive(name, &objects);
}

/// Compiles the copy and makes it the one relocatable object `dotprod_copy` describes.
fn dotprod_object(build: &cc::Build, name: &str, init_section: &str, function: &str) -> PathBuf {
    let objects = build.compile_intermediates();

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let object = out_dir.join(format!("{name}.o"));
    run(Command::new(llvm_tool(build, "ld.lld"))
        .arg("-r")
        .arg("-o")
        .arg(&object)
        .args(&objects));
    // The section keeps its type (SHT_INIT_ARRAY), so the linker never drops it, but only
    // `.init_array` itself is run when the library loads.
    run(Command::new(llvm_tool(build, "llvm-objcopy"))
        .arg("--remove-section=.group")
        .arg(format!("--rename-section=.init_array={init_section}"))
        .arg(format!("--keep-global-symbol={function}"))
        .arg(&object));
    // Nothing else of this copy may run at load (prioritized initializers would be in
    // `.init_array.<n>`: rename them too if a Stockfish update brings some).
    let sections = Command::new(llvm_tool(build, "llvm-readelf"))
        .args(["-S", "-W"])
        .arg(&object)
        .output()
        .expect("llvm-readelf");
    assert!(sections.status.success(), "llvm-readelf failed");
    let sections = String::from_utf8_lossy(&sections.stdout);
    for loaded in [".init_array", ".preinit_array", ".ctors"] {
        assert!(
            !sections.contains(loaded),
            "{name} still has {loaded}:\n{sections}"
        );
    }
    object
}

/// Where compiled copies are kept, unless `ORBT_STOCKFISH_CACHE` is `off`. A folder of the
/// build machine, apart from the app's own data.
fn cache_root() -> Option<PathBuf> {
    println!("cargo:rerun-if-env-changed=ORBT_STOCKFISH_CACHE");
    match std::env::var("ORBT_STOCKFISH_CACHE") {
        Ok(dir) if dir == "off" => return None,
        Ok(dir) if !dir.is_empty() => return Some(PathBuf::from(dir)),
        _ => {}
    }
    let env = |name| std::env::var_os(name).map(PathBuf::from);
    let base = if cfg!(target_os = "macos") {
        env("HOME")?.join("Library/Caches")
    } else if cfg!(windows) {
        env("LOCALAPPDATA")?
    } else {
        env("XDG_CACHE_HOME").or_else(|| env("HOME").map(|home| home.join(".cache")))?
    };
    Some(base.join("orbt-chess-build/stockfish"))
}

/// Every file under `dir`, by path and contents.
fn hash_tree(dir: &Path, hasher: &mut DefaultHasher) {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .expect("vendored sources")
        .map(|e| e.expect("directory entry").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            hash_tree(&path, hasher);
        } else {
            path.hash(hasher);
            std::fs::read(&path).expect("source file").hash(hasher);
        }
    }
}

/// What a compiled copy depends on: the sources, how this script treats them, and the exact
/// compiler command. Two differently seeded hashes, so a collision is out of the question.
fn cache_key(build: &cc::Build, name: &str) -> String {
    let compiler = build.get_compiler();
    let version = Command::new(compiler.path())
        .arg("--version")
        .output()
        .map(|output| output.stdout)
        .unwrap_or_default();
    let mut key = String::new();
    for seed in [0u8, 1] {
        let mut hasher = DefaultHasher::new();
        seed.hash(&mut hasher);
        for dir in ["vendor", "bridge"] {
            hash_tree(Path::new(dir), &mut hasher);
        }
        std::fs::read("build.rs")
            .expect("build.rs")
            .hash(&mut hasher);
        name.hash(&mut hasher);
        std::env::var("TARGET")
            .unwrap_or_default()
            .hash(&mut hasher);
        compiler.path().hash(&mut hasher);
        compiler.args().hash(&mut hasher);
        version.hash(&mut hasher);
        key.push_str(&format!("{:016x}", hasher.finish()));
    }
    key
}

/// The objects of one copy: from the cache when it has them, else made by `make` and stored.
fn cached_objects(
    build: &cc::Build,
    name: &str,
    make: impl FnOnce() -> Vec<PathBuf>,
) -> Vec<PathBuf> {
    let Some(root) = cache_root() else {
        return make();
    };
    let entry = root.join(cache_key(build, name));
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let local = out_dir.join("stockfish-cache").join(name);
    if let Ok(files) = std::fs::read_dir(&entry) {
        let _ = std::fs::remove_dir_all(&local);
        std::fs::create_dir_all(&local).expect("OUT_DIR");
        let objects: Option<Vec<PathBuf>> = files
            .map(|file| {
                let file = file.ok()?.path();
                let copy = local.join(file.file_name()?);
                std::fs::copy(&file, &copy).ok()?;
                Some(copy)
            })
            .collect();
        if let Some(objects) = objects.filter(|objects| !objects.is_empty()) {
            return objects;
        }
    }
    let objects = make();
    // Written under a temporary name and renamed: another build reading or writing the same
    // entry never sees half of it.
    let temporary = root.join(format!("{}.tmp-{}", entry.display(), std::process::id()));
    let stored = std::fs::create_dir_all(&temporary).is_ok()
        && objects.iter().all(|object| {
            object
                .file_name()
                .is_some_and(|file| std::fs::copy(object, temporary.join(file)).is_ok())
        })
        && std::fs::rename(&temporary, &entry).is_ok();
    if !stored {
        let _ = std::fs::remove_dir_all(&temporary);
    }
    objects
}

/// One static library from compiled objects, linked like `cc::Build::compile` links it.
fn archive(name: &str, objects: &[PathBuf]) {
    let mut build = cc::Build::new();
    build.cpp(true).objects(objects);
    if windows_gnu() {
        build.cpp_link_stdlib(None);
    }
    build.compile(name);
}

fn flavour(name: &str, dir: &str, function: &str, embedded_net: bool) {
    let build = configure(dir, function, embedded_net, isa());
    let objects = cached_objects(&build, name, || build.compile_intermediates());
    archive(name, &objects);
    if runtime_dispatch() {
        dotprod_copy(
            &format!("{name}_dotprod"),
            dir,
            &function.replace("_main", "_dotprod_main"),
            embedded_net,
        );
    }
}

fn main() {
    println!("cargo:rerun-if-changed=vendor");
    println!("cargo:rerun-if-changed=bridge");
    // Stockfish on Windows (misc.cpp): large pages adjust the process token's privileges, and
    // the command line is split with CommandLineToArgvW.
    if std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "windows") {
        println!("cargo:rustc-link-lib=advapi32");
        println!("cargo:rustc-link-lib=shell32");
    }
    // MinGW's C++ runtime goes into the core's DLL: Windows PCs have no libstdc++-6.dll.
    if windows_gnu() {
        println!("cargo:rustc-link-lib=static:-bundle=stdc++");
    }
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
