# Install the Zeo Windows build toolchain in the guest (docs/ZEO-PLATFORMS-PROPOSAL.md W3).
#
#     provision.ps1 -Inputs C:\zeo-inputs
#
# The host copies inputs.lock and every file it names into -Inputs (release/windows/provision.sh
# does both); nothing here downloads except the Visual Studio installer, which fetches its
# components from Microsoft and checks their signatures itself. Each file is checked against
# its sha256 before it runs. Idempotent: a tool already installed is skipped.
#
# Writes C:\zeo-toolchain.txt, the versions a release's PROVENANCE quotes.
[CmdletBinding()]
Param([Parameter(Mandatory)][string]$Inputs)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Log([string]$event, [string]$detail = '') {
    Write-Output ("provision event={0} {1}" -f $event, $detail).TrimEnd()
}

# Every inputs.lock entry, checked by hash: name -> path.
$files = @{}
foreach ($line in Get-Content (Join-Path $Inputs 'inputs.lock')) {
    if ($line -match '^\s*(#|$)') { continue }
    $name, $url, $sum = $line -split "`t"
    $path = Join-Path $Inputs $name
    $actual = (Get-FileHash -Algorithm SHA256 $path).Hash
    if ($actual -ne $sum.ToUpper()) {
        throw "provision event=hash-mismatch name=$name expected=$sum actual=$actual"
    }
    $files[$name] = $path
}
Log 'inputs-checked' "count=$($files.Count)"

function Run([string]$file, [string[]]$arguments, [int[]]$ok = @(0)) {
    $process = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
    if ($ok -notcontains $process.ExitCode) {
        throw "provision event=install-failed file=$file exit=$($process.ExitCode)"
    }
}

# Zed's tree nests deep; without long paths, cargo fails on some registry paths.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord
# Defender scanning every object file slows a build by a large factor; exclude the build tree only.
New-Item -ItemType Directory -Force -Path 'C:\zeo' | Out-Null
Add-MpPreference -ExclusionPath 'C:\zeo', "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup"
# The paths alone were not enough: on the first release build (2026-11-17) Defender used more CPU
# than any rustc, scanning what the toolchain opens and the temporary files it writes. The
# operator approved excluding the build's processes and TEMP, in this build guest only.
Add-MpPreference -ExclusionProcess 'rustc.exe', 'cargo.exe', 'link.exe', 'cl.exe', 'lld-link.exe', 'cmake.exe' -ExclusionPath $env:TEMP

if (-not (Test-Path 'C:\Program Files\Git\cmd\git.exe')) {
    Run $files['Git-64-bit.exe'] @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES')
    Log 'installed' 'tool=git'
}
if (-not (Test-Path 'C:\Program Files\CMake\bin\cmake.exe')) {
    Run msiexec.exe @('/i', "`"$($files['cmake-windows-x86_64.msi'])`"", '/qn', 'ADD_CMAKE_TO_PATH=System')
    Log 'installed' 'tool=cmake'
}
if (-not (Test-Path 'C:\Program Files\LLVM\bin\clang.exe')) {
    Run msiexec.exe @('/i', "`"$($files['LLVM-win64.msi'])`"", '/qn')
    Log 'installed' 'tool=llvm'
}
if (-not (Test-Path 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe')) {
    Run $files['innosetup.exe'] @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')
    Log 'installed' 'tool=inno-setup'
}

if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) {
    Run msiexec.exe @('/i', "`"$($files['PowerShell-win-x64.msi'])`"", '/qn', 'ADD_PATH=1', 'DISABLE_TELEMETRY=1', 'USE_MU=0', 'ENABLE_MU=0')
    Log 'installed' 'tool=powershell-7'
}

# The VS bootstrapper must be Microsoft's, whatever its hash says.
$vs = $files['vs_community.exe']
$signature = Get-AuthenticodeSignature $vs
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "provision event=bad-signature file=vs_community.exe status=$($signature.Status)"
}
$vsDevShell = 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1'
if (-not (Test-Path $vsDevShell)) {
    # What Zed's Windows build docs require: MSVC, its Spectre-mitigated libraries, and a
    # Windows SDK; 10.0.26100 is the one bundle-windows.ps1 calls makeAppx from.
    $components = @(
        'Microsoft.VisualStudio.Workload.NativeDesktop',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre',
        'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    )
    $arguments = @('--quiet', '--wait', '--norestart', '--nocache')
    foreach ($component in $components) { $arguments += @('--add', $component) }
    # 3010: installed, restart pending.
    Run $vs $arguments @(0, 3010)
    Log 'installed' 'tool=visual-studio-2022-community'
}

$rustup = "$env:USERPROFILE\.cargo\bin\rustup.exe"
if (-not (Test-Path $rustup)) {
    Run $files['rustup-init.exe'] @('-y', '--profile', 'minimal', '--default-toolchain', 'none', '--no-modify-path')
    Log 'installed' 'tool=rustup'
}
# The toolchain is the tree's: rust-toolchain.toml's channel, read by the build itself.
& $rustup toolchain install 1.98.1 --profile minimal --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw "provision event=install-failed tool=rust-1.98.1" }

# cargo-about, at the version Zed's generate-licenses.ps1 pins (0.8.2). Installed here with
# --locked, because that script would otherwise `cargo install` it unlocked in the middle of a
# release build. Its stderr is progress output, so Windows PowerShell must not see it as an error.
$cargoAbout = "$env:USERPROFILE\.cargo\bin\cargo-about.exe"
if (-not (Test-Path $cargoAbout) -or ((& $cargoAbout --version) -notmatch '^cargo-about 0\.8\.2$')) {
    $ErrorActionPreference = 'Continue'
    & $rustup run 1.98.1 cargo install --locked cargo-about --version 0.8.2 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "provision event=install-failed tool=cargo-about exit=$code" }
    Log 'installed' 'tool=cargo-about'
}

# Machine PATH for the tools whose installers do not add themselves.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($dir in @('C:\Program Files\LLVM\bin', 'C:\Program Files (x86)\Inno Setup 6')) {
    if (($machinePath -split ';') -notcontains $dir) { $machinePath = "$machinePath;$dir" }
}
[Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')

# Windows PowerShell turns any stderr line of a native command into a terminating error under
# 'Stop', and `rustup --version` prints an "info:" note there (2026-11-17); the versions are
# read with that relaxed.
$ErrorActionPreference = 'Continue'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$versions = @(
    "windows=$((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version)",
    "visual-studio=$(& $vswhere -latest -property catalog_productDisplayVersion)",
    "msvc=$((Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC' | Sort-Object Name | Select-Object -Last 1).Name)",
    "windows-sdk=$((Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory | Where-Object Name -match '^10\.' | Sort-Object Name | Select-Object -Last 1).Name)",
    "git=$(& 'C:\Program Files\Git\cmd\git.exe' --version)",
    "cmake=$((& 'C:\Program Files\CMake\bin\cmake.exe' --version)[0])",
    "llvm=$((& 'C:\Program Files\LLVM\bin\clang.exe' --version)[0])",
    # ISCC.exe carries no version resource (0.0.0.0, 2026-11-17); its uninstall entry does.
    "inno-setup=$((Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1' -ErrorAction SilentlyContinue | Select-Object -First 1).DisplayVersion)",
    # @() keeps a one-line output an array, so [0] is the line and not its first character.
    "rustup=$(@(& $rustup --version 2>$null)[0])",
    "rustc=$(& $rustup run 1.98.1 rustc --version)",
    "powershell=$(& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')",
    "cargo-about=$(& $cargoAbout --version)"
)
$versions | Set-Content -Path 'C:\zeo-toolchain.txt' -Encoding utf8
$versions | ForEach-Object { Log 'version' $_ }
Log 'done'
