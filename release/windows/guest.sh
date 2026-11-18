#!/usr/bin/env bash
# Create and drive the Zeo Windows build guest (docs/ZEO-PLATFORMS-PROPOSAL.md W3 in the hub).
#
#     release/windows/guest.sh create <windows11.iso> [--edition "Windows 11 Home"]
#     release/windows/guest.sh ip
#     release/windows/guest.sh ssh [command...]
#     release/windows/guest.sh provision
#     release/windows/guest.sh put <guest-dir> <file>...
#     release/windows/guest.sh get <guest-path> <local-dir>
#     release/windows/guest.sh start | stop | status | screenshot <file.png>
#     release/windows/guest.sh autologon
#     release/windows/guest.sh keys <chord|text:...>...   (lab only: ctrl-shift-p text:about ret)
#
# ZEO_WIN_HOST picks where the guest runs: `lab` (default), QEMU on bentoo-lab under its slot
# ledger (guest-lab.sh), or `local`, libvirt on this desktop. The guest lives on the lab only
# since 2026-11-18, when the desktop's copy was removed (operator's call); `local` stays for
# `create`, which installs a new guest here from the ISO before it is moved. Every command but
# create and provision works on both; screenshot is lab-only.
#
# create   a libvirt guest "zeo-win" in pool "zeo-win" (/var/lib/libvirt/images/zeo-win): q35,
#          UEFI with Secure Boot, a software TPM 2.0 (Windows 11 requires both), a 100 GB SATA
#          disk and an e1000e NIC on the default network -- devices Windows drives out of the
#          box. The install is unattended (autounattend.xml.in via build-answers.sh) and ends
#          with sshd listening; `ip` then answers. The ISO is checked against Microsoft's
#          published sha256 for "English 64-bit" before anything is created.
# provision  copies inputs.lock and its files (downloaded into the host cache once, each
#          checked by hash) into C:\zeo-inputs and runs provision.ps1 there.
# put/get  copy files in and out (scp; used by scripts/release-windows.sh). Guest paths take
#          forward slashes: C:/zeo/inputs.
# autologon  signs builder in to the desktop at every boot, so a GUI proof has a session to run
#          in (the answer file's auto-logon covers the first boot only). The password goes over
#          ssh's stdin, never an argument; Windows keeps it in the Winlogon DefaultPassword
#          value, readable by the guest's administrators (operator's choice, 2026-11-18).
#
# The guest is pet infrastructure on purpose: one toolchain, versioned here, recorded by
# provision.ps1 in C:\zeo-toolchain.txt. Its secrets (ssh key, the builder password) are in
# ${ZEO_WIN_CONFIG:-~/.config/zeo-win}; the Windows licence key never passes through here --
# the operator enters it in the guest's Settings.
#
# Exit: 0 done · 1 a check failed · 2 environment problem.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conn="qemu:///system"
name="zeo-win"
pool_dir="/var/lib/libvirt/images/${name}"
config="${ZEO_WIN_CONFIG:-${HOME}/.config/zeo-win}"
cache="${ZEO_WIN_CACHE:-/var/tmp/zeo-win/inputs}"
# Microsoft's software-download page, 2026-11-17: Windows 11 multi-edition ISO, English 64-bit.
iso_sha256="bd4307df32bc8af33b39ccecb1174aeb345386630f89a2b86c7a4e36b55ea650"
# 24 vCPUs and 24 GB, the operator's choice of 2026-11-17 after an 8-vCPU first build: the host has
# 32 threads; the memory stops at 24 GB because the desktop has ~13 GB to spare beyond the guest's
# first 16, and a guest larger than that sends the host into swap. Override per run.
cpus="${ZEO_WIN_CPUS:-24}"
memory_mib="${ZEO_WIN_MEMORY_MIB:-24576}"

die() {
	echo "guest event=error reason=\"$2\"" >&2
	exit "$1"
}
virsh_() { virsh -c "${conn}" "$@"; }

guest_ip() {
	virsh_ domifaddr "${name}" --source lease 2>/dev/null | awk '/ipv4/ { sub(/\/.*/, "", $4); print $4; exit }'
}

# endpoint -- where the guest's sshd is reached: sets `target` (user@address) and the options
# ssh (`via_ssh`) and scp (`via_scp`) need for it. On the lab that is the loopback port the lab
# forwards, through the lab itself, with the host key pinned under its own alias.
endpoint() {
	if [[ "${host_mode}" == lab ]]; then
		lab_seed_key_alias
		target="builder@127.0.0.1"
		via_ssh=(-J "${lab_host}" -p "${lab_port}" -o HostKeyAlias="${lab_key_alias}")
		via_scp=(-J "${lab_host}" -P "${lab_port}" -o HostKeyAlias="${lab_key_alias}")
		return 0
	fi
	local ip
	ip="$(guest_ip)"
	[[ -n "${ip}" ]] || die 1 "the guest has no address yet"
	target="builder@${ip}"
	via_ssh=()
	via_scp=()
}

ssh_() {
	local target via_ssh via_scp
	endpoint
	# Keepalives: a release build holds one session for hours, mostly silent while it links.
	ssh -i "${config}/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 \
		-o ServerAliveInterval=60 -o ServerAliveCountMax=10 \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${config}/known_hosts" \
		"${via_ssh[@]}" "${target}" "$@"
}

# -O: the classic SCP protocol. The guest's sftp subsystem closes the connection as soon as it
# is asked for (Win32-OpenSSH 10.4, 2026-11-17), and scp uses sftp by default.
scp_() {
	scp -O -q -i "${config}/id_ed25519" -o BatchMode=yes -o UserKnownHostsFile="${config}/known_hosts" "$@"
}

put() {
	local dir="${1:?usage: guest.sh put <guest-dir> <file>...}" target via_ssh via_scp
	shift
	(($# > 0)) || die 2 "usage: guest.sh put <guest-dir> <file>..."
	endpoint
	scp_ "${via_scp[@]}" "$@" "${target}:${dir}/" || die 1 "copying into ${dir} failed"
}

get() {
	local path="${1:?usage: guest.sh get <guest-path> <local-dir>}" dir="${2:?usage: guest.sh get <guest-path> <local-dir>}"
	local target via_ssh via_scp
	endpoint
	scp_ "${via_scp[@]}" "${target}:${path}" "${dir}/" || die 1 "copying ${path} out failed"
}

# The desktop guest's start and stop; the lab's are in guest-lab.sh.
local_start() {
	[[ "$(virsh_ domstate "${name}")" == "running" || "$(virsh_ domstate "${name}")" == "executando" ]] ||
		virsh_ start "${name}" >/dev/null
	local deadline=$((SECONDS + 600))
	until ssh_ "exit 0" >/dev/null 2>&1; do
		((SECONDS < deadline)) || die 1 "the guest did not answer ssh within 10 minutes"
		sleep 10
	done
	echo "guest event=ready host=local"
}

local_stop() {
	ssh_ "Stop-Computer -Force" >/dev/null 2>&1 || true
	local deadline=$((SECONDS + 300)) state
	while ((SECONDS < deadline)); do
		state="$(virsh_ domstate "${name}")"
		[[ "${state}" == "shut off" || "${state}" == "desligado" ]] && {
			echo "guest event=stopped host=local"
			return 0
		}
		sleep 5
	done
	die 1 "the guest did not power off within 5 minutes"
}

ensure_pool() {
	virsh_ pool-info "${name}" >/dev/null 2>&1 && return 0
	local xml
	xml="$(mktemp)"
	cat >"${xml}" <<EOF
<pool type='dir'>
  <name>${name}</name>
  <target>
    <path>${pool_dir}</path>
    <permissions><mode>0755</mode><owner>$(id -u)</owner><group>$(getent group libvirt | cut -d: -f3)</group></permissions>
  </target>
</pool>
EOF
	virsh_ pool-define "${xml}" >/dev/null
	rm -f "${xml}"
	virsh_ pool-build "${name}" >/dev/null
	virsh_ pool-start "${name}" >/dev/null
	virsh_ pool-autostart "${name}" >/dev/null
	echo "guest event=pool-created path=${pool_dir}"
}

create() {
	local iso="${1:?usage: guest.sh create <windows11.iso> [--edition NAME]}"
	shift
	[[ -f "${iso}" ]] || die 2 "no such ISO: ${iso}"
	virsh_ dominfo "${name}" >/dev/null 2>&1 && die 1 "guest ${name} already exists"
	echo "guest event=checking-iso file=${iso}"
	echo "${iso_sha256}  ${iso}" | sha256sum --check --status || die 1 "the ISO does not match Microsoft's published sha256"

	ensure_pool
	install -m 0644 "${iso}" "${pool_dir}/windows11.iso"
	bash "${here}/build-answers.sh" "${pool_dir}/answers.iso" "$@"

	virt-install --connect "${conn}" --name "${name}" --osinfo win11 \
		--memory "${memory_mib}" --vcpus "${cpus}" --cpu host-passthrough --machine q35 \
		--boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes \
		--tpm emulator,model=tpm-crb,version=2.0 \
		--disk "path=${pool_dir}/disk.qcow2,size=100,format=qcow2,bus=sata,boot.order=2" \
		--disk "path=${pool_dir}/windows11.iso,device=cdrom,bus=sata,boot.order=1" \
		--disk "path=${pool_dir}/answers.iso,device=cdrom,bus=sata" \
		--network network=default,model=e1000e \
		--graphics spice --video qxl --noautoconsole

	press_cd_prompt
	echo "guest event=installing name=${name} (unattended; watch with: virt-viewer -c ${conn} ${name})"
}

disk_mib() {
	virsh_ vol-info --pool "${name}" disk.qcow2 --bytes | awk '/^(Allocation|Aloca)/ { print int($2 / 1048576) }'
}

# Windows' boot CD shows "Press any key to boot from CD or DVD" for a few seconds, at a time
# that varies with the firmware (20-60 s with the TPM), and otherwise falls through to the
# disk. Blind key presses missed it more often than not (2026-11-17), so watch the screen:
# press when the prompt is up, and only while the disk is still empty -- once Setup has
# written Windows to it, a press would start the install over. Measured at 1280x800: the
# prompt's text averages ~72/1000 in its box and 1 without it.
press_cd_prompt() {
	command -v magick >/dev/null || die 2 "magick (ImageMagick) is needed to watch the console"
	local shot deadline=$((SECONDS + 600)) prompt below
	shot="$(mktemp --suffix=.ppm)"
	while ((SECONDS < deadline)) && (($(disk_mib) < 2048)); do
		if virsh_ screenshot "${name}" "${shot}" >/dev/null 2>&1; then
			prompt="$(magick "${shot}" -crop 150x30+100+35 +repage -format '%[fx:int(1000*mean)]' info:)"
			below="$(magick "${shot}" -crop 600x22+0+65 +repage -format '%[fx:int(1000*mean)]' info:)"
			# The "No bootable option" lines below it mean the prompt already timed out.
			if ((prompt > 30 && below < 5)); then
				virsh_ send-key "${name}" KEY_ENTER >/dev/null
				echo "guest event=cd-prompt-pressed t=${SECONDS}s"
				sleep 3
			fi
		fi
		sleep 0.3
	done
	rm -f "${shot}"
}

autologon() {
	[[ -s "${config}/password" ]] || die 2 "no builder password in ${config}/password"
	# shellcheck disable=SC2016 # PowerShell variables, expanded in the guest.
	ssh_ '$pw = [Console]::In.ReadLine()
$k = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $k -Name AutoAdminLogon -Value "1"
Set-ItemProperty $k -Name DefaultUserName -Value "builder"
Set-ItemProperty $k -Name DefaultDomainName -Value $env:COMPUTERNAME
Set-ItemProperty $k -Name DefaultPassword -Value $pw
# AutoLogonCount counts down and then switches auto-logon off again: that is the first-boot-only
# behaviour this replaces.
Remove-ItemProperty $k -Name AutoLogonCount -ErrorAction SilentlyContinue
# A blanked monitor is a black screenshot; the guest has no one to save the screen for.
powercfg /change monitor-timeout-ac 0
"autologon=" + (Get-ItemProperty $k).AutoAdminLogon' <"${config}/password"
}

provision() {
	local names=() n url sum
	while IFS=$'\t' read -r n url sum; do
		[[ "${n}" =~ ^[[:space:]]*(#|$) ]] && continue
		names+=("${n}")
		if [[ ! -f "${cache}/${n}" ]]; then
			curl -fsSL --retry 3 -o "${cache}/${n}.part" "${url}"
			mv "${cache}/${n}.part" "${cache}/${n}"
		fi
		echo "${sum}  ${cache}/${n}" | sha256sum --check --status || die 1 "hash mismatch: ${n}"
	done <"${here}/inputs.lock"
	echo "guest event=inputs-checked count=${#names[@]}"

	ssh_ "New-Item -ItemType Directory -Force -Path C:\\zeo-inputs | Out-Null"
	local ip
	ip="$(guest_ip)"
	local files=("${here}/inputs.lock" "${here}/provision.ps1")
	for n in "${names[@]}"; do files+=("${cache}/${n}"); done
	scp_ "${files[@]}" "builder@${ip}:C:/zeo-inputs/" || die 1 "copying the inputs to the guest failed"
	ssh_ "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\zeo-inputs\\provision.ps1 -Inputs C:\\zeo-inputs"
}

host_mode="${ZEO_WIN_HOST:-lab}"
case "${host_mode}" in
local) ;;
lab)
	# shellcheck source=release/windows/guest-lab.sh
	source "${here}/guest-lab.sh"
	;;
*) die 2 "ZEO_WIN_HOST must be local or lab, got: ${host_mode}" ;;
esac

install -d "${cache}"
case "${1:-}" in
create)
	shift
	create "$@"
	;;
ip) if [[ "${host_mode}" == lab ]]; then echo "127.0.0.1:${lab_port} via ${lab_host}"; else guest_ip; fi ;;
start) if [[ "${host_mode}" == lab ]]; then lab_start; else local_start; fi ;;
stop) if [[ "${host_mode}" == lab ]]; then lab_stop; else local_stop; fi ;;
status) if [[ "${host_mode}" == lab ]]; then lab_status; else virsh_ domstate "${name}"; fi ;;
screenshot)
	[[ "${host_mode}" == lab ]] || die 2 "screenshot is lab-only; use virsh screenshot ${name} on the desktop"
	shift
	lab_screenshot "$@"
	;;
ssh)
	shift
	ssh_ "$@"
	;;
provision) provision ;;
autologon) autologon ;;
keys)
	[[ "${host_mode}" == lab ]] || die 2 "keys is lab-only"
	shift
	lab_keys "$@"
	;;
put)
	shift
	put "$@"
	;;
get)
	shift
	get "$@"
	;;
*) die 2 "usage: guest.sh create <iso> | ip | ssh [cmd] | provision | put <dir> <file>... | get <path> <dir> | start | stop | status | screenshot <png> | autologon | keys <key>..." ;;
esac
