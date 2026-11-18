# First-logon script of the Zeo Windows build guest (autounattend.xml.in): make the guest
# reachable over ssh with the host's key, and keep it still while it builds.
#
# Runs from the answers ISO (volume label ZEOANSWERS), which build-answers.sh fills with this
# script, the Win32-OpenSSH MSI, its sha256 and the host's public key.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = 'C:\zeo-setup-ssh.log'
Start-Transcript -Path $log -Append

# The MSI is checked against the hash build-answers.sh recorded when it put it on the ISO.
$msi = Join-Path $root 'OpenSSH-Win64.msi'
$expected = (Get-Content (Join-Path $root 'OpenSSH-Win64.msi.sha256') -Raw).Trim().Split(' ')[0]
$actual = (Get-FileHash -Algorithm SHA256 $msi).Hash
if ($actual -ne $expected.ToUpper()) {
    throw "setup-ssh event=hash-mismatch file=OpenSSH-Win64.msi expected=$expected actual=$actual"
}
Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', 'ADDLOCAL=Server' -Wait

# An administrator's key lives in administrators_authorized_keys, readable by SYSTEM and
# Administrators only, or sshd ignores it.
$keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Copy-Item (Join-Path $root 'authorized_key.pub') $keys -Force
icacls.exe $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

# Key authentication only, and PowerShell as the shell the host's commands run in.
$config = 'C:\ProgramData\ssh\sshd_config'
if (-not (Test-Path $config)) {
    Copy-Item 'C:\Program Files\OpenSSH\sshd_config_default' $config
}
Add-Content $config "`nPasswordAuthentication no`nPubkeyAuthentication yes"
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
if (-not (Get-NetFirewallRule -Name 'zeo-sshd' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'zeo-sshd' -DisplayName 'OpenSSH (zeo build guest)' -Direction Inbound `
        -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
}
Set-Service sshd -StartupType Automatic
Restart-Service sshd

# A build that takes an hour must not be interrupted: no sleep, and no automatic updates that
# change the toolchain under it (the provisioner pins every installer; updates are run by hand).
powercfg.exe /change standby-timeout-ac 0
powercfg.exe /change hibernate-timeout-ac 0
# The NoAutoUpdate policy holds on Pro and above; Home ignores Windows Update policies, and the
# operator's key is Home (2026-11-17). Home does honour the pause that Settings offers, so the
# pause is written directly, with the ceiling Settings enforces raised to a year. Resuming is
# Settings > Windows Update > Resume, or deleting the Pause* values.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
New-Item -Path $ux -Force | Out-Null
$start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$end = (Get-Date).AddDays(365).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Set-ItemProperty -Path $ux -Name FlightSettingsMaxPauseDays -Value 365 -Type DWord
Set-ItemProperty -Path $ux -Name PauseUpdatesStartTime -Value $start -Type String
Set-ItemProperty -Path $ux -Name PauseUpdatesExpiryTime -Value $end -Type String
Set-ItemProperty -Path $ux -Name PauseFeatureUpdatesStartTime -Value $start -Type String
Set-ItemProperty -Path $ux -Name PauseFeatureUpdatesEndTime -Value $end -Type String
Set-ItemProperty -Path $ux -Name PauseQualityUpdatesStartTime -Value $start -Type String
Set-ItemProperty -Path $ux -Name PauseQualityUpdatesEndTime -Value $end -Type String

Write-Output "setup-ssh event=ready host=$env:COMPUTERNAME"
Stop-Transcript
