fn main() {
    println!("cargo:rerun-if-env-changed=VICTORY_D3D12_CORE");
    println!("cargo:rerun-if-env-changed=USERPROFILE");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    let explicit = std::env::var_os("VICTORY_D3D12_CORE").map(std::path::PathBuf::from);
    let source = explicit.clone().or_else(find_cached_agility_runtime);
    let Some(source) = source else {
        println!("cargo:warning=Agility SDK runtime not staged: obtain Microsoft.Direct3D.D3D12 1.620.2 and set VICTORY_D3D12_CORE to its build/native/bin/x64/D3D12Core.dll; without it Windows uses the inbox runtime");
        return;
    };

    if !source.is_file() {
        panic!("D3D12Core.dll not found: {}", source.display());
    }
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() != Ok("x86_64") {
        panic!("the configured Agility SDK runtime is x64-only; target architecture must be x86_64");
    }
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("msvc") {
        panic!("Agility SDK data exports currently require the MSVC linker");
    }

    // d3d12.dll reads these two data exports from the host executable. `.`
    // makes it load D3D12Core.dll from the same directory as victory.exe.
    println!("cargo:rustc-link-arg-bin=victory=/EXPORT:D3D12SDKVersion,DATA");
    println!("cargo:rustc-link-arg-bin=victory=/EXPORT:D3D12SDKPath,DATA");
    println!("cargo:rerun-if-changed={}", source.display());

    // Cargo places OUT_DIR at <target>/<profile>/build/<hash>/out (with an
    // extra target-triple directory for cross-compilation). Stage the DLL
    // beside the executable, not under OUT_DIR.
    let out_dir = std::path::PathBuf::from(
        std::env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR for build scripts"),
    );
    let target = std::env::var("TARGET").expect("Cargo sets TARGET");
    let host = std::env::var("HOST").expect("Cargo sets HOST");
    let profile_ancestor = if target == host { 3 } else { 4 };
    let profile_dir = out_dir
        .ancestors()
        .nth(profile_ancestor)
        .expect("Cargo OUT_DIR has a profile directory ancestor");
    let destination = profile_dir.join("D3D12Core.dll");
    std::fs::copy(&source, &destination).unwrap_or_else(|error| {
        panic!(
            "could not stage {} beside victory.exe at {}: {error}",
            source.display(),
            destination.display()
        )
    });
    println!("cargo:warning=staged Agility SDK D3D12Core.dll at {}", destination.display());
}

fn find_cached_agility_runtime() -> Option<std::path::PathBuf> {
    let profile = std::env::var_os("USERPROFILE")?;
    Some(
        std::path::PathBuf::from(profile)
            .join(r".nuget\packages\microsoft.direct3d.d3d12\1.620.2\build\native\bin\x64\D3D12Core.dll"),
    )
    .filter(|path| path.is_file())
}
