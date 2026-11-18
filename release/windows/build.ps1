# Build one Zeo Windows release in the build guest (docs/ZEO-PLATFORMS-PROPOSAL.md W4 in the hub).
# scripts/release-windows.sh copies the prepared tree and the pinned inputs in and runs this; it is
# not meant to be run by hand.
#
#     pwsh -File build.ps1 -Src C:\zeo\src -Inputs C:\zeo\inputs -Out C:\zeo\out `
#          -Version 0.13.0_p20261114 -Pvr 0.13.0_p20261114 -Commit <zed sha> [-Jobs 8]
#
# -Src holds the Zed tree with the series applied, the icons and RELEASE_CHANNEL already in place
# (release-windows.sh does that on Linux, where `patch` runs). This checks the pinned inputs again,
# sets the environment the Linux build sets, and runs Zed's own script/bundle-windows.ps1, which
# patch 0127 teaches the zeo channel. Then it assembles the portable zip from the files the
# installer installs and writes build-info.txt for the host's PROVENANCE.
#
# PowerShell 7 only: bundle-windows.ps1 relies on $PSNativeCommandUseErrorActionPreference, and
# generate-licenses.ps1 on `? :`, neither of which Windows PowerShell 5.1 has.
#
# Output in -Out: zeo-<Pvr>-windows-x86_64.zip, Zeo-<Pvr>-x86_64-setup.exe, build-info.txt.
#Requires -Version 7
[CmdletBinding()]
Param(
    [Parameter(Mandatory)][string]$Src,
    [Parameter(Mandatory)][string]$Inputs,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Pvr,
    [Parameter(Mandatory)][string]$Commit,
    # 0: one job per processor the guest has.
    [int]$Jobs = 0
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

function Log([string]$event, [string]$detail = '') {
    Write-Output ("build event={0} {1}" -f $event, $detail).TrimEnd()
}

# The pinned inputs, checked again here: the copy over ssh is the one hop the host's check
# does not cover.
$pinned = @{}
foreach ($line in Get-Content (Join-Path $Inputs 'build-inputs.lock')) {
    if ($line -match '^\s*(#|$)') { continue }
    $name, $url, $sum = $line -split "`t"
    $path = Join-Path $Inputs $name
    $actual = (Get-FileHash -Algorithm SHA256 $path).Hash
    if ($actual -ne $sum.ToUpper()) {
        throw "build event=hash-mismatch name=$name expected=$sum actual=$actual"
    }
    $pinned[$name] = $path
}
Log 'inputs-checked' "count=$($pinned.Count)"

Set-Location $Src
if ((Get-Content 'crates\zed\RELEASE_CHANNEL' -Raw).Trim() -ne 'zeo') {
    throw "build event=wrong-channel file=crates\zed\RELEASE_CHANNEL"
}
foreach ($art in @('crates\zed\resources\app-icon-zeo.png', 'crates\zed\resources\windows\app-icon-zeo.ico')) {
    if (-not (Test-Path $art)) { throw "build event=missing-art file=$art" }
}

# bundle-windows.ps1 takes these from the working directory when present (0127) instead of
# downloading them unchecked.
Copy-Item $pinned['AGS_SDK_v6.3.0.zip'] -Destination '.\AGS_SDK_v6.3.0.zip' -Force
Copy-Item $pinned['Microsoft.Windows.Console.ConPTY.1.25.260710002-preview.nupkg'] `
    -Destination '.\Microsoft.Windows.Console.ConPTY.1.25.260710002-preview.nupkg' -Force

# The prebuilt WebRTC, unpacked where LK_CUSTOM_WEBRTC points, as the ebuild does on Linux.
$webrtcRoot = Join-Path (Split-Path $Src -Parent) 'webrtc'
if (Test-Path $webrtcRoot) { Remove-Item -Recurse -Force $webrtcRoot }
New-Item -ItemType Directory -Path $webrtcRoot | Out-Null
tar.exe -xf $pinned['webrtc-win-x64-release.zip'] -C $webrtcRoot
$webrtc = Join-Path $webrtcRoot 'win-x64-release'
if (-not (Test-Path (Join-Path $webrtc 'webrtc.ninja'))) {
    throw "build event=webrtc-layout dir=$webrtc"
}

# Unlicense joins Zed's accepted licences only with voice input (0067): whisper-rs and
# whisper-rs-sys are under it, as on Linux (build-in-container.sh).
if (Select-String -Path 'Cargo.lock' -Pattern '^name = "whisper-rs-sys"$' -Quiet) {
    $toml = 'script\licenses\zed-licenses.toml'
    $text = Get-Content $toml -Raw
    if ($text -notmatch '(?m)^    "Unlicense",') {
        $text = $text -replace '(?m)^(    "MIT-0",\r?\n)', "`$1    `"Unlicense`",`n"
        Set-Content -Path $toml -Value $text -NoNewline
    }
    if ((Get-Content $toml -Raw) -notmatch '(?m)^    "Unlicense",') {
        throw "build event=licence-list file=$toml"
    }
}

# An ssh session inherits the PATH sshd started with, which predates provisioning; rebuild it.
$env:Path = @(
    "$env:USERPROFILE\.cargo\bin",
    [Environment]::GetEnvironmentVariable('Path', 'Machine'),
    [Environment]::GetEnvironmentVariable('Path', 'User')
) -join ';'

# The environment build-in-container.sh sets for Linux, in its Windows form.
$env:RELEASE_VERSION = $Version
# 0091: the About window's Zed row shows the packaged upstream commit.
$env:ZEO_UPSTREAM_COMMIT = $Commit
$env:ZED_UPDATE_EXPLANATION = 'Update Zeo by installing the new release from https://github.com/zeo-workspace/zeo/releases'
$env:LK_CUSTOM_WEBRTC = $webrtc
# RUSTFLAGS replaces .cargo/config.toml's target rustflags instead of adding to them, so the two
# Windows flags upstream sets there are repeated next to the CPU floor the Linux build uses.
$env:RUSTFLAGS = '--cfg windows_slim_errors -C target-feature=+crt-static -C target-cpu=x86-64-v3'
# Voice input (0067): ggml's fixed x86-64-v3 set, not the build machine's CPU.
$env:GGML_NATIVE = 'OFF'
$env:GGML_CCACHE = 'OFF'
# No WHISPER_DONT_GENERATE_BINDINGS here, unlike Linux: whisper-rs-sys's bundled bindings were
# generated against glibc, so on MSVC their layout asserts fail (_IO_FILE is 208 bytes here, not
# 216; E0080, 2026-11-18). bindgen generates them for this target with LLVM's libclang below.
$env:ZEO_VOICE_CPU_BASELINE = 'x86-64-v3'
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }
$env:CARGO_BUILD_JOBS = "$Jobs"
Log 'environment' "version=$Version commit=$Commit jobs=$Jobs webrtc=$webrtc"

# target\ survives between runs (release-windows.sh leaves it) so a rerun recompiles little, but
# only for the same version: tar keeps the Zed archive's mtimes, which predate a build of the
# previous version, so cargo took 0.13.0's compiled `anthropic` as fresh for 0.14.0 and the
# build failed on a function it lacked (2026-11-18). A new version starts from an empty target\.
$stamp = Join-Path $Src 'target\.zeo-version'
$want = "$Pvr $Commit"
if ((Test-Path 'target') -and (-not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $want)) {
    Log 'target-reset' "was=`"$(if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { 'unknown' })`" now=`"$want`""
    Remove-Item -Recurse -Force 'target'
}
New-Item -ItemType Directory -Force -Path 'target' | Out-Null
Set-Content -Path $stamp -Value $want -NoNewline

# A rerun keeps target\, so drop the previous run's installer.
$setup = Join-Path $Src 'target\Zeo-x86_64.exe'
if (Test-Path $setup) { Remove-Item -Force $setup }

$started = Get-Date
& "$PSHOME\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File '.\script\bundle-windows.ps1'
Log 'bundled' "minutes=$([int]((Get-Date) - $started).TotalMinutes)"

$inno = Join-Path $Src 'inno\x86_64'
# zeo.exe writes UTF-8; read with the console's OEM code page, its en dash came out as "ΓÇô" in
# the first PROVENANCE (2026-11-18).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cliVersion = (& (Join-Path $inno 'bin\zeo.exe') --version | Out-String).Trim()
Log 'cli-version' "output=`"$cliVersion`""

# The portable zip: exactly what the installer puts in the install directory.
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
$name = "zeo-$Pvr-windows-x86_64"
$stage = Join-Path $Out $name
New-Item -ItemType Directory -Path $stage | Out-Null
$runtime = @('Zeo.exe', 'bin', 'conpty.dll', 'amd_ags_x64.dll', 'x64', 'arm64', 'zeo-remote-server')
foreach ($item in $runtime) {
    $from = Join-Path $inno $item
    if (Test-Path $from) {
        Copy-Item $from -Destination $stage -Recurse
    } elseif ($item -ne 'zeo-remote-server') {
        throw "build event=missing-runtime-file file=$item"
    }
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath (Join-Path $Out "$name.zip")
Remove-Item -Recurse -Force $stage
Copy-Item $setup -Destination (Join-Path $Out "Zeo-$Pvr-x86_64-setup.exe")

$info = @(
    "version=$Version",
    "pvr=$Pvr",
    "zed-commit=$Commit",
    "rustflags=$env:RUSTFLAGS",
    "cli-version=$cliVersion",
    "remote-server=$(if (Test-Path (Join-Path $inno 'zeo-remote-server')) { 'bundled' } else { 'absent' })"
) + (Get-Content 'C:\zeo-toolchain.txt')
$info | Set-Content -Path (Join-Path $Out 'build-info.txt') -Encoding utf8
Log 'done' "out=$Out"
