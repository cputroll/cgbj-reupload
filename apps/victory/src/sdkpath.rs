/// Data exports read by the D3D12 loader to select the app-local Agility SDK.
///
/// The MSVC linker exports these symbols as data when the build script stages
/// an Agility SDK runtime. Keep the path and runtime DLL beside victory.exe.
#[repr(transparent)]
pub struct SdkPath(*const u8);

// SAFETY: this pointer refers to a static byte string that never changes.
unsafe impl Sync for SdkPath {}

/// The executable's directory; `D3D12Core.dll` must be beside victory.exe.
#[used]
#[unsafe(no_mangle)]
pub static D3D12SDKPath: SdkPath = SdkPath(b".\0".as_ptr());

/// Agility SDK 1.620.2; the loader expects the middle version component.
#[used]
#[unsafe(no_mangle)]
pub static D3D12SDKVersion: u32 = 620;
