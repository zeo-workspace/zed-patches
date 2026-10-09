#!/usr/bin/env bash
# Catch rebrand drift: what an upstream bump adds that still says "Zed".
#
#     check-rebrand.sh <PF> [--update]
#
# The rebrand patches change the names a user reads and the identifiers that
# keep Zeo apart from an installed Zed. A bump that applies cleanly and compiles
# can still bring new ones in, because upstream keeps writing "Zed": a new menu
# label, a new dialog, a new path joined onto "zed". Nothing that applies or
# builds the series notices that. This does, by comparing the patched source
# against two baselines kept in rebrand/:
#
#   identity-allowlist.txt   every literal naming Zed's *identity* -- its app id,
#                            its binary, its state directory. A new one is a HARD
#                            failure: it may share state with, or launch, an
#                            installed Zed. Each kept entry is a reviewed decision.
#   zed-literals.txt         every string literal containing the word "Zed". A
#                            new one is reported for triage against
#                            zeo/docs/STRINGS.md: rebrand it, or accept it here.
#
# Entries are `path<TAB>literal`, with no line numbers, so code moving inside a
# file is not drift. Tests, fixtures and evals are skipped: they are not shipped.
#
# The series is applied, cumulatively and in order, in a throwaway worktree cut
# from the prepared tree's baseline -- the same way verify.sh applies it. The
# prepared tree itself is never written to.
#
# --update rewrites both baselines from the patched source. Run it only after
# triaging what the plain run reported.
#
# Exit: 0 nothing new · 1 new entries (drift) · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 2
}

# discard_scratch <prepared-tree> <scratch> -- remove the throwaway worktree.
discard_scratch() {
	local tree="$1" scratch="$2"
	[[ -n "${scratch}" && -d "${scratch}" ]] || return 0
	if [[ -d "${scratch}/tree" ]]; then
		git -C "${tree}" worktree remove --force "${scratch}/tree" >/dev/null 2>&1 || true
	fi
	rm -rf "${scratch}"
	git -C "${tree}" worktree prune >/dev/null 2>&1 || true
	return 0
}

# Paths that never ship: tests, fixtures, evals and benchmarks.
NOT_SHIPPED='(^|/)(tests?|fixtures|evals?|benches|test_data|examples)/|_tests?[.]rs$|/test_[^/]*[.]rs$'

# scan_identity <tree> -- `path<TAB>line` for each literal naming Zed's identity.
scan_identity() {
	(cd "$1" && grep -rnE --include='*.rs' \
		'dev\.zed\.Zed|zed-editor|"\./zed"|join\("zed"\)' crates || true) |
		awk -F: -v skip="${NOT_SHIPPED}" '$1 !~ skip {
			path = $1; sub(/^[^:]*:[^:]*:/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
			print path "\t" $0
		}' | LC_ALL=C sort -u
}

# scan_literals <tree> -- `path<TAB>literal` for each string literal saying "Zed".
scan_literals() {
	(cd "$1" && grep -rnoP --include='*.rs' \
		'"(?:[^"\\]|\\.)*\bZed\b(?:[^"\\]|\\.)*"' crates || true) |
		awk -F: -v skip="${NOT_SHIPPED}" '$1 !~ skip {
			path = $1; sub(/^[^:]*:[^:]*:/, "")
			print path "\t" $0
		}' | LC_ALL=C sort -u
}

# report <label> <baseline> <current> <hard> -- prints what is new and what is
# gone; returns 1 when anything is new.
report() {
	local label="$1" baseline="$2" current="$3" hard="$4" added removed
	added="$(LC_ALL=C comm -13 "${baseline}" "${current}")"
	removed="$(LC_ALL=C comm -23 "${baseline}" "${current}")"
	if [[ -z "${added}" ]]; then
		printf 'ok       %s: %d entries, nothing new\n' "${label}" "$(wc -l <"${current}")"
	else
		printf '%s %s: %d new\n' "$([[ "${hard}" == hard ]] && echo 'FAIL    ' || echo 'DRIFT   ')" \
			"${label}" "$(grep -c . <<<"${added}")"
		printf '           + %s\n' "${added//$'\n'/$'\n           + '}"
	fi
	if [[ -n "${removed}" ]]; then
		printf '         %s: %d gone from the source (stale in the baseline)\n' \
			"${label}" "$(grep -c . <<<"${removed}")"
	fi
	[[ -z "${added}" ]]
}

main() {
	local pf="" update=0 arg
	for arg in "$@"; do
		case "${arg}" in
		--update) update=1 ;;
		-h | --help) usage ;;
		-*) die 2 "unknown option: ${arg}" ;;
		*)
			[[ -z "${pf}" ]] || die 2 "more than one version given: ${pf} and ${arg}"
			pf="${arg}"
			;;
		esac
	done
	[[ -n "${pf}" ]] || usage
	grep -qP 'x' <<<x 2>/dev/null || die 2 "grep without -P (PCRE) support"

	resolve_version "${pf}"
	local patch_dir="${ZP_REPO}/patches/${ZP_PV}"
	local series="${patch_dir}/series"
	local baselines="${ZP_REPO}/rebrand"
	[[ -f "${series}" ]] || die 2 "no series for ${ZP_PV}: ${series}"
	[[ -d "${ZP_WORKTREE}" ]] || die 2 "no prepared tree at ${ZP_WORKTREE} -- run: prepare-tree.sh ${ZP_PV}"

	local listing status=0
	listing="$(read_series "${series}" "")" || status=$?
	((status == 0)) || exit "${status}"
	local -a patches=()
	[[ -z "${listing}" ]] || mapfile -t patches <<<"${listing}"
	((${#patches[@]} > 0)) || die 2 "the series selected no patches (series: ${series})"

	local baseline scratch
	baseline="$(git -C "${ZP_WORKTREE}" rev-list --max-parents=0 HEAD 2>/dev/null | tail -n1)" || baseline=""
	[[ -n "${baseline}" ]] || die 2 "the prepared tree at ${ZP_WORKTREE} has no baseline commit"
	mkdir -p "${ZP_WORKROOT}"
	scratch="$(mktemp -d "${ZP_WORKROOT}/.rebrand-XXXXXX")" ||
		die 2 "cannot create a scratch directory under ${ZP_WORKROOT}"
	# shellcheck disable=SC2064
	trap "discard_scratch '${ZP_WORKTREE}' '${scratch}'" EXIT INT TERM
	git -C "${ZP_WORKTREE}" worktree prune >/dev/null 2>&1 || true
	git -C "${ZP_WORKTREE}" worktree add --detach --quiet "${scratch}/tree" "${baseline}" ||
		die 2 "cannot cut a scratch worktree from ${baseline} in ${ZP_WORKTREE}"

	local name
	for name in "${patches[@]}"; do
		(cd "${scratch}/tree" && patch -p1 -f -g0 -s <"${patch_dir}/${name}" >/dev/null 2>&1) ||
			die 2 "${name} does not apply -- run verify.sh ${ZP_PV} first"
	done

	scan_identity "${scratch}/tree" >"${scratch}/identity"
	scan_literals "${scratch}/tree" >"${scratch}/literals"

	if ((update)); then
		mkdir -p "${baselines}"
		cp "${scratch}/identity" "${baselines}/identity-allowlist.txt"
		cp "${scratch}/literals" "${baselines}/zed-literals.txt"
		printf 'rewrote rebrand/identity-allowlist.txt (%d) and rebrand/zed-literals.txt (%d) from %s\n' \
			"$(wc -l <"${scratch}/identity")" "$(wc -l <"${scratch}/literals")" "${ZP_PV}"
		return 0
	fi

	[[ -f "${baselines}/identity-allowlist.txt" && -f "${baselines}/zed-literals.txt" ]] ||
		die 2 "no baselines in ${baselines} -- create them with: check-rebrand.sh ${ZP_PV} --update"

	local drift=0
	report "Zed identity literals" "${baselines}/identity-allowlist.txt" "${scratch}/identity" hard || drift=1
	report "\"Zed\" string literals" "${baselines}/zed-literals.txt" "${scratch}/literals" soft || drift=1
	if ((drift)); then
		printf '\nnew entries above: rebrand them in a patch, or accept them with --update after triage (zeo/docs/STRINGS.md)\n'
		return 1
	fi
	printf '\nno rebrand drift in %s\n' "${ZP_PV}"
}

main "$@"
