# shellcheck shell=bash
# The Zeo Windows build guest on bentoo-lab, sourced by guest.sh when ZEO_WIN_HOST=lab.
#
# Why not libvirt there: bentoo-lab is a live system -- its root lives in RAM and only /mnt/work
# survives a reboot -- so a package emerged onto it is gone at the next boot; and its CPU and
# memory are shared through Shidashi's `slot` ledger, which a `virsh start` would bypass
# (operator decision, 2026-11-17). So QEMU runs directly, under `slot run`: the reservation lives
# exactly as long as the QEMU process, and is released if it dies.
#
# The guest is the desktop's, moved on 2026-11-18: disk.qcow2 (compacted, sha256-checked) in
# ${lab_dir}, with copy-on-write off (chattr +C), since btrfs fragments a VM image it rewrites.
# Its UEFI variables started from the lab's own OVMF_VARS_4M.secboot template, the same file
# (sha256) as the desktop's. No TPM: the lab has no swtpm, and the disk is not encrypted
# (manage-bde: Fully Decrypted, 2026-11-18), which is what would have bound it to the desktop's TPM.
#
# The host reaches the guest's sshd through a port the lab forwards on its loopback only
# (hostfwd 127.0.0.1:${lab_port} -> 22), with ssh -J; nothing is exposed on the lab's network.

lab_host="${ZEO_WIN_LAB:-bentoo-lab}"
lab_dir="${ZEO_WIN_LAB_DIR:-/mnt/work/zeo-win}"
lab_port="${ZEO_WIN_LAB_PORT:-2222}"
lab_slot="${ZEO_WIN_LAB_SLOT:-/mnt/work/slots/slot}"
# Seconds between checks while the guest starts (the self-test shortens it).
lab_poll="${ZEO_WIN_LAB_POLL:-10}"
# 12 vCPUs and 32 GB: the operator's choice (2026-11-18) on the lab's 16 threads and 42 GiB slot
# budget, leaving 4 CPUs and 10 GiB to the other consumers. One socket: Windows 11 Home uses a
# single one, and libvirt's default of one socket per vCPU left the desktop guest on a fraction
# of its CPUs (2026-11-18). One thread per core: QEMU cannot present SMT on this AMD CPU without
# topoext ("doesn't support hyperthreading(2)", 2026-11-18), so cores=6,threads=2 came out as 12
# plain cores anyway. The slot reservation adds 1 GiB for QEMU's own overhead.
lab_cpus="${ZEO_WIN_LAB_CPUS:-12}"
lab_memory_gib="${ZEO_WIN_LAB_MEMORY_GIB:-32}"
# The desktop guest's identity, kept so Windows sees the same machine.
lab_uuid="b8b1313b-a786-49e2-b40f-b4d965e535ce"
lab_mac="52:54:00:2d:12:12"
# The name the guest's host key is pinned under in ${config}/known_hosts for this route.
lab_key_alias="zeo-win"

lab_() { ssh -o BatchMode=yes -o ConnectTimeout=10 "${lab_host}" "$@"; }

# lab_seed_key_alias -- pin the guest's known host key under ${lab_key_alias}, from the entry the
# desktop route recorded, so the first lab connection checks it instead of trusting a new one.
lab_seed_key_alias() {
	# shellcheck disable=SC2154 # config, die and ssh_ are guest.sh's, which sources this file.
	local known="${config}/known_hosts" line
	ssh-keygen -F "${lab_key_alias}" -f "${known}" >/dev/null 2>&1 && return 0
	line="$(awk '$2 == "ssh-ed25519" { $1 = ""; print; exit }' "${known}")"
	[[ -n "${line}" ]] || die 2 "no recorded host key for the guest in ${known}"
	printf '%s%s\n' "${lab_key_alias}" "${line}" >>"${known}"
}

# lab_pid -- the running QEMU's pid, or nothing: a pidfile left by a QEMU that died answers empty.
lab_pid() { lab_ "p=\$(cat '${lab_dir}/qemu.pid' 2>/dev/null) && kill -0 \"\$p\" 2>/dev/null && echo \"\$p\"" 2>/dev/null || true; }

lab_running() { [[ -n "$(lab_pid)" ]]; }

# lab_launch_alive -- whether the process lab_start launched is still there. `slot run` execs
# QEMU (its last line is `exec "$@"`), so this is one pid from the reservation to the running
# guest -- alive while slot waits or reserves and while QEMU initialises, before QEMU has written
# qemu.pid. Without it, that window read as "QEMU exited" and the start died while QEMU came up
# and held the slot (2026-11-20, the 0.17.0 Windows build).
lab_launch_alive() {
	lab_ "p=\$(cat '${lab_dir}/launch.pid' 2>/dev/null) && kill -0 \"\$p\" 2>/dev/null" 2>/dev/null
}

lab_start() {
	if lab_running; then
		echo "guest event=already-running host=${lab_host}"
		return 0
	fi
	# shellcheck disable=SC2054 # the commas belong to QEMU's option syntax.
	local args=(
		qemu-system-x86_64 -name zeo-win,process=zeo-win -uuid "${lab_uuid}"
		-machine q35,smm=on,accel=kvm,vmport=off,hpet=off
		-global driver=cfi.pflash01,property=secure,value=on
		-global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1
		# The Hyper-V enlightenments libvirt gave the desktop guest (osinfo win11).
		-cpu host,hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-vpindex,hv-runtime,hv-synic,hv-stimer,hv-frequencies,hv-tlbflush,hv-ipi,hv-time
		-smp "${lab_cpus},sockets=1,cores=${lab_cpus},threads=1"
		-m "${lab_memory_gib}G"
		-rtc base=localtime,driftfix=slew -global kvm-pit.lost_tick_policy=delay
		-drive "if=pflash,format=qcow2,unit=0,readonly=on,file=/usr/share/edk2/OvmfX64/OVMF_CODE_4M.secboot.qcow2"
		-drive "if=pflash,format=qcow2,unit=1,file=${lab_dir}/VARS.qcow2"
		# SATA and e1000e, as on the desktop: the drivers Windows was installed with.
		-drive "file=${lab_dir}/disk.qcow2,format=qcow2,if=none,id=disk0,discard=unmap,cache=none"
		-device ide-hd,bus=ide.0,drive=disk0,bootindex=1
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${lab_port}-:22"
		-device "e1000e,netdev=net0,mac=${lab_mac}"
		-vga std -display none
		-qmp "unix:${lab_dir}/qmp.sock,server=on,wait=off"
		-pidfile "${lab_dir}/qemu.pid"
	)
	# Quoted once more for the lab's shell, which runs the command.
	local quoted
	printf -v quoted '%q ' "${args[@]}"
	# Braces: `&` must background the launch alone. Applied to the whole `cd && rm && ...` list it
	# made a subshell that held ssh's output open, and ssh waited for QEMU to exit (2026-11-18).
	lab_ "cd '${lab_dir}' && rm -f qemu.pid launch.pid && { setsid nohup '${lab_slot}' run --owner zeo-win:build \
		--cpus ${lab_cpus} --memory $((lab_memory_gib + 1)) --wait -1 -- ${quoted} \
		>qemu.log 2>&1 </dev/null & echo \$! >launch.pid; }" || die 1 "starting QEMU on ${lab_host} failed"
	echo "guest event=starting host=${lab_host} cpus=${lab_cpus} memory_gib=${lab_memory_gib}"
	# Ten minutes to answer ssh once QEMU runs; however long the slot queue takes before that
	# (a builder image holds every CPU for longer than ten minutes, 2026-11-18).
	local deadline=$((SECONDS + 600)) queued=0
	while ((SECONDS < deadline)); do
		if ssh_ "exit 0" >/dev/null 2>&1; then
			echo "guest event=ready host=${lab_host} t=${SECONDS}s"
			return 0
		fi
		if ! lab_running; then
			# No QEMU pid yet: dead only if what was launched is gone too.
			if ! lab_launch_alive; then
				lab_ "tail -20 '${lab_dir}/qemu.log'" >&2 || true
				die 1 "QEMU exited on ${lab_host} (log above)"
			fi
			if lab_ "grep -q 'slot: queued' '${lab_dir}/qemu.log'" 2>/dev/null; then
				((queued)) || echo "guest event=queued host=${lab_host} (slot list shows who holds it)"
				queued=1
				deadline=$((SECONDS + 600))
			fi
		fi
		sleep "${lab_poll}"
	done
	die 1 "the guest did not answer ssh within 10 minutes (guest.sh screenshot shows its screen)"
}

# lab_qmp <json-command> -- one QMP command over the guest's monitor socket, through the lab's
# python3 (the lab has no socat).
lab_qmp() {
	lab_ "python3 -I - '${lab_dir}/qmp.sock' '$1'" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()
for cmd in ({"execute": "qmp_capabilities"}, json.loads(sys.argv[2])):
    f.write(json.dumps(cmd) + "\n"); f.flush()
    while True:
        reply = json.loads(f.readline())
        if "return" in reply or "error" in reply:
            break
print(json.dumps(reply))
EOF
}

lab_stop() {
	lab_running || {
		echo "guest event=already-stopped host=${lab_host}"
		return 0
	}
	# Windows ignores an ACPI power button press (as `virsh shutdown` showed, 2026-11-17), so ask
	# it from inside first; the QMP powerdown is the fallback, and quit the last resort.
	ssh_ "Stop-Computer -Force" >/dev/null 2>&1 || lab_qmp '{"execute": "system_powerdown"}' >/dev/null || true
	local deadline=$((SECONDS + 300))
	while ((SECONDS < deadline)); do
		lab_running || {
			echo "guest event=stopped host=${lab_host}"
			return 0
		}
		sleep 5
	done
	lab_qmp '{"execute": "quit"}' >/dev/null || true
	echo "guest event=stopped-by-quit host=${lab_host}"
}

lab_status() {
	if lab_running; then echo "guest event=running host=${lab_host} pid=$(lab_pid)"; else echo "guest event=stopped host=${lab_host}"; fi
	lab_ "'${lab_slot}' list"
}

# lab_screenshot <file.png> -- the guest's screen, for a boot that never reaches sshd.
lab_screenshot() {
	local out="${1:?usage: guest.sh screenshot <file.png>}"
	lab_qmp "{\"execute\": \"screendump\", \"arguments\": {\"filename\": \"${lab_dir}/screen.ppm\"}}" >/dev/null ||
		die 1 "screendump failed"
	lab_ "cat '${lab_dir}/screen.ppm'" | magick ppm:- "${out}" || die 1 "fetching the screenshot failed"
	echo "guest event=screenshot file=${out}"
}

# lab_keys <chord|text:...>... -- key presses into the guest's console over QMP, for GUI proofs:
# `ctrl-shift-p` presses one chord, `text:about` types lowercase letters, digits and spaces one key
# at a time, `ret`/`esc`/`tab` are single keys. QEMU's qcodes are the key names.
lab_keys() {
	local arg chord json c
	for arg in "$@"; do
		if [[ "${arg}" == text:* ]]; then
			local text="${arg#text:}" i
			for ((i = 0; i < ${#text}; i++)); do
				c="${text:i:1}"
				[[ "${c}" == " " ]] && c="spc"
				[[ "${c}" =~ ^([a-z0-9]|spc)$ ]] || die 2 "text: takes a-z, 0-9 and spaces, got: ${c}"
				lab_qmp "{\"execute\": \"send-key\", \"arguments\": {\"keys\": [{\"type\": \"qcode\", \"data\": \"${c}\"}]}}" >/dev/null ||
					die 1 "send-key failed"
			done
			continue
		fi
		json=""
		IFS=- read -ra chord <<<"${arg}"
		for c in "${chord[@]}"; do
			json+="${json:+, }{\"type\": \"qcode\", \"data\": \"${c}\"}"
		done
		lab_qmp "{\"execute\": \"send-key\", \"arguments\": {\"keys\": [${json}]}}" >/dev/null || die 1 "send-key ${arg} failed"
		sleep 0.3
	done
}
