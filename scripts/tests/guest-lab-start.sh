#!/usr/bin/env bash
# release/windows/guest-lab.sh's lab_start against a local fake lab: lab_ runs commands
# here instead of over ssh, `slot` and qemu-system-x86_64 are stubs, and ssh_ answers once
# the fake QEMU says the guest booted.
#
# Proves: a QEMU that takes a moment to write its pidfile -- slot reserving its budget,
# QEMU initialising -- is waited for, not reported as exited (the 2026-11-20 race: the
# first check found no pidfile and an empty qemu.log, and lab_start died while QEMU came
# up and held the slot); a QEMU that really exits is still reported, with its log; a
# queued reservation is still announced once and waited for.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${ZP_REPO:-$(cd "${here}/../.." && pwd)}"
guest_lab="${repo}/release/windows/guest-lab.sh"
[[ -f "${guest_lab}" ]] || {
	echo "FAIL: ${guest_lab} not found" >&2
	exit 1
}

tmp="$(mktemp -d)"
trap 'pkill -f "${tmp}/bin/" 2>/dev/null || true; rm -rf "${tmp}"' EXIT
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mkdir -p "${tmp}/bin"
# slot stand-in: honours FAKE_SLOT_QUEUED (prints the ledger's queued line first) and
# FAKE_SLOT_DELAY (the reservation's latency), then execs the command after `--`, as
# the real slot does.
cat >"${tmp}/bin/slot" <<'EOS'
#!/usr/bin/env bash
while (($#)) && [[ "$1" != -- ]]; do shift; done
shift
[[ -n "${FAKE_SLOT_QUEUED:-}" ]] && echo "slot: queued behind another lease" >&2
sleep "${FAKE_SLOT_DELAY:-0}"
exec "$@"
EOS
# QEMU stand-in: FAKE_QEMU_FAIL exits at once with an error, as a QEMU refusing its
# arguments does; otherwise it writes -pidfile after FAKE_QEMU_DELAY, marks the guest
# booted and stays up.
cat >"${tmp}/bin/qemu-system-x86_64" <<'EOS'
#!/usr/bin/env bash
if [[ -n "${FAKE_QEMU_FAIL:-}" ]]; then
	echo "qemu-system-x86_64: -drive file=disk.qcow2: Could not open: No such file" >&2
	exit 1
fi
pidfile=""
while (($#)); do
	[[ "$1" == -pidfile ]] && pidfile="$2"
	shift
done
sleep "${FAKE_QEMU_DELAY:-0}"
echo $$ >"${pidfile}"
touch "${FAKE_BOOTED}"
exec sleep 60
EOS
chmod +x "${tmp}/bin/slot" "${tmp}/bin/qemu-system-x86_64"

# run_start <name> -- lab_start in a subshell against a fresh fake lab dir; prints its
# output and exit status.
run_start() {
	local name="$1"
	local dir="${tmp}/${name}"
	mkdir -p "${dir}"
	(
		export PATH="${tmp}/bin:${PATH}" FAKE_BOOTED="${dir}/booted"
		export ZEO_WIN_LAB_DIR="${dir}" ZEO_WIN_LAB_SLOT="${tmp}/bin/slot" ZEO_WIN_LAB_POLL=1
		die() {
			printf 'die %s: %s\n' "$1" "$2"
			exit "$1"
		}
		# shellcheck source=release/windows/guest-lab.sh
		source "${guest_lab}"
		lab_() { bash -c "$*"; }
		ssh_() { [[ -e "${FAKE_BOOTED}" ]]; }
		lab_start
	) 2>&1 || true
}

# 1. The race: three seconds before the pidfile exists. Must end ready, not "exited".
out="$(FAKE_SLOT_DELAY=1 FAKE_QEMU_DELAY=2 run_start slow)"
grep -q 'guest event=ready' <<<"${out}" || fail "a slow start was not waited for: ${out}"
grep -q 'QEMU exited' <<<"${out}" && fail "a slow start was reported as exited: ${out}"

# 2. A QEMU that dies is still reported, with its own error from qemu.log.
out="$(FAKE_QEMU_FAIL=1 run_start dead)"
grep -q 'QEMU exited' <<<"${out}" || fail "a dead QEMU was not reported: ${out}"
grep -q 'Could not open' <<<"${out}" || fail "the dead QEMU's log was not shown: ${out}"

# 3. A queued reservation is announced once, then the guest comes up.
out="$(FAKE_SLOT_QUEUED=1 FAKE_SLOT_DELAY=2 run_start queued)"
[[ "$(grep -c 'guest event=queued' <<<"${out}")" == 1 ]] || fail "queued not announced once: ${out}"
grep -q 'guest event=ready' <<<"${out}" || fail "a queued start did not end ready: ${out}"

echo "PASS: guest-lab lab_start waits for a slow QEMU, reports a dead one, announces a queue"
