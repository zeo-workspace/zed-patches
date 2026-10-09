#!/usr/bin/env bash
# Run the test suites of the crates the series touches, the way the release ships them.
#
#     test.sh <PF> [--from-tree] [--doc] [--ignored] [--e2e] [-- <nextest args>]
#
# The source tested is the packaged Zed commit with the series applied:
#
#   default       patches/<PF>/series, applied cumulatively onto the prepared
#                 tree's baseline in a scratch worktree (as verify.sh applies it)
#   --from-tree   the prepared tree's working copy as it stands -- for a fix in
#                 progress on a branch there, before it is a series
#
# Either way the tree is copied to ${ZP_TEST_ROOT}/src and given the ebuild's own
# offline [patch] rewrite, so cargo resolves from the same vendored crates
# `ebuild compile` would. The Portage work directory that rewrite points at
# (cargo_home, livekit, the prebuilt WebRTC) is made once with `ebuild unpack`.
#
# Phases, each opt-in except the first:
#
#   (always)    nextest over the crates the series touches: one process per test,
#               as upstream runs it. Built with the system toolchain; RUN with
#               rustup's toolchain first on PATH, because extension_host compiles
#               a wasm32-wasip2 extension and Gentoo's rust has no such target.
#               Building with rustup on PATH would swap rustc and rebuild all.
#   --doc       `cargo test --doc` for the same crates (nextest runs no doctests).
#   --ignored   the upstream-ignored tests, minus the e2e suites (keyless they can
#               only fail on authentication).
#   --e2e       the e2e suites (--features agent/e2e,agent_servers/e2e) against a
#               real model: ANTHROPIC_API_KEY, else the session keyring entry
#               `service anthropic purpose zeo-e2e`. The key is never printed.
#
# Arguments after `--` go to every nextest run (e.g. `-E 'test(foo)'`).
#
# Environment: ZP_TEST_ROOT (default /var/tmp/zeo-test: src/, target/, portage/,
# meta/); ZP_TEST_TARGET and ZP_TEST_WORKDIR to reuse a target directory and an
# unpacked Portage work directory of the same Zed commit -- cargo fingerprints the
# vendored crates' paths, so a new work directory rebuilds every dependency;
# ZP_RUSTUP_TOOLCHAIN (default: the system rustc's version); and the ZP_*
# overrides lib.sh honours.
#
# Exit: 0 every phase passed · 1 a phase failed · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The crates the series touches -- what a regression from a patch can break.
CRATES=(acp_thread agent agent_servers agent_settings agent_tasks_panel agent_ui
	auto_update claude_code_ide cli client extension_host feature_flags icons
	install_cli markdown oauth_callback_server onboarding paths project
	recent_projects release_channel remote_server settings settings_content
	settings_ui sidebar title_bar ui workspace zed zed_credentials_provider)

E2E_FILTER='test(common_e2e) | test(=tests::test_basic_tool_calls) | test(=tests::test_cancellation) | test(=tests::test_concurrent_tool_calls) | test(=tests::test_streaming_tool_calls)'

usage() {
	sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 2
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

main() {
	local pf="" from_tree=0 doc=0 ignored=0 e2e=0
	local -a extra=()
	while (($# > 0)); do
		case "$1" in
		--from-tree) from_tree=1 ;;
		--doc) doc=1 ;;
		--ignored) ignored=1 ;;
		--e2e) e2e=1 ;;
		--) shift; extra=("$@"); break ;;
		-h | --help) usage ;;
		-*) die 2 "unknown option: $1" ;;
		*)
			[[ -z "${pf}" ]] || die 2 "more than one version given: ${pf} and $1"
			pf="$1"
			;;
		esac
		shift
	done
	[[ -n "${pf}" ]] || usage
	for tool in cargo cargo-nextest rsync ebuild; do
		command -v "${tool}" >/dev/null || die 2 "${tool} is not on PATH"
	done

	resolve_version "${pf}"
	local root="${ZP_TEST_ROOT:-/var/tmp/zeo-test}"
	local src="${root}/src" meta="${root}/meta" portage_tmp="${root}/portage"
	local target="${ZP_TEST_TARGET:-${root}/target}"
	local workdir="${ZP_TEST_WORKDIR:-${portage_tmp}/portage/${ZP_CATEGORY_PATH%/*}/${pf}/work}"
	mkdir -p "${src}" "${target}" "${meta}" "${portage_tmp}"
	[[ -d "${ZP_WORKTREE}/.git" ]] || die 2 "no prepared tree at ${ZP_WORKTREE} -- run: prepare-tree.sh ${pf}"

	# --- the Portage work directory the offline rewrite points at ----------------
	if [[ ! -d "${workdir}/cargo_home" ]]; then
		step "ebuild unpack (once per version) -> ${workdir}"
		PORTAGE_TMPDIR="${portage_tmp}" ebuild "${ZP_EBUILD}" clean unpack >"${root}/unpack.log" 2>&1 ||
			die 2 "ebuild unpack failed -- see ${root}/unpack.log"
	fi

	# --- the source -------------------------------------------------------------
	local tree scratch=""
	if ((from_tree)); then
		tree="${ZP_WORKTREE}"
		step "source: the prepared tree's working copy ($(git -C "${tree}" rev-parse --abbrev-ref HEAD))"
	else
		local series="${ZP_REPO}/patches/${pf}/series" name
		[[ -f "${series}" ]] || die 2 "no series for ${pf}: ${series}"
		local baseline
		baseline="$(git -C "${ZP_WORKTREE}" rev-list --max-parents=0 HEAD | tail -n1)"
		scratch="$(mktemp -d "${ZP_WORKROOT}/.test-XXXXXX")"
		# shellcheck disable=SC2064
		trap "git -C '${ZP_WORKTREE}' worktree remove --force '${scratch}/tree' >/dev/null 2>&1; rm -rf '${scratch}'" EXIT
		git -C "${ZP_WORKTREE}" worktree add --detach --quiet "${scratch}/tree" "${baseline}"
		tree="${scratch}/tree"
		step "source: ${pf} series applied onto ${baseline:0:12}"
		while IFS= read -r name; do
			(cd "${tree}" && patch -p1 -f -g0 -s <"${ZP_REPO}/patches/${pf}/${name}" >/dev/null) ||
				die 1 "${name} does not apply -- run verify.sh ${pf}"
		done < <(read_series "${series}" "")
	fi

	# rsync keeps excluded paths, so a cloned test grammar would keep its .git and
	# lose its sources -- "already cloned", and the extension build fails.
	rm -rf "${src}/extensions/test-extension/grammars"
	rsync -a --delete --exclude .git --exclude target --exclude '*.orig' "${tree}/" "${src}/"
	cp "${ZP_OVERLAY}/${ZP_CATEGORY_PATH}/files/"app-icon-zeo*.png "${src}/crates/zed/resources/"
	local body
	body="$(sed -n '/# Cargo offline fetch workaround/,/Cargo fetch workaround failed/p' "${ZP_EBUILD}")"
	[[ -n "${body}" ]] || die 2 "the ebuild's offline fetch rewrite was not found in ${ZP_EBUILD}"
	(
		cd "${src}"
		S="${src}" WORKDIR="${workdir}"
		export S WORKDIR
		# The rewrite calls die; inside this subshell it ends only the subshell.
		# shellcheck disable=SC2329
		die() { echo "die: $*" >&2; exit 1; }
		eval "${body}"
	) || die 2 "the offline rewrite failed"
	grep -q "path = \"${workdir}/livekit" "${src}/Cargo.toml" || die 2 "the offline rewrite changed nothing"
	mkdir -p "${src}/.git"

	local -a sysenv=(env -u RUSTC_WRAPPER CARGO_HOME="${workdir}/cargo_home" CARGO_TARGET_DIR="${target}"
		LK_CUSTOM_WEBRTC="${workdir}/linux-x64-release" RUSTFLAGS="--cfg tokio_unstable --cap-lints=warn")
	local -a pkgs=()
	local crate
	for crate in "${CRATES[@]}"; do pkgs+=(-p "${crate}"); done
	local toolchain="${ZP_RUSTUP_TOOLCHAIN:-$(rustc --version | awk '{print $2}')}"
	local -a runenv=(PATH="${HOME}/.cargo/bin:${PATH}" RUSTUP_TOOLCHAIN="${toolchain}")
	local failed=0

	# nextest_phase <label> <build args...> -- <run args...>
	nextest_phase() {
		local label="$1"
		shift
		local -a build=() run=()
		while (($# > 0)) && [[ "$1" != -- ]]; do build+=("$1"); shift; done
		[[ "${1:-}" == -- ]] && shift
		run=("$@")
		step "${label}"
		(cd "${src}" && "${sysenv[@]}" cargo --config term.verbose=false nextest list --offline \
			"${build[@]}" --list-type binaries-only --message-format json >"${meta}/binaries.json") ||
			{ failed=1; return 0; }
		(cd "${src}" && "${sysenv[@]}" cargo metadata --offline --format-version 1 --all-features \
			>"${meta}/cargo.json") || { failed=1; return 0; }
		(cd "${src}" && "${sysenv[@]}" "${runenv[@]}" cargo-nextest nextest run --no-fail-fast \
			--binaries-metadata "${meta}/binaries.json" --cargo-metadata "${meta}/cargo.json" \
			"${run[@]}" "${extra[@]}") || failed=1
	}

	nextest_phase "nextest: ${#CRATES[@]} crates" "${pkgs[@]}" --

	if ((doc)); then
		step "doctests"
		(cd "${src}" && "${sysenv[@]}" cargo --config term.verbose=false test --offline --doc \
			--no-fail-fast "${pkgs[@]}") || failed=1
	fi

	if ((ignored)); then
		nextest_phase "upstream-ignored tests, e2e excluded" "${pkgs[@]}" -- \
			--run-ignored only -E "not (${E2E_FILTER})"
	fi

	if ((e2e)); then
		if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
			command -v secret-tool >/dev/null || die 2 "--e2e needs ANTHROPIC_API_KEY or secret-tool"
			ANTHROPIC_API_KEY="$(secret-tool lookup service anthropic purpose zeo-e2e 2>/dev/null)" ||
				die 2 "--e2e needs ANTHROPIC_API_KEY or the keyring entry (service anthropic purpose zeo-e2e)"
			export ANTHROPIC_API_KEY
		fi
		nextest_phase "e2e (real model)" -p agent -p agent_servers \
			--features "agent/e2e,agent_servers/e2e" -- -E "${E2E_FILTER}"
	fi

	if ((failed)); then
		printf '\n\033[1ma phase failed -- see above\033[0m\n'
		return 1
	fi
	printf '\n\033[1mevery phase passed\033[0m\n'
}

main "$@"
