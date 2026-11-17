#!/usr/bin/env bash
# shellcheck disable=SC2016  # remote scripts are single-quoted: they expand on the host
# Run Zeo's portable release build on a remote build host (bentoo-lab), not here.
#
#     lab.sh build  <PF> [--jobs N]   send the inputs, start the build detached, return
#     lab.sh status <PF>              state of that build; exit 0 ok · 1 failed · 3 running
#     lab.sh log    <PF> [-f]         its log (-f follows it)
#     lab.sh stop   <PF>              stop that build: its runner, then its container
#     lab.sh fetch  <PF>              bring out/dist back and check its SHA256SUMS
#     lab.sh clean  <PF>              drop that version's tree on the host (caches stay)
#     lab.sh df                       free space on the host
#
# Why: a Zed build takes every core and tens of GB of RAM, and this desktop has other
# projects open. The host is slower but otherwise idle, and a build there cannot pick
# up this host's target-cpu RUSTFLAGS.
#
# What runs there is release-portable.sh itself, unchanged, under podman: its build is
# already a container fed by bind-mounted inputs, so the host needs only those inputs
# and a container engine -- no Rust, no Portage. `build` rsyncs, under ZP_LAB_ROOT:
#
#   src/zed-patches/    this repository's files as they stand (tracked + untracked,
#                       minus ignored), so an uncommitted series builds as it is
#   src/zeo/CHANGELOG.md  release-portable.sh refuses a version without its section
#   overlay/app-editors/zeo/   the ebuild, Manifest and files/ (icons)
#   distfiles/          the Zed archive and the prebuilt WebRTC the Manifest names
#   portable/           ZP_PORTABLE_DIR: <PF>/{work,out}, sccache/, cargo-home/
#   jobs/<PF>/          log, pid, rc of the detached run
#
# The host is a live system on bentoo-lab: everything outside ZP_LAB_ROOT is gone on
# reboot, so all state lives there. One build at a time (flock on ZP_LAB_ROOT/.lock).
# The Flatpak is skipped there (flatpak-builder runs on the host, which has none).
#
# Environment:
#   ZP_LAB_HOST      ssh destination (default bentoo-lab); "local" runs on this
#                    machine instead -- the self-test's seam, not for real builds
#   ZP_LAB_ROOT      state directory on the host (default /mnt/work/zeo-lab)
#   ZP_LAB_JOBS      CPUs for the build when --jobs is not given (default 12 of the
#                    host's 16, leaving room for Shidashi's VMs on the same worker)
#   ZP_LAB_MIN_FREE_GB  refuse to start below this much free space (default 30;
#                    a build needs ~22 GB: tree 14, sccache 4.5, cargo-home 3)
#   ZP_LAB_FETCH_DIR artefacts land in <dir>/<PF> (default ~/.cache/zeo-portable/lab)
#   plus what lib.sh resolves locally: ZP_OVERLAY, ZP_DISTDIR, ZP_CHANGELOG.
#
# It never publishes. Events are key=value lines on stdout.
#
# Exit: 0 ok · 1 the build failed, was stopped, or was lost · 2 environment problem · 3 running.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB_HOST="${ZP_LAB_HOST:-bentoo-lab}"
LAB_ROOT="${ZP_LAB_ROOT:-/mnt/work/zeo-lab}"

usage() {
	# the header comment, from after the shellcheck line to the first blank line
	sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed -e '/^$/d' -e 's/^# \{0,1\}//'
	exit 2
}

# remote <script> [args...] — run a bash script on the host, args passed safely
# (the script travels on stdin, so nothing is re-parsed by a remote shell).
remote() {
	local script="$1"
	shift
	if [[ "${LAB_HOST}" == local ]]; then
		bash -s -- "$@" <<<"${script}"
	else
		# shellcheck disable=SC2029  # the quoting below is the point
		ssh -o BatchMode=yes "${LAB_HOST}" "bash -s -- $(printf '%q ' "$@")" <<<"${script}"
	fi
}

# dest <path> — rsync's spelling of a path on the host.
dest() {
	if [[ "${LAB_HOST}" == local ]]; then
		printf '%s' "$1"
	else
		printf '%s:%s' "${LAB_HOST}" "$1"
	fi
}

sync_to() {
	rsync -a --partial "$@"
}

valid_pf() {
	[[ "$1" =~ ^zeo-[0-9]+\.[0-9]+\.[0-9]+_p[0-9]{8}(-r[0-9]+)?$ ]] ||
		die 2 "not a zeo PF: $1 (expected e.g. zeo-0.12.0_p20261114)"
}

cmd_df() {
	remote 'set -euo pipefail; mkdir -p "$1"; printf "host=%s root=%s free_gb=%s\n" "$(hostname)" "$1" "$(df -BG --output=avail "$1" | tail -1 | tr -dc 0-9)"' "${LAB_ROOT}"
}

cmd_build() {
	local pf="" jobs="${ZP_LAB_JOBS:-12}"
	while (($#)); do
		case "$1" in
		--jobs)
			jobs="${2:-}"
			shift 2 || die 2 "--jobs needs a number"
			;;
		-*) die 2 "unknown option: $1" ;;
		*)
			pf="$1"
			shift
			;;
		esac
	done
	[[ -n "${pf}" ]] || usage
	valid_pf "${pf}"
	[[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || die 2 "--jobs must be a positive integer, got: ${jobs}"
	resolve_version "${pf}"

	local changelog webrtc
	changelog="$(zeo_changelog)"
	[[ -f "${changelog}" ]] || die 2 "changelog not found: ${changelog}"
	webrtc="$(grep -oE 'webrtc-[^ ]*-linux-x64-release\.zip' "$(dirname "${ZP_EBUILD}")/Manifest" | head -1)"
	[[ -f "${ZP_DISTFILE}" ]] || die 2 "Zed archive missing: ${ZP_DISTFILE} (ebuild ... fetch first)"
	[[ -n "${webrtc}" && -f "${ZP_DISTDIR}/${webrtc}" ]] || die 2 "prebuilt WebRTC missing from ${ZP_DISTDIR}"

	# Refuse early: busy, or too little space. Both are checked again by the
	# runner itself, which is what actually holds the lock.
	remote 'set -euo pipefail
		root="$1" min="$2"
		mkdir -p "${root}"
		exec 9>"${root}/.lock"
		flock -n 9 || { echo "error: a build is already running on $(hostname) (${root}/.lock)" >&2; exit 75; }
		free="$(df -BG --output=avail "${root}" | tail -1 | tr -dc 0-9)"
		(( free >= min )) || { echo "error: ${free} GB free under ${root}, need ${min}" >&2; exit 28; }
		command -v podman >/dev/null || { echo "error: podman missing on $(hostname)" >&2; exit 2; }' \
		"${LAB_ROOT}" "${ZP_LAB_MIN_FREE_GB:-30}" || die 2 "the host refused the build (see above)"

	printf 'event=sync host=%s pf=%s\n' "${LAB_HOST}" "${pf}"
	remote 'mkdir -p "$1"/src/zed-patches "$1"/src/zeo "$1"/overlay/app-editors "$1"/distfiles "$1"/jobs' "${LAB_ROOT}"
	(cd "${ZP_REPO}" &&
		git ls-files -z --cached --others --exclude-standard |
		while IFS= read -r -d '' f; do [[ -e "${f}" ]] && printf '%s\0' "${f}"; done |
			sync_to --from0 --files-from=- ./ "$(dest "${LAB_ROOT}/src/zed-patches/")") ||
		die 2 "rsync of ${ZP_REPO} failed"
	sync_to "${changelog}" "$(dest "${LAB_ROOT}/src/zeo/CHANGELOG.md")" || die 2 "rsync of the changelog failed"
	sync_to --delete "$(dirname "${ZP_EBUILD}")/" "$(dest "${LAB_ROOT}/overlay/${ZP_CATEGORY_PATH}/")" ||
		die 2 "rsync of the overlay package failed"
	sync_to "${ZP_DISTFILE}" "${ZP_DISTDIR}/${webrtc}" "$(dest "${LAB_ROOT}/distfiles/")" ||
		die 2 "rsync of the distfiles failed"

	remote 'set -euo pipefail
		root="$1" pf="$2" jobs="$3"
		job="${root}/jobs/${pf}"
		mkdir -p "${job}"
		rm -f "${job}/rc"
		cat >"${job}/run.sh" <<EOS
#!/usr/bin/env bash
exec 9>"${root}/.lock"
if ! flock -n 9; then echo "event=busy" ; echo 75 >"${job}/rc"; exit 75; fi
echo "event=start pf=${pf} jobs=${jobs} host=\$(hostname) at=\$(date -Is)"
# /var/tmp is on the live root, itself an overlay: podman cannot stack its build
# context overlay there ("mount overlay ... invalid argument"). Keep it on the disk.
mkdir -p "${root}/tmp"
export TMPDIR="${root}/tmp"
ZP_CONTAINER_ENGINE=podman ZP_PORTABLE_JOBS="${jobs}" ZP_PORTABLE_DIR="${root}/portable" \
ZP_OVERLAY="${root}/overlay" ZP_DISTDIR="${root}/distfiles" ZP_REPO="${root}/src/zed-patches" \
	bash "${root}/src/zed-patches/scripts/release-portable.sh" "${pf}" --no-flatpak
rc=\$?
echo "event=done pf=${pf} rc=\${rc} at=\$(date -Is)"
echo "\${rc}" >"${job}/rc"
EOS
		setsid nohup bash "${job}/run.sh" >"${job}/log" 2>&1 </dev/null &
		echo $! >"${job}/pid"
		printf "event=started pf=%s jobs=%s pid=%s log=%s\n" "${pf}" "${jobs}" "$!" "${job}/log"' \
		"${LAB_ROOT}" "${pf}" "${jobs}"
}

cmd_status() {
	local pf="${1:-}"
	[[ -n "${pf}" ]] || usage
	valid_pf "${pf}"
	local rc=0
	remote 'root="$1" pf="$2"; job="${root}/jobs/${pf}"
		[[ -d "${job}" ]] || { echo "state=absent pf=${pf}"; exit 1; }
		if [[ -f "${job}/rc" ]]; then
			rc="$(cat "${job}/rc")"
			if [[ "${rc}" == 0 ]]; then echo "state=done pf=${pf} rc=0"; s=0
			elif [[ "${rc}" == stopped ]]; then echo "state=stopped pf=${pf}"; s=1
			else echo "state=failed pf=${pf} rc=${rc}"; s=1; fi
		elif kill -0 "$(cat "${job}/pid" 2>/dev/null)" 2>/dev/null; then
			echo "state=running pf=${pf}"; s=3
		else
			echo "state=lost pf=${pf}"; s=1
		fi
		tail -n 15 "${job}/log" 2>/dev/null | sed "s/^/  /"
		exit "${s}"' "${LAB_ROOT}" "${pf}" || rc=$?
	return "${rc}"
}

cmd_log() {
	local pf="${1:-}" follow="${2:-}"
	[[ -n "${pf}" ]] || usage
	valid_pf "${pf}"
	remote 'if [[ "$3" == -f ]]; then exec tail -n +1 -F "$1/jobs/$2/log"; else cat "$1/jobs/$2/log"; fi' \
		"${LAB_ROOT}" "${pf}" "${follow}"
}

# The runner was started by setsid, so its pid is its process group: TERM to the
# group reaches release-portable.sh and the podman client. The container itself
# may outlive that (podman stop waits, then kills), so it is stopped by name: only
# lab builds run zeo-portable images, and the lock allows one at a time.
cmd_stop() {
	local pf="${1:-}"
	[[ -n "${pf}" ]] || usage
	valid_pf "${pf}"
	remote 'set -uo pipefail; root="$1" pf="$2"; job="${root}/jobs/${pf}"
		pid="$(cat "${job}/pid" 2>/dev/null)"
		if [[ -f "${job}/rc" || -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
			echo "error: ${pf} is not running on $(hostname)" >&2; exit 1
		fi
		kill -TERM -- "-${pid}" 2>/dev/null
		if command -v podman >/dev/null; then
			podman ps --format "{{.ID}} {{.Image}}" | while read -r id image; do
				[[ "${image}" == *zeo-portable:* ]] && podman stop -t 10 "${id}" >/dev/null
			done
		fi
		for _ in $(seq 1 30); do kill -0 "${pid}" 2>/dev/null || break; sleep 0.5; done
		kill -KILL -- "-${pid}" 2>/dev/null
		echo stopped >"${job}/rc"
		echo "event=stopped pf=${pf} at=$(date -Is)" | tee -a "${job}/log"' "${LAB_ROOT}" "${pf}"
}

cmd_fetch() {
	local pf="${1:-}"
	[[ -n "${pf}" ]] || usage
	valid_pf "${pf}"
	local into="${ZP_LAB_FETCH_DIR:-${HOME}/.cache/zeo-portable/lab}/${pf}"
	mkdir -p "${into}"
	sync_to --delete "$(dest "${LAB_ROOT}/portable/${pf}/out/dist/")" "${into}/" ||
		die 1 "nothing to fetch for ${pf} (did the build finish? lab.sh status ${pf})"
	local sums
	sums="$(find "${into}" -maxdepth 1 -name 'SHA256SUMS-portable-*' -printf '%f\n' | head -1)"
	[[ -n "${sums}" ]] || die 1 "no SHA256SUMS in ${into}"
	(cd "${into}" && sha256sum -c --quiet "${sums}") || die 1 "checksum mismatch in ${into}"
	printf 'event=fetched pf=%s dir=%s\n' "${pf}" "${into}"
	ls -la "${into}"
}

cmd_clean() {
	local pf="${1:-}"
	[[ -n "${pf}" ]] || usage
	valid_pf "${pf}"
	remote 'set -euo pipefail; root="$1" pf="$2"
		exec 9>"${root}/.lock"
		flock -n 9 || { echo "error: a build is running; not cleaning" >&2; exit 75; }
		rm -rf -- "${root}/portable/${pf}" "${root}/jobs/${pf}"
		echo "event=cleaned pf=${pf}"' "${LAB_ROOT}" "${pf}"
}

main() {
	local sub="${1:-}"
	(($#)) && shift
	case "${sub}" in
	build) cmd_build "$@" ;;
	status) cmd_status "$@" ;;
	log) cmd_log "$@" ;;
	stop) cmd_stop "$@" ;;
	fetch) cmd_fetch "$@" ;;
	clean) cmd_clean "$@" ;;
	df) cmd_df ;;
	*) usage ;;
	esac
}

main "$@"
