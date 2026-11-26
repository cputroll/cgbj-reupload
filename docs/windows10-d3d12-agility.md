# Windows 10 and the Direct3D 12 Agility SDK

On Windows, `victory` uses the normal `D3D12CreateDevice` API through
`d3d12.dll`; applications do not load `D3D12Core.dll` themselves. The system
loader selects an app-local Agility SDK runtime only when the executable
exports the data symbols `D3D12SDKVersion` and `D3D12SDKPath`. This change
exports SDK version `620` and path `.` when it can stage the corresponding
runtime. `.` means the DLL must be beside `victory.exe`.

## Build

Use the x64 `D3D12Core.dll` from the official `Microsoft.Direct3D.D3D12`
NuGet package version `1.620.2` (`build/native/bin/x64/D3D12Core.dll`). If the
package is already in the standard NuGet cache, the build script discovers it
automatically. Otherwise set `VICTORY_D3D12_CORE` to the DLL's full path before
building:

```powershell
$env:VICTORY_D3D12_CORE = 'C:\path\to\Microsoft.Direct3D.D3D12\build\native\bin\x64\D3D12Core.dll'
cargo build --locked --profile diag -p victory --features diagnostics
```

When the runtime is found, the build script adds the two PE data exports to
`victory.exe` and stages `D3D12Core.dll` in the matching target profile folder
(for example, `target\diag`). Keep the DLL beside `victory.exe` when moving or
packaging the executable. The integration currently targets x64 MSVC builds.

Without the Agility SDK package, a build still succeeds, warns, and does not
add the exports, so Windows falls back to its inbox D3D12 runtime. That is
useful on systems where the inbox runtime works; on Windows 10 setups that
reject root-signature flags `0xc01`, build with the Agility SDK runtime.

## Report that prompted the workaround

The supplied report associates a Windows 10 22H2 / RX 6800 XT failure with
inbox-runtime rejection of those descriptor-heap indexing flags, which caused
several pipeline creations to fail and was followed by an access violation.
It reports that the Agility SDK runtime accepted the flags and that the
reported run remained stable for over an hour. These are observations from
that machine, not a guarantee for every Windows 10 or GPU configuration.
