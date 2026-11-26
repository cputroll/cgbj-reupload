# Read-only preflight for this fork: machine, toolchain and the paths it needs.
# It never builds, launches the title or changes settings.
#   scripts\doctor.ps1
#   scripts\doctor.ps1 -Exe D:\Games\MyDump\game_scarlett_master.exe
# Exit code 1 when a check fails, 0 otherwise. WARN lines are advisory: shader
# model 6.6 and mesh shaders, for example, are only confirmed at run time.
param(
    [string]$Exe,
    [string]$Config
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$counts = @{ OK = 0; WARN = 0; FAIL = 0 }

function Report {
    param([ValidateSet('OK', 'WARN', 'FAIL')]$Level, [string]$Text)
    $counts[$Level]++
    Write-Host ('[{0,-4}] {1}' -f $Level, $Text)
}

function GiB {
    param([double]$Bytes)
    '{0:N1} GiB' -f ($Bytes / 1GB)
}

# A path is usable for cache/data only if no ancestor carries .victory-root.
function Test-OutsideRepo {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $dir = $full
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $dir '.victory-root')) { return $false }
        $parent = Split-Path -Path $dir -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { return $true }
        $dir = $parent
    }
}

function From-Env-OrFile {
    param([string]$Name, [hashtable]$File)
    $value = Get-Item "Env:$Name" -ErrorAction SilentlyContinue
    if ($value -and $value.Value) { return $value.Value }
    return $File[$Name]
}

Write-Host 'VIctory preflight'
Write-Host '================'

# Windows 10/11 x64 is the documented minimum.
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$osText = '{0} (build {1}), {2}' -f $os.Caption.Trim(), $build,
    $(if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })
if ([Environment]::Is64BitOperatingSystem -and $build -ge 17763) {
    Report OK "OS: $osText"
} else {
    Report FAIL "OS: $osText; Windows 10/11 x64 is required"
}

$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
Report OK ('CPU: {0}' -f $(if ($cpu) { $cpu.Trim() } else { 'unknown' }))

# PF_AVX2_INSTRUCTIONS_AVAILABLE = 40 in winnt.h. This is the same feature the
# binary checks before `run --execute` (VICTORY_SKIP_CPU_CHECK=1 bypasses it).
try {
    if (-not ('VictoryCpuFeature' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class VictoryCpuFeature
{
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsProcessorFeaturePresent(uint feature);
}
'@
    }
    if ([VictoryCpuFeature]::IsProcessorFeaturePresent(40)) {
        Report OK 'CPU feature: AVX2 available'
    } else {
        Report FAIL 'CPU feature: no AVX2; the title cannot start'
    }
} catch {
    Report WARN ('CPU feature: AVX2 could not be checked ({0})' -f $_.Exception.Message)
}

$ram = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$commit = [double]$os.TotalVirtualMemorySize * 1KB
$memory = '{0} RAM, {1} commit limit' -f (GiB $ram), (GiB $commit)
if ($ram -lt 24GB) {
    Report FAIL "Memory: $memory; this fork needs at least 24 GiB"
} elseif ($ram -lt 64GB) {
    Report WARN "Memory: $memory; 64 GiB is recommended (32 GiB works with reduced budgets)"
} else {
    Report OK "Memory: $memory"
}

$gpus = @(Get-CimInstance Win32_VideoController)
if ($gpus.Count -eq 0) {
    Report WARN 'GPU: none reported by WMI'
} else {
    foreach ($gpu in ($gpus | Select-Object -First 4)) {
        Report OK ('GPU: {0}, driver {1}' -f $gpu.Name.Trim(), $gpu.DriverVersion)
    }
    Report WARN 'GPU features: SM6.6 and mesh shaders are confirmed only at run time (log: "host mesh shader support")'
}

$pin = ''
$toolchain = Join-Path $repo 'rust-toolchain.toml'
if (Test-Path -LiteralPath $toolchain) {
    $match = Select-String -LiteralPath $toolchain -Pattern '^\s*channel\s*=\s*"([^"]+)"'
    if ($match) { $pin = $match.Matches[0].Groups[1].Value }
}
if (Get-Command rustc -ErrorAction SilentlyContinue) {
    try {
        $version = (& rustc --version 2>&1 | Out-String).Trim()
        if ($pin -and $version -notmatch [regex]::Escape($pin)) {
            Report WARN "Rust: $version (this checkout pins $pin)"
        } else {
            Report OK "Rust: $version"
        }
    } catch {
        Report WARN ('Rust: version could not be read ({0})' -f $_.Exception.Message)
    }
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if ($rustup) {
        $targets = (& rustup target list --installed 2>&1 | Out-String)
        if ($targets -match 'x86_64-pc-windows-msvc') {
            Report OK 'Rust target: x86_64-pc-windows-msvc installed'
        } else {
            Report WARN 'Rust target: x86_64-pc-windows-msvc not installed'
        }
    }
} else {
    Report WARN 'Rust: rustc is not on PATH (only needed to build from source)'
}
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    Report WARN 'MSVC: cl.exe is not on PATH (only needed to build from source)'
}

# Config resolution mirrors crates/victory-core/src/config.rs: env, then file,
# then the LOCALAPPDATA default. Only the small [paths] table is read here.
$cfgPath = if ($Config) { $Config } elseif ($env:VICTORY_CONFIG) { $env:VICTORY_CONFIG } else { 'victory.toml' }
$file = @{}
Push-Location $repo
try {
    $cfgFull = [IO.Path]::GetFullPath($cfgPath)
    if (Test-Path -LiteralPath $cfgFull -PathType Leaf) {
        $section = ''
        foreach ($line in Get-Content -LiteralPath $cfgFull) {
            if ($line -match '^\s*\[([^\]]+)\]\s*$') { $section = $Matches[1]; continue }
            if ($section -eq 'paths' -and
                $line -match '^\s*(game_dir|cache_dir|data_dir)\s*=\s*"([^"]*)"\s*$') {
                $file[$Matches[1]] = $Matches[2]
            }
        }
        Report OK "Config: $cfgFull"
    } else {
        Report WARN "Config: $cfgFull not found (copy victory.example.toml, or set VICTORY_CONFIG)"
    }

    $gameDir = From-Env-OrFile 'VICTORY_GAME_DIR' $file
    if (-not $gameDir) {
        Report FAIL 'Game dir: set VICTORY_GAME_DIR or [paths].game_dir in victory.toml'
    } else {
        $gameFull = [IO.Path]::GetFullPath($gameDir)
        if (Test-Path -LiteralPath $gameFull -PathType Container) {
            Report OK "Game dir: $gameFull"
        } else {
            Report FAIL "Game dir: $gameFull does not exist"
        }
    }

    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE '.cache' }
    foreach ($spec in @(
            @{ Env = 'VICTORY_CACHE_DIR'; Key = 'cache_dir'; Name = 'cache'; Default = Join-Path (Join-Path $base 'victory') 'cache' },
            @{ Env = 'VICTORY_DATA_DIR'; Key = 'data_dir'; Name = 'data'; Default = Join-Path (Join-Path $base 'victory') 'data' })) {
        $raw = From-Env-OrFile $spec.Env $file
        if (-not $raw) { $raw = $spec.Default }
        $full = [IO.Path]::GetFullPath($raw)
        if (-not (Test-OutsideRepo $full)) {
            Report FAIL ("{0} dir: {1} is inside the repository (asset policy)" -f $spec.Name, $full)
        } else {
            Report OK ("{0} dir: {1}" -f $spec.Name, $full)
        }
    }

    if ($Exe) {
        $exeFull = [IO.Path]::GetFullPath($Exe)
        if (Test-Path -LiteralPath $exeFull -PathType Leaf) {
            Report OK "Title exe: $exeFull"
        } else {
            Report FAIL "Title exe: $exeFull does not exist"
        }
    } elseif ($gameDir) {
        $candidate = Join-Path ([IO.Path]::GetFullPath($gameDir)) 'game_scarlett_master.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Report OK "Title exe: $candidate (use -Exe for another executable)"
        } else {
            Report WARN "Title exe: not found at $candidate; pass -Exe for another executable"
        }
    }
} finally {
    Pop-Location
}

$cache = From-Env-OrFile 'VICTORY_CACHE_DIR' $file
if (-not $cache) { $cache = Join-Path (Join-Path $base 'victory') 'cache' }
try {
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($cache)))
    if ($drive.AvailableFreeSpace -lt 60GB) {
        Report WARN ('Disk: {0} free on {1}; the shader cache can be large' -f (GiB $drive.AvailableFreeSpace), $drive.Name)
    } else {
        Report OK ('Disk: {0} free on {1}' -f (GiB $drive.AvailableFreeSpace), $drive.Name)
    }
} catch {
    Report WARN ('Disk: free space on the cache drive could not be read ({0})' -f $_.Exception.Message)
}

$dxil = $env:VICTORY_DXIL
if (-not $dxil) {
    $kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
    $found = Get-ChildItem -LiteralPath $kits -Filter dxil.dll -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { $dxil = $found.FullName }
}
if ($dxil -and (Test-Path -LiteralPath $dxil -PathType Leaf)) {
    Report OK "dxil.dll: $dxil"
} else {
    Report WARN 'dxil.dll: not found (only needed for "victory translate --validate"; set VICTORY_DXIL)'
}

Write-Host ''
Write-Host ('Summary: {0} OK, {1} WARN, {2} FAIL' -f $counts.OK, $counts.WARN, $counts.FAIL)
if ($counts.FAIL -gt 0) { exit 1 }
