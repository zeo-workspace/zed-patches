#!/usr/bin/env bash
# Self-test for the zed-patches tooling.
#
# Runs entirely against temporary fixtures: it never reads the real distfile,
# never touches the overlay, and never needs network access.
#
# Override the repository under test with ZP_REPO_ROOT (used while the scripts
# are still being written).

set -uo pipefail

SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ZP_REPO_ROOT:-$(cd "${SELFTEST_DIR}/.." && pwd)}"
SCRIPTS="${REPO_ROOT}/scripts"

PASS=0
FAIL=0
CURRENT=""

FIXTURE_COMMIT="1111111111111111111111111111111111111111"
FIXTURE_PV="zeo-0.9.9_p20260101"
FIXTURE_DISTFILE="zed-${FIXTURE_COMMIT}.tar.gz"

case_start() {
	CURRENT="$1"
}

ok() {
	PASS=$((PASS + 1))
	printf 'ok   %s\n' "${CURRENT}"
}

no() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n       %s\n' "${CURRENT}" "$1"
}

assert_status() {
	local expected="$1" actual="$2"
	[[ "${expected}" == "${actual}" ]] || {
		no "expected exit ${expected}, got ${actual}"
		return 1
	}
	return 0
}

assert_contains() {
	local haystack="$1" needle="$2"
	[[ "${haystack}" == *"${needle}"* ]] || {
		no "output did not mention: ${needle}"
		return 1
	}
	return 0
}

assert_equal() {
	local expected="$1" actual="$2"
	[[ "${expected}" == "${actual}" ]] || {
		no "expected [${expected}], got [${actual}]"
		return 1
	}
	return 0
}

assert_not_contains() {
	local haystack="$1" needle="$2"
	[[ "${haystack}" != *"${needle}"* ]] || {
		no "output must NOT mention: ${needle}"
		return 1
	}
	return 0
}

# tree_checksum <dir> — content digest of a tree, independent of where it lives.
# sha256sum prints the path next to each hash, so this must run from inside the
# directory: with absolute paths two identical trees in different temp dirs would
# never digest the same, and the immutability cases compare across temp dirs.
tree_checksum() {
	(
		cd "$1" || return 1
		find . -path '*/.git' -prune -o -type f -print0 |
			sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1
	)
}

# --- fixture builders -------------------------------------------------------

# make_ebuild <dir> <commit|-> — an ebuild carrying (or missing) EGIT_COMMIT.
make_ebuild() {
	local dir="$1" commit="$2"
	mkdir -p "${dir}/app-editors/zeo/files"
	{
		echo 'EAPI=8'
		[[ "${commit}" == "-" ]] || echo "EGIT_COMMIT=\"${commit}\""
		# shellcheck disable=SC2016  # ebuild syntax written verbatim; must not expand here
		echo 'SRC_URI="https://example.invalid/${EGIT_COMMIT}.tar.gz -> zed-${EGIT_COMMIT}.tar.gz"'
	} >"${dir}/app-editors/zeo/${FIXTURE_PV}.ebuild"
}

# make_distfile <distdir> <root-dir-name> — a tarball with a known root.
make_distfile() {
	local distdir="$1" root="$2" stage
	mkdir -p "${distdir}"
	stage="$(mktemp -d)"
	mkdir -p "${stage}/${root}/src"
	printf 'fn main() {\n    println!("one");\n}\n' >"${stage}/${root}/src/main.rs"
	printf 'fn helper() {\n    let x = 1;\n}\n' >"${stage}/${root}/src/lib.rs"
	tar -czf "${distdir}/${FIXTURE_DISTFILE}" -C "${stage}" "${root}"
	rm -rf "${stage}"
}

# make_patch <out.patch> <relative-file> <old-text> <new-text>
make_patch() {
	local out="$1" rel="$2" old="$3" new="$4" work
	work="$(mktemp -d)"
	mkdir -p "${work}/a/$(dirname "${rel}")" "${work}/b/$(dirname "${rel}")"
	printf '%s' "${old}" >"${work}/a/${rel}"
	printf '%s' "${new}" >"${work}/b/${rel}"
	(cd "${work}" && diff -Nur a b >"${out}")
	rm -rf "${work}"
}

# --- lib.sh: environment resolution (R2.3) ----------------------------------

test_lib_resolves_commit() {
	case_start "lib: resolves the packaged commit from the ebuild"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	out="$(ZP_OVERLAY="${tmp}/overlay" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_COMMIT}\"" 2>&1)"
	assert_equal "${FIXTURE_COMMIT}" "${out}" && ok
	rm -rf "${tmp}"
}

test_lib_rejects_ebuild_without_commit() {
	case_start "lib: dies with status 2 when the ebuild declares no commit"
	local tmp out status
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "-"
	out="$(ZP_OVERLAY="${tmp}/overlay" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" ".ebuild" && ok
	rm -rf "${tmp}"
}

test_lib_falls_back_to_default_distdir() {
	case_start "lib: falls back to the default distdir when portageq is unavailable"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	out="$(PATH="/nonexistent" ZP_OVERLAY="${tmp}/overlay" "${BASH}" -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_DISTFILE}\"" 2>&1)"
	assert_contains "${out}" "/var/cache/distfiles" && ok
	rm -rf "${tmp}"
}

test_lib_names_distfile_from_src_uri() {
	case_start "lib: the distfile is the name SRC_URI gives the archive, not the PF"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	out="$(ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/d" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_DISTFILE}\"" 2>&1)"
	assert_equal "${tmp}/d/${FIXTURE_DISTFILE}" "${out}" && ok
	rm -rf "${tmp}"
}

test_lib_distfile_expands_pf() {
	case_start "lib: a \${PF}.tar.gz rename (the old zed shape) expands to the PF"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	sed -i 's|-> zed-\${EGIT_COMMIT}.tar.gz|-> \${PF}.tar.gz|' "${tmp}/overlay/app-editors/zeo/${FIXTURE_PV}.ebuild"
	out="$(ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/d" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_DISTFILE}\"" 2>&1)"
	assert_equal "${tmp}/d/${FIXTURE_PV}.tar.gz" "${out}" && ok
	rm -rf "${tmp}"
}

test_lib_rejects_ebuild_without_archive_rename() {
	case_start "lib: dies with status 2 when SRC_URI renames no archive"
	local tmp out status
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	sed -i '/^SRC_URI=/d' "${tmp}/overlay/app-editors/zeo/${FIXTURE_PV}.ebuild"
	out="$(ZP_OVERLAY="${tmp}/overlay" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "SRC_URI" && ok
	rm -rf "${tmp}"
}

test_lib_reads_overlay_from_config() {
	case_start "lib: .zp-overlay names the overlay when ZP_OVERLAY is unset"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	printf '# the working overlay\n\n  %s/overlay  \n' "${tmp}" >"${tmp}/.zp-overlay"
	out="$(ZP_REPO="${tmp}" "${BASH}" -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_OVERLAY}\"" 2>&1)"
	assert_equal "${tmp}/overlay" "${out}" && ok
	rm -rf "${tmp}"
}

test_lib_env_overrides_config() {
	case_start "lib: ZP_OVERLAY in the environment wins over .zp-overlay"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/chosen" "${FIXTURE_COMMIT}"
	printf '%s/ignored\n' "${tmp}" >"${tmp}/.zp-overlay"
	out="$(ZP_REPO="${tmp}" ZP_OVERLAY="${tmp}/chosen" "${BASH}" -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_OVERLAY}\"" 2>&1)"
	assert_equal "${tmp}/chosen" "${out}" && ok
	rm -rf "${tmp}"
}

test_lib_rejects_config_naming_missing_dir() {
	case_start "lib: .zp-overlay naming a missing directory dies with status 2"
	local tmp out status
	tmp="$(mktemp -d)"
	printf '%s/nowhere\n' "${tmp}" >"${tmp}/.zp-overlay"
	out="$(ZP_REPO="${tmp}" "${BASH}" -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "not a directory" && ok
	rm -rf "${tmp}"
}

test_lib_rejects_empty_config() {
	case_start "lib: a comment-only .zp-overlay dies with status 2"
	local tmp out status
	tmp="$(mktemp -d)"
	printf '# nothing here\n\n' >"${tmp}/.zp-overlay"
	out="$(ZP_REPO="${tmp}" "${BASH}" -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "names no overlay path" && ok
	rm -rf "${tmp}"
}

# --- lib.sh: series parsing (R3.1, R3.2, R3.3) ------------------------------

series_fixture() {
	local dir="$1"
	mkdir -p "${dir}"
	: >"${dir}/0001-first.patch"
	: >"${dir}/0002-second.patch"
	: >"${dir}/0005-third.patch"
	cat >"${dir}/series" <<-EOS
		# a plain comment

		# @feature: group-a
		0001-first.patch
		# 0003/0004 retired upstream
		0005-third.patch

		# @feature: group-b
		0002-second.patch
	EOS
}

test_series_preserves_order() {
	case_start "series: preserves order and ignores blanks and plain comments"
	local tmp out
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series'" 2>&1 | tr '\n' ' ')"
	assert_equal "0001-first.patch 0005-third.patch 0002-second.patch " "${out}" && ok
	rm -rf "${tmp}"
}

test_series_group_carries_forward() {
	case_start "series: a feature group carries forward until redeclared"
	local tmp out
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series' group-a" 2>&1 | tr '\n' ' ')"
	assert_equal "0001-first.patch 0005-third.patch " "${out}" && ok
	rm -rf "${tmp}"
}

test_series_filter_returns_only_its_group() {
	case_start "series: filtering returns only the requested group"
	local tmp out
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series' group-b" 2>&1 | tr '\n' ' ')"
	assert_equal "0002-second.patch " "${out}" && ok
	rm -rf "${tmp}"
}

test_series_lists_every_missing_entry() {
	case_start "series: lists every missing entry at once with status 2"
	local tmp out status
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	rm "${tmp}/0001-first.patch" "${tmp}/0002-second.patch"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "0001-first.patch" &&
		assert_contains "${out}" "0002-second.patch" && ok
	rm -rf "${tmp}"
}

# --- prepare-tree.sh (R2.1, R2.2, R2.4, R2.5, R2.6) -------------------------

prepare_env() {
	local tmp="$1" root="${2:-zed-${FIXTURE_COMMIT}}"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	make_distfile "${tmp}/distfiles" "${root}"
	mkdir -p "${tmp}/repo/scripts"
}

run_prepare() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		bash "${SCRIPTS}/prepare-tree.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_prepare_refuses_missing_distfile() {
	case_start "prepare: missing distfile exits 2, names the path, creates no tree"
	local tmp out status
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	rm "${tmp}/distfiles/${FIXTURE_DISTFILE}"
	out="$(run_prepare "${tmp}")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "${tmp}/distfiles" &&
		{ [[ ! -d "${tmp}/work" ]] || {
			no "a work tree was created anyway"
			false
		}; } && ok
	rm -rf "${tmp}"
}

test_prepare_refuses_mismatched_root() {
	case_start "prepare: archive root mismatching the commit exits 2 and extracts nothing"
	local tmp out status
	tmp="$(mktemp -d)"
	prepare_env "${tmp}" "zed-deadbeef"
	out="$(run_prepare "${tmp}")"
	status=$?
	assert_status 2 "${status}" &&
		{ [[ ! -d "${tmp}/work/zed-deadbeef" ]] || {
			no "the mismatched archive was extracted"
			false
		}; } && ok
	rm -rf "${tmp}"
}

test_prepare_is_idempotent() {
	case_start "prepare: a second run reuses the tree; --force re-extracts"
	local tmp before after forced
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	printf 'marker\n' >"${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt"
	before="$(cat "${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt" 2>/dev/null)"
	run_prepare "${tmp}" >/dev/null
	after="$(cat "${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt" 2>/dev/null)"
	run_prepare "${tmp}" --force >/dev/null
	forced="$(cat "${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt" 2>/dev/null)"
	assert_equal "marker" "${before}" &&
		assert_equal "${before}" "${after}" &&
		assert_equal "" "${forced}" && ok
	rm -rf "${tmp}"
}

test_prepare_leaves_pristine_baseline() {
	case_start "prepare: the tree carries one baseline commit and a clean status"
	local tmp tree commits status_out
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	commits="$(git -C "${tree}" rev-list --count HEAD 2>&1)"
	status_out="$(git -C "${tree}" status --porcelain 2>&1)"
	assert_equal "1" "${commits}" &&
		assert_equal "" "${status_out}" && ok
	rm -rf "${tmp}"
}

test_prepare_regenerates_a_patch() {
	case_start "prepare: an edit to the tree can be regenerated as a reappliable patch"
	local tmp tree patch status
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	printf 'fn main() {\n    println!("two");\n}\n' >"${tree}/src/main.rs"
	patch="${tmp}/edit.patch"
	git -C "${tree}" diff >"${patch}" 2>&1
	git -C "${tree}" checkout -- . 2>/dev/null
	(cd "${tree}" && patch -p1 -f -g0 --dry-run <"${patch}" >/dev/null 2>&1)
	status=$?
	assert_status 0 "${status}" && ok
	rm -rf "${tmp}"
}

# --- verify.sh (R4.1 - R4.6) ------------------------------------------------

verify_env() {
	local tmp="$1" broken="${2:-no}"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	mkdir -p "${tmp}/repo/patches/${FIXTURE_PV}"
	local pdir="${tmp}/repo/patches/${FIXTURE_PV}"
	make_patch "${pdir}/0001-first.patch" "src/main.rs" \
		'fn main() {
    println!("one");
}
' 'fn main() {
    println!("two");
}
'
	if [[ "${broken}" == "broken" ]]; then
		make_patch "${pdir}/0002-second.patch" "src/lib.rs" \
			'fn helper() {
    let x = 99;
}
' 'fn helper() {
    let x = 100;
}
'
	else
		make_patch "${pdir}/0002-second.patch" "src/lib.rs" \
			'fn helper() {
    let x = 1;
}
' 'fn helper() {
    let x = 2;
}
'
	fi
	cat >"${pdir}/series" <<-EOS
		# @feature: group-a
		0001-first.patch
		# @feature: group-b
		0002-second.patch
	EOS
}

run_verify() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/verify.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_verify_passes_whole_series() {
	case_start "verify: a fully applying series exits 0 and reports the count"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	out="$(run_verify "${tmp}")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "2" && ok
	rm -rf "${tmp}"
}

test_verify_reports_failing_patch() {
	case_start "verify: a broken patch exits 1 naming patch, position and file"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_verify "${tmp}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0002-second.patch" &&
		assert_contains "${out}" "src/lib.rs" && ok
	rm -rf "${tmp}"
}

test_verify_requires_prepared_tree() {
	case_start "verify: a missing prepared tree exits 2"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	rm -rf "${tmp}/work"
	out="$(run_verify "${tmp}")"
	status=$?
	assert_status 2 "${status}" && ok
	rm -rf "${tmp}"
}

test_verify_leaves_tree_untouched() {
	case_start "verify: the tree is byte-identical after passing and failing runs"
	local tmp tree before after_pass after_fail pass_status fail_status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	before="$(tree_checksum "${tree}")"
	run_verify "${tmp}" >/dev/null
	pass_status=$?
	after_pass="$(tree_checksum "${tree}")"
	rm -rf "${tmp}"

	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	run_verify "${tmp}" >/dev/null
	fail_status=$?
	after_fail="$(tree_checksum "${tree}")"
	assert_status 0 "${pass_status}" &&
		assert_status 1 "${fail_status}" &&
		assert_equal "${before}" "${after_pass}" &&
		assert_equal "${before}" "${after_fail}" && ok
	rm -rf "${tmp}"
}

test_verify_restores_baseline_tree() {
	case_start "verify: a tree left carrying refresh commits is put back on the baseline"
	local tmp tree out status head baseline
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	# Reproduce what refresh.sh leaves behind: the series applied to the tree,
	# one commit per patch. Verifying against that would read its own output.
	(cd "${tree}" && patch -p1 -f -g0 <"${tmp}/repo/patches/${FIXTURE_PV}/0001-first.patch" >/dev/null 2>&1)
	git -C "${tree}" commit -aqm "refresh: 0001-first.patch"
	out="$(run_verify "${tmp}")"
	status=$?
	head="$(git -C "${tree}" rev-parse HEAD)"
	baseline="$(git -C "${tree}" rev-list --max-parents=0 HEAD)"
	assert_status 0 "${status}" &&
		assert_contains "${out}" "restored the baseline" &&
		assert_equal "${baseline}" "${head}" && ok
	rm -rf "${tmp}"
}

test_verify_refuses_modified_tree() {
	case_start "verify: uncommitted source edits exit 2 and are left in place"
	local tmp tree out status content
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	printf 'fn main() {\n    println!("mid-edit");\n}\n' >"${tree}/src/main.rs"
	out="$(run_verify "${tmp}")"
	status=$?
	content="$(cat "${tree}/src/main.rs")"
	assert_status 2 "${status}" &&
		assert_contains "${out}" "uncommitted changes" &&
		assert_contains "${content}" "mid-edit" && ok
	rm -rf "${tmp}"
}

test_verify_feature_filter() {
	case_start "verify: --feature verifies only its group; unknown group exits 2"
	local tmp out status unknown_status
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_verify "${tmp}" "--feature=group-a")"
	status=$?
	run_verify "${tmp}" "--feature=nope" >/dev/null
	unknown_status=$?
	assert_status 0 "${status}" &&
		assert_status 2 "${unknown_status}" &&
		assert_contains "${out}" "0001-first.patch" && ok
	rm -rf "${tmp}"
}

# stacked_verify_env <tmp> — a series whose second patch only applies once the
# first has been applied: both touch src/main.rs, and 0002 expects the text 0001
# produces. Checking each patch against the pristine source rejects 0002; the
# ebuild, which applies them in order, does not. That gap is what this fixture
# pins, and the real series has the same shape in 0007/0010.
stacked_verify_env() {
	local tmp="$1"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	local pdir="${tmp}/repo/patches/${FIXTURE_PV}"
	mkdir -p "${pdir}"
	make_patch "${pdir}/0001-first.patch" "src/main.rs" \
		'fn main() {
    println!("one");
}
' 'fn main() {
    println!("two");
}
'
	make_patch "${pdir}/0002-stacked.patch" "src/main.rs" \
		'fn main() {
    println!("two");
}
' 'fn main() {
    println!("three");
}
'
	cat >"${pdir}/series" <<-EOS
		0001-first.patch
		0002-stacked.patch
	EOS
}

test_verify_applies_series_cumulatively() {
	case_start "verify: a stacked patch is read with its predecessor applied"
	local tmp out status tree before after leftovers
	tmp="$(mktemp -d)"
	stacked_verify_env "${tmp}"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	before="$(tree_checksum "${tree}")"
	out="$(run_verify "${tmp}")"
	status=$?
	after="$(tree_checksum "${tree}")"
	# The scratch worktree lives under the work root and must not outlive the run.
	leftovers="$(find "${tmp}/work" -maxdepth 1 -name '.verify-*' 2>/dev/null | wc -l)"
	assert_status 0 "${status}" &&
		assert_contains "${out}" "0002-stacked.patch" &&
		assert_equal "${before}" "${after}" &&
		assert_equal "0" "${leftovers}" && ok
	rm -rf "${tmp}"
}

# --- sync-overlay.sh (R6.1 - R6.5) ------------------------------------------

# add_ebuild_patches <overlay> <name>... — give the fixture ebuild a
# src_prepare that applies the named patches, so check-sync.sh has an ebuild
# side to compare the series against.
add_ebuild_patches() {
	local overlay="$1"
	shift
	local ebuild="${overlay}/app-editors/zeo/${FIXTURE_PV}.ebuild" name
	{
		echo 'src_prepare() {'
		echo '	PATCHES+=('
		# shellcheck disable=SC2016  # ebuild syntax written verbatim; must not expand here
		for name in "$@"; do printf '\t\t"${FILESDIR}/%s"\n' "${name}"; done
		echo '	)'
		echo '	default'
		echo '}'
	} >>"${ebuild}"
}

run_branches() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/patch-branches.sh" "${FIXTURE_PV}" "$@" 2>&1
}

# run_checksync — with a changelog that has the fixture version's section, so
# only the relation a case is about decides its verdict.
run_checksync() {
	local tmp="$1"
	shift
	[[ -f "${tmp}/CHANGELOG.fixture.md" ]] ||
		printf '# Changelog\n\n## [0.9.9] — 2026-01-01\n\n- NINE.\n' >"${tmp}/CHANGELOG.fixture.md"
	ZP_CHANGELOG="${tmp}/CHANGELOG.fixture.md" \
		ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/check-sync.sh" "${FIXTURE_PV}" "$@" 2>&1
}

run_sync() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/sync-overlay.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_sync_refuses_unverified() {
	case_start "sync: failing verification copies nothing and exits non-zero"
	local tmp out status count
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_sync "${tmp}")"
	status=$?
	count="$(find "${tmp}/overlay/app-editors/zeo/files" -name '*.patch' | wc -l)"
	[[ "${status}" -ne 0 ]] || {
		no "expected a non-zero exit"
		rm -rf "${tmp}"
		return
	}
	assert_equal "0" "${count}" &&
		assert_contains "${out}" "${FIXTURE_PV}" && ok
	rm -rf "${tmp}"
}

test_sync_copies_verified_series() {
	case_start "sync: a verified series is copied in full and the ebuild is untouched"
	local tmp status count before after
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	before="$(sha256sum "${tmp}/overlay/app-editors/zeo/${FIXTURE_PV}.ebuild" | cut -d' ' -f1)"
	run_sync "${tmp}" >/dev/null
	status=$?
	after="$(sha256sum "${tmp}/overlay/app-editors/zeo/${FIXTURE_PV}.ebuild" | cut -d' ' -f1)"
	count="$(find "${tmp}/overlay/app-editors/zeo/files" -name '*.patch' | wc -l)"
	assert_status 0 "${status}" &&
		assert_equal "2" "${count}" &&
		assert_equal "${before}" "${after}" && ok
	rm -rf "${tmp}"
}

test_sync_dry_run_writes_nothing() {
	case_start "sync: --dry-run reports the same set and writes nothing"
	local tmp out count
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	out="$(run_sync "${tmp}" "--dry-run")"
	count="$(find "${tmp}/overlay/app-editors/zeo/files" -name '*.patch' | wc -l)"
	assert_equal "0" "${count}" &&
		assert_contains "${out}" "0001-first.patch" && ok
	rm -rf "${tmp}"
}

test_sync_reports_orphans() {
	case_start "sync: an overlay-only patch is reported as an orphan and kept"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	: >"${tmp}/overlay/app-editors/zeo/files/0099-orphan.patch"
	out="$(run_sync "${tmp}")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "0099-orphan.patch" &&
		{ [[ -f "${tmp}/overlay/app-editors/zeo/files/0099-orphan.patch" ]] || {
			no "the orphan was deleted"
			false
		}; } && ok
	rm -rf "${tmp}"
}

test_sync_reports_zero_orphans_when_aligned() {
	case_start "sync: an overlay matching the series reports zero orphans"
	local tmp out
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	run_sync "${tmp}" >/dev/null
	out="$(run_sync "${tmp}")"
	assert_contains "${out}" "0 orphan" && ok
	rm -rf "${tmp}"
}

# --- patch-branches.sh: one branch per patch --------------------------------

test_branches_one_per_patch() {
	case_start "branches: one branch per patch, each a single commit on the baseline"
	local tmp status count parents
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	run_branches "${tmp}" >/dev/null
	status=$?
	count="$(git -C "${tmp}/work/zed-${FIXTURE_COMMIT}" branch --list 'patch/*' | wc -l)"
	parents="$(git -C "${tmp}/work/zed-${FIXTURE_COMMIT}" rev-list --count 'patch/0001-first')"
	assert_status 0 "${status}" &&
		assert_equal "2" "${count}" &&
		assert_equal "2" "${parents}" && ok
	rm -rf "${tmp}"
}

test_branches_leave_tree_on_baseline() {
	case_start "branches: the prepared tree is left clean on the baseline"
	local tmp dirty head baseline
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	run_branches "${tmp}" >/dev/null
	dirty="$(git -C "${tmp}/work/zed-${FIXTURE_COMMIT}" status --porcelain | wc -l)"
	head="$(git -C "${tmp}/work/zed-${FIXTURE_COMMIT}" rev-parse HEAD)"
	baseline="$(git -C "${tmp}/work/zed-${FIXTURE_COMMIT}" rev-list --max-parents=0 HEAD)"
	assert_equal "0" "${dirty}" &&
		assert_equal "${baseline}" "${head}" && ok
	rm -rf "${tmp}"
}

# --- check-sync.sh: the three relations -------------------------------------

test_checksync_reports_in_sync() {
	case_start "check-sync: all three relations agree after a sync"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	add_ebuild_patches "${tmp}/overlay" "0001-first.patch" "0002-second.patch"
	run_sync "${tmp}" >/dev/null
	out="$(run_checksync "${tmp}")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "in sync" && ok
	rm -rf "${tmp}"
}

test_checksync_detects_overlay_drift() {
	case_start "check-sync: a patch edited in the overlay only is reported as drift"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	add_ebuild_patches "${tmp}/overlay" "0001-first.patch" "0002-second.patch"
	run_sync "${tmp}" >/dev/null
	printf '\n# edited in the overlay only\n' >>"${tmp}/overlay/app-editors/zeo/files/0001-first.patch"
	out="$(run_checksync "${tmp}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "differs" && ok
	rm -rf "${tmp}"
}

test_checksync_detects_ebuild_drift() {
	case_start "check-sync: a patch the ebuild applies but the series omits is reported"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	add_ebuild_patches "${tmp}/overlay" "0001-first.patch" "0002-second.patch" "0003-ghost.patch"
	run_sync "${tmp}" >/dev/null
	out="$(run_checksync "${tmp}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0003-ghost.patch" && ok
	rm -rf "${tmp}"
}

# --- refresh.sh (R7.1 - R7.3) -----------------------------------------------

run_refresh() {
	local tmp="$1" to="$2"
	shift 2
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/refresh.sh" --from "${FIXTURE_PV}" --to "${to}" "$@" 2>&1
}

test_refresh_preserves_source_set() {
	case_start "refresh: the source version's patch set is left byte-identical"
	local tmp before after
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	before="$(tree_checksum "${tmp}/repo/patches/${FIXTURE_PV}")"
	run_refresh "${tmp}" "zed-9.9.9_pre20260202" >/dev/null
	after="$(tree_checksum "${tmp}/repo/patches/${FIXTURE_PV}")"
	{ [[ -f "${tmp}/repo/patches/zed-9.9.9_pre20260202/series" ]] || {
		no "the refreshed patch set was not produced"
		false
	}; } &&
		assert_equal "${before}" "${after}" && ok
	rm -rf "${tmp}"
}

test_refresh_refuses_existing_destination() {
	case_start "refresh: an existing destination directory is refused"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	mkdir -p "${tmp}/repo/patches/zed-9.9.9_pre20260202"
	out="$(run_refresh "${tmp}" "zed-9.9.9_pre20260202")"
	status=$?
	{ [[ "${status}" -ne 0 ]] || {
		no "expected a non-zero exit"
		false
	}; } &&
		assert_contains "${out}" "zed-9.9.9_pre20260202" && ok
	rm -rf "${tmp}"
}

test_refresh_stops_on_conflict() {
	case_start "refresh: a conflict exits non-zero, keeps the reject and names the remainder"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_refresh "${tmp}" "zed-9.9.9_pre20260202")"
	status=$?
	[[ "${status}" -ne 0 ]] || {
		no "expected a non-zero exit"
		rm -rf "${tmp}"
		return
	}
	assert_contains "${out}" "0002-second.patch" && ok
	rm -rf "${tmp}"
}

# --- lib.sh: the advisory step (task 2.3 — R2.4…R2.8) -----------------------
#
# Authored test-first, from the requirements alone. The helper under test does not
# exist yet; these cases describe what it must answer, never how.
#
#   report_advisories [--offline]
#     scans the chain's lockfiles — the four npm ones plus the packaged Zed's
#     Cargo.lock at ${ZP_WORKTREE} — and PRINTS one of four verdicts per file:
#     clean · findings · scan failed · skipped. It ALWAYS returns 0: R2.8 forbids
#     it changing any caller's exit code, and every caller runs under
#     `set -euo pipefail`, where a non-zero return would abort the whole run.
#     The chain root is ZP_CHAIN_ROOT (the ZP_* override convention lib.sh
#     already follows for ZP_REPO / ZP_OVERLAY / ZP_DISTDIR / ZP_WORKROOT).
#
# The scanner is stubbed ON PATH, never behind a flag: status.sh parses its
# arguments positionally and exits 2 on anything it does not recognise.
#
# `clean` is asserted in its own case on purpose. R2.6 asks for `scan failed` to be
# DISTINCT from clean, and a distinction cannot be proved from one side: without the
# clean fixture, a helper that prints "scan failed" for every run would pass.

# make_chain <dir> — the five lockfiles the advisory step reads (D2), each with
# enough content to be a plausible input. The Cargo.lock sits where the packaged
# tree does, under a work/ that CLAUDE.md calls disposable by design.
make_chain() {
	local root="$1"
	mkdir -p "${root}/claude-agent-fork/fork" \
		"${root}/claude-agent-fork/claude-agent-acp-plus" \
		"${root}/claude-agent-tui/fork" \
		"${root}/claude-agent-tui/claude-agent-tui" \
		"${root}/zed-patches/work/zed-${FIXTURE_COMMIT}"
	printf '{"lockfileVersion":3,"packages":{}}\n' >"${root}/claude-agent-fork/fork/package-lock.json"
	printf '{"lockfileVersion":3,"packages":{}}\n' >"${root}/claude-agent-fork/claude-agent-acp-plus/package-lock.json"
	printf '{"lockfileVersion":3,"packages":{}}\n' >"${root}/claude-agent-tui/fork/package-lock.json"
	printf '{"lockfileVersion":3,"packages":{}}\n' >"${root}/claude-agent-tui/claude-agent-tui/package-lock.json"
	printf 'version = 4\n' >"${root}/zed-patches/work/zed-${FIXTURE_COMMIT}/Cargo.lock"
}

# make_scanner <bindir> <exit-status> <stdout…> — an osv-scanner stub, first on
# PATH. It ignores its arguments: what the helper passes is its business, what it
# does with the answer is what these cases are about. Every call is recorded, so
# a case can assert the scanner was NOT run.
make_scanner() {
	local bindir="$1" status="$2" out="$3"
	mkdir -p "${bindir}"
	{
		echo '#!/usr/bin/env bash'
		# shellcheck disable=SC2016,SC2028  # the stub's body, written verbatim; it must not expand here
		echo 'printf "%s\n" "$*" >>"${SCANNER_CALLS:-/dev/null}"'
		printf 'printf %s\\\\n %q\n' '%s' "${out}"
		echo "exit ${status}"
	} >"${bindir}/osv-scanner"
	chmod +x "${bindir}/osv-scanner"
}

# run_advisories <chain> <bindir|-> [args…] — call the helper the way both callers
# will: from a `set -euo pipefail` shell, printing its own return status after it.
# `-` for <bindir> means a PATH with no osv-scanner on it at all.
run_advisories() {
	local chain="$1" bindir="$2"
	shift 2
	local path
	if [[ "${bindir}" == "-" ]]; then
		mkdir -p "${chain}/.empty-bin"
		path="${chain}/.empty-bin"
	else
		path="${bindir}:${PATH}"
	fi
	PATH="${path}" \
		SCANNER_CALLS="${chain}/.scanner-calls" \
		ZP_CHAIN_ROOT="${chain}" \
		ZP_WORKTREE="${chain}/zed-patches/work/zed-${FIXTURE_COMMIT}" \
		"${BASH}" -c "set -euo pipefail; source '${SCRIPTS}/lib.sh'; report_advisories $*; printf 'rc=%s\n' \$?" 2>&1
}

test_advisory_skips_when_scanner_absent() {
	case_start "advisory: no osv-scanner on PATH is reported as skipped, not as a failure"
	local tmp out status
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	out="$(run_advisories "${tmp}/chain" "-")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "skipped" &&
		assert_not_contains "${out}" "scan failed" &&
		assert_contains "${out}" "rc=0" && ok
	rm -rf "${tmp}"
}

test_advisory_skips_when_offline() {
	case_start "advisory: --offline skips without running the scanner (R2.5)"
	local tmp out status
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	make_scanner "${tmp}/bin" 0 "no vulnerabilities found"
	out="$(run_advisories "${tmp}/chain" "${tmp}/bin" --offline)"
	status=$?
	# Local-first: --offline must not merely discard the answer, it must not ask.
	{ [[ ! -s "${tmp}/chain/.scanner-calls" ]] || {
		no "the scanner was invoked despite --offline"
		false
	}; } &&
		assert_status 0 "${status}" &&
		assert_contains "${out}" "skipped" &&
		assert_contains "${out}" "rc=0" && ok
	rm -rf "${tmp}"
}

test_advisory_reports_clean() {
	case_start "advisory: a scanner that finds nothing is reported clean"
	local tmp out status
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	make_scanner "${tmp}/bin" 0 "no vulnerabilities found"
	out="$(run_advisories "${tmp}/chain" "${tmp}/bin")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "clean" &&
		assert_not_contains "${out}" "scan failed" &&
		assert_contains "${out}" "rc=0" && ok
	rm -rf "${tmp}"
}

test_advisory_reports_findings_without_touching_the_exit_code() {
	case_start "advisory: findings are shown and the caller's status is untouched (R2.4, R2.8)"
	local tmp out status
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	# osv-scanner exits non-zero for findings — the same way it exits non-zero
	# when it breaks, which is why a blanket `|| true` cannot tell them apart.
	make_scanner "${tmp}/bin" 1 "GHSA-1234-5678-9abc: prototype pollution in left-pad"
	out="$(run_advisories "${tmp}/chain" "${tmp}/bin")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "findings" &&
		assert_contains "${out}" "GHSA-1234-5678-9abc" &&
		assert_contains "${out}" "rc=0" && ok
	rm -rf "${tmp}"
}

test_advisory_reports_scan_failure_distinctly_from_clean() {
	case_start "advisory: a non-zero exit with no report is 'scan failed', not 'clean' (R2.6)"
	local tmp out status
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	# The case that matters most: the scanner broke. It exits non-zero and says
	# nothing — indistinguishable from a clean run to anything that only reads
	# the status, and indistinguishable from findings to anything that only reads
	# the non-zero.
	make_scanner "${tmp}/bin" 127 ""
	out="$(run_advisories "${tmp}/chain" "${tmp}/bin")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "scan failed" &&
		assert_not_contains "${out}" "clean" &&
		assert_contains "${out}" "rc=0" && ok
	rm -rf "${tmp}"
}

test_advisory_skips_only_the_missing_lockfile() {
	case_start "advisory: a lockfile that is not there is skipped for that file alone (R2.7)"
	local tmp out status
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	# work/ is disposable by design, so the packaged Cargo.lock is routinely
	# absent. That is a skip for one file, never a failed step.
	rm -f "${tmp}/chain/zed-patches/work/zed-${FIXTURE_COMMIT}/Cargo.lock"
	make_scanner "${tmp}/bin" 0 "no vulnerabilities found"
	out="$(run_advisories "${tmp}/chain" "${tmp}/bin")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "Cargo.lock" &&
		assert_contains "${out}" "skipped" &&
		assert_not_contains "${out}" "scan failed" &&
		assert_contains "${out}" "claude-agent-acp-plus" &&
		assert_contains "${out}" "rc=0" && ok
	rm -rf "${tmp}"
}

# --- status.sh / bump.sh: the advisory step in the caller's own body (task 2.4)
#
# Task 2.3's six cases call report_advisories directly, so they say nothing about
# WHERE it is called from: a helper that is perfectly correct but wired into one
# of the delegated `bash "${SCRIPTS}/…"` sub-shells passes all six of them. This
# case is the one that cannot be satisfied that way. It runs the REAL
# scripts/status.sh end to end and asserts the advisory verdict reaches THAT
# script's own output, ahead of its first gated step (R2.9) — and status.sh
# captures every delegated run into a variable, printing only the lines it
# chooses to and only after the 'packaged zeo' header, so output produced inside
# a sub-shell can never land ahead of it.
#
# bump.sh cannot be run end to end here: its first step regenerates a patch
# series against a prepared tree, which is a Rust checkout this harness has no
# business building. Its half of R2.9 is therefore read from the script itself —
# a top-level `report_advisories` call standing before `step '1/4 …'`.
#
# Nothing real is touched: a fixture overlay holding one ebuild (never the
# machine's), a temporary DISTDIR and WORKROOT, and two stubs first on PATH.
# Stubs on PATH rather than a flag because status.sh parses its arguments
# positionally and exits 2 on anything it does not recognise; npm is stubbed for
# the same reason the rest of this file never reaches the network — the registry
# lookups status.sh performs online are answered locally instead.
#
# The fixture overlay is also what makes the exit code deterministic rather than
# a property of this machine: check-sync.sh finds no series for the fixture
# version, so status.sh reports drift and exits 1 whether or not the advisory
# step is there. R2.8 is that it STAYS 1 — measured from the run itself, never
# through a pipe, which would report the pipeline's status instead.

# make_npm <bindir> <version> — an npm stub answering `npm view <pkg> version`,
# so the online path of status.sh needs no registry.
make_npm() {
	local bindir="$1" version="$2"
	mkdir -p "${bindir}"
	{
		echo '#!/usr/bin/env bash'
		printf 'printf %s\\\\n %q\n' '%s' "${version}"
	} >"${bindir}/npm"
	chmod +x "${bindir}/npm"
}

test_status_calls_the_advisory_step_in_its_own_body() {
	case_start "callers: status.sh reports advisories from its own body ahead of step 1, its exit code unchanged (R2.8, R2.9, R2.10)"
	local tmp out status chain_root status_sh bump_sh header before adv_line step_line
	chain_root="$(cd "${REPO_ROOT}/.." && pwd)"
	status_sh="${chain_root}/scripts/status.sh"
	bump_sh="${SCRIPTS}/bump.sh"
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	make_scanner "${tmp}/bin" 1 "GHSA-1234-5678-9abc: prototype pollution in left-pad"
	make_npm "${tmp}/bin" "0.0.0-stub"

	out="$(PATH="${tmp}/bin:${PATH}" \
		SCANNER_CALLS="${tmp}/chain/.scanner-calls" \
		ZP_CHAIN_ROOT="${tmp}/chain" \
		ZP_OVERLAY="${tmp}/overlay" \
		ZP_DISTDIR="${tmp}/dist" \
		ZP_WORKROOT="${tmp}/work" \
		bash "${status_sh}" 2>&1)"
	status=$?

	header='packaged zeo'
	before="${out%%"${header}"*}"
	adv_line="$(grep -n '^[[:space:]]*report_advisories' "${bump_sh}" | head -1 | cut -d: -f1)"
	step_line="$(grep -n "1/4" "${bump_sh}" | head -1 | cut -d: -f1)"

	assert_status 1 "${status}" &&
		assert_contains "${out}" "${header}" &&
		assert_contains "${out}" "findings" &&
		assert_contains "${out}" "GHSA-1234-5678-9abc" &&
		{ [[ -s "${tmp}/chain/.scanner-calls" ]] || {
			no "status.sh never invoked the scanner — the advisory step did not run"
			false
		}; } &&
		{ [[ "${before}" == *"GHSA-1234-5678-9abc"* ]] || {
			no "the advisory output did not reach status.sh's own body ahead of '${header}' — output from inside a delegated sub-shell looks exactly like this"
			false
		}; } &&
		{ [[ -n "${adv_line}" && -n "${step_line}" && "${adv_line}" -lt "${step_line}" ]] || {
			no "bump.sh has no top-level report_advisories call standing before step 1/4 (found at line [${adv_line:-none}], step 1/4 at [${step_line:-none}])"
			false
		}; } &&
		{ [[ "$(sed -n '1,/^set -euo pipefail/p' "${status_sh}")" == *advisor* &&
			"$(sed -n '1,/^set -euo pipefail/p' "${bump_sh}")" == *advisor* ]] || {
			no "the header comment of status.sh and bump.sh must describe the advisory step and what it does to the exit code (R2.10)"
			false
		}; } && ok
	rm -rf "${tmp}"
}

# --- status.sh: the installed column (task 1.2) ------------------------------
#
# The adapters table compared two declarations -- the repo's package.json and the
# overlay's ebuild -- plus what npm had published, and said `ok` when they agreed.
# None of the three says what Portage has actually MERGED, so the table could
# report agreement across the board while the adapter this machine runs was a
# release behind. Measured 2026-09-22: repo and ebuild at 0.19.0 and 0.13.3,
# /var/db/pkg at 0.18.0 and 0.13.2, every row `ok`.
#
# The fixture controls the overlay (ZP_OVERLAY) and the merged set (ZP_VDB), and
# DERIVES its expected versions from the real package.json files: ROOT is where
# status.sh lives, so the `repo` column cannot be faked from here. Deriving rather
# than hardcoding is the same reason the protocol cases cut PATH -- the adapters
# release on their own cadence, and a literal would turn these cases red at the
# next release for a reason unrelated to this column.
#
# The exit code is deliberately NOT asserted: check-sync.sh finds no series for
# the fixture version, so status.sh exits 1 in all three cases whatever this
# column decides. The row's own mark is the assertion, and `DRIFT` there is
# written by the same branch that calls note_drift -- one printf earlier.

# adapter_repo_version <relative-repo> — the version status.sh will read for the
# `repo` column of that adapter.
adapter_repo_version() {
	python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
		"${REPO_ROOT}/../$1/package.json"
}

# make_adapter_ebuild <overlay> <pkg> <version> — one dev-util ebuild, the shape
# ebuild_version() parses.
make_adapter_ebuild() {
	mkdir -p "$1/dev-util/$2"
	printf 'EAPI=8\n' >"$1/dev-util/$2/$2-$3.ebuild"
}

# make_vdb_entry <vdb> <pkg> <version> — one merged package, the shape the vdb
# has: a directory named <PN>-<PVR> under the category.
make_vdb_entry() {
	mkdir -p "$1/dev-util/$2-$3"
	printf '%s\n' "dev-util/$2-$3" >"$1/dev-util/$2-$3/PF"
}

# run_status <overlay> <vdb> <chain> — the real scripts/status.sh, --offline.
#
# CLAUDE_CONFIG_DIR points at an empty directory so the protocol contract skips
# its live clause instead of probing this machine's real lock files: that clause
# has nothing to do with the adapters table and would add a socket per lock.
run_status() {
	local overlay="$1" vdb="$2" chain="$3"
	mkdir -p "${chain}/empty-ide/ide"
	PATH="/usr/bin:/bin" \
		CLAUDE_CONFIG_DIR="${chain}/empty-ide" \
		ZP_CHAIN_ROOT="${chain}" \
		ZP_OVERLAY="${overlay}" \
		ZP_VDB="${vdb}" \
		ZP_DISTDIR="${chain}/dist" \
		ZP_WORKROOT="${chain}/work" \
		bash "${REPO_ROOT}/../scripts/status.sh" --offline 2>&1
}

# adapter_row <output> <package-name> — the one table line naming that package.
adapter_row() {
	printf '%s\n' "$1" | grep -F -- "$2" | head -n1
}

test_status_installed_agreeing_is_ok() {
	case_start "status: an installed version agreeing with the ebuild leaves the adapter row ok"
	local tmp out plus tui v_plus v_tui
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	v_plus="$(adapter_repo_version claude-agent-plus/claude-agent-acp-plus)"
	v_tui="$(adapter_repo_version claude-agent-tui/claude-agent-tui)"
	make_adapter_ebuild "${tmp}/overlay" claude-agent-acp-plus "${v_plus}"
	make_adapter_ebuild "${tmp}/overlay" claude-agent-acp-tui "${v_tui}"
	make_vdb_entry "${tmp}/vdb" claude-agent-acp-plus "${v_plus}"
	make_vdb_entry "${tmp}/vdb" claude-agent-acp-tui "${v_tui}"

	out="$(run_status "${tmp}/overlay" "${tmp}/vdb" "${tmp}/chain")"
	plus="$(adapter_row "${out}" '@lucascouts/claude-agent-acp-plus')"
	tui="$(adapter_row "${out}" '@lucascouts/claude-agent-tui')"

	assert_contains "${out}" 'installed' &&
		assert_contains "${plus}" "ok" &&
		assert_contains "${plus}" "${v_plus}" &&
		assert_not_contains "${plus}" "DRIFT" &&
		assert_not_contains "${tui}" "DRIFT" && ok
	rm -rf "${tmp}"
}

test_status_installed_behind_is_drift() {
	case_start "status: an installed version behind the ebuild is drift, and the row says which side is behind"
	local tmp out plus tui v_plus v_tui
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	v_plus="$(adapter_repo_version claude-agent-plus/claude-agent-acp-plus)"
	v_tui="$(adapter_repo_version claude-agent-tui/claude-agent-tui)"
	make_adapter_ebuild "${tmp}/overlay" claude-agent-acp-plus "${v_plus}"
	make_adapter_ebuild "${tmp}/overlay" claude-agent-acp-tui "${v_tui}"
	# 0.0.1 is behind anything either adapter has ever published, so the case
	# needs no arithmetic on the real version to stay behind it.
	make_vdb_entry "${tmp}/vdb" claude-agent-acp-plus 0.0.1
	make_vdb_entry "${tmp}/vdb" claude-agent-acp-tui "${v_tui}"

	out="$(run_status "${tmp}/overlay" "${tmp}/vdb" "${tmp}/chain")"
	plus="$(adapter_row "${out}" '@lucascouts/claude-agent-acp-plus')"
	tui="$(adapter_row "${out}" '@lucascouts/claude-agent-tui')"

	assert_contains "${plus}" "DRIFT" &&
		assert_contains "${plus}" "0.0.1" &&
		assert_contains "${out}" "behind" &&
		assert_not_contains "${tui}" "DRIFT" && ok
	rm -rf "${tmp}"
}

test_status_installed_absent_is_named() {
	case_start "status: a package Portage has not merged prints absent, never an empty cell"
	local tmp out plus v_plus v_tui
	tmp="$(mktemp -d)"
	make_chain "${tmp}/chain"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	v_plus="$(adapter_repo_version claude-agent-plus/claude-agent-acp-plus)"
	v_tui="$(adapter_repo_version claude-agent-tui/claude-agent-tui)"
	make_adapter_ebuild "${tmp}/overlay" claude-agent-acp-plus "${v_plus}"
	make_adapter_ebuild "${tmp}/overlay" claude-agent-acp-tui "${v_tui}"
	mkdir -p "${tmp}/vdb/dev-util"
	make_vdb_entry "${tmp}/vdb" claude-agent-acp-tui "${v_tui}"

	out="$(run_status "${tmp}/overlay" "${tmp}/vdb" "${tmp}/chain")"
	plus="$(adapter_row "${out}" '@lucascouts/claude-agent-acp-plus')"

	# Absent ABSTAINS rather than drifting: nothing merged is not two copies
	# disagreeing, and a machine that installs the adapters some other way must
	# not have the chain's top-line answer turned red by that choice. It is said
	# in a word for the same reason `skipped` and `?` are -- an empty cell reads
	# like agreement.
	assert_contains "${plus}" "absent" &&
		assert_not_contains "${plus}" "DRIFT" && ok
	rm -rf "${tmp}"
}

# --- check-protocol.sh: which lock file the live clause probes ---------------
#
# The live clause is the only part of this tooling that opens a socket, so it is
# the only one whose fixtures have to answer one. Nothing here reaches the
# network: the listener binds 127.0.0.1 and the dead ports are ones the kernel
# has just confirmed nobody holds.
#
# PATH is cut to /usr/bin:/bin for these three cases, and that is not a detail.
# It drops /opt/bin and with it `claude`, so check_cli takes its 'no claude on
# PATH' skip and the exit code under test belongs to the live clause alone.
# Keeping the real PATH would have made every case below depend on whether the
# CLI on this machine still matches five string literals — a coupling that would
# turn the next CLI release into a red here for a reason unrelated to locks.

# dead_port <start> — the first port at or above <start> that refuses a connect.
#
# Low and fixed rather than kernel-allocated, because these lock FILENAMES have
# to sort lexicographically ahead of the live one: `sort` over the glob is
# exactly what the old code took, so a fixture whose live lock happens to sort
# first would pass without testing anything.
dead_port() {
	local p="$1"
	while ((p < 65000)); do
		if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${p}" 2>/dev/null; then
			printf '%s' "${p}"
			return 0
		fi
		p=$((p + 1))
	done
	printf '%s' "$1"
}

# start_listener <port> <readyfile> — a listener that accepts a connection and
# closes it without speaking websocket: enough to answer a connect, never enough
# to pass the handshake. Prints its PID.
#
# Its stdout and stderr go to /dev/null, which is load-bearing rather than tidy:
# the caller reads that PID through a command substitution, and a background
# child inheriting the substitution's pipe holds its write end open for as long
# as it lives. This one lives until it is killed, so the substitution would never
# return -- measured as a selftest stuck in anon_pipe_read with no children.
start_listener() {
	local port="$1" ready="$2" pid waited=0
	python3 -c 'import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
open(sys.argv[2], "w").write("ready")
while True:
    c, _ = s.accept()
    c.close()' "${port}" "${ready}" >/dev/null 2>&1 &
	pid=$!
	while [[ ! -s "${ready}" ]] && ((waited < 100)); do
		sleep 0.05
		waited=$((waited + 1))
	done
	printf '%s' "${pid}"
}

# make_lock <ide-dir> <port> [ideName] — one ~/.claude/ide lock file.
make_lock() {
	local dir="$1" port="$2" ide="${3:-Zed}"
	mkdir -p "${dir}"
	printf '{"pid":1,"ideName":"%s","transport":"ws","useWebSocket":true,"authToken":"fixture-token","workspaceFolders":["/tmp"]}\n' \
		"${ide}" >"${dir}/${port}.lock"
}

# run_protocol <config-dir> — check-protocol.sh against a fixture lock directory.
run_protocol() {
	# Run with the fixture directory as cwd: the hostile-name case needs a marker
	# it can name WITHOUT a slash, since a slash in a filename cannot be created
	# at all -- the first version of that case silently created nothing and passed
	# vacuously.
	( cd "$1" && PATH=/usr/bin:/bin CLAUDE_CONFIG_DIR="$1" \
		bash "${SCRIPTS}/check-protocol.sh" 2>&1 )
}

test_protocol_picks_a_lock_that_answers() {
	case_start "protocol: the live clause probes the lock whose port answers, not the first name in the glob"
	local tmp ide out status pid live dead_a dead_b
	tmp="$(mktemp -d)"
	ide="${tmp}/ide"
	dead_a="$(dead_port 10001)"
	dead_b="$(dead_port $((dead_a + 1)))"
	live="$(dead_port 64000)"
	pid="$(start_listener "${live}" "${tmp}/ready")"
	make_lock "${ide}" "${dead_a}"
	make_lock "${ide}" "${dead_b}"
	make_lock "${ide}" "${live}"

	out="$(run_protocol "${tmp}")"
	status=$?
	kill "${pid}" 2>/dev/null

	assert_contains "${out}" "port ${live}:" &&
		assert_not_contains "${out}" "port ${dead_a}:" &&
		assert_not_contains "${out}" "port ${dead_b}:" && ok
	rm -rf "${tmp}"
}

test_protocol_refuses_a_lock_name_that_is_not_a_port() {
	case_start "protocol: a lock file whose name would execute a command is refused, not dialled"
	local tmp ide out status marker
	tmp="$(mktemp -d)"
	ide="${tmp}/ide"
	marker="${tmp}/executed"
	mkdir -p "${ide}"
	# The port is derived from the filename, and ~/.claude/ide holds whatever any
	# IDE integration wrote there. Spliced into a shell string, this name runs
	# `touch`; the marker is how the case tells dialling from executing, because
	# both leave the same silence behind. The payload names the marker RELATIVELY
	# and run_protocol supplies the cwd -- an absolute path would put slashes in
	# the filename, which cannot be created, and the case would pass vacuously.
	: >"${ide}/\$(touch executed).lock"
	[[ -e "${ide}/\$(touch executed).lock" ]] || {
		no "the fixture lock was never created -- the case would prove nothing"
		rm -rf "${tmp}"
		return 1
	}
	make_lock "${ide}" "$(dead_port 10001)"

	out="$(run_protocol "${tmp}")"
	status=$?

	{ [[ ! -e "${marker}" ]] || {
		no "the lock file's name was EXECUTED -- ${marker} exists"
		false
	}; } &&
		assert_status 0 "${status}" &&
		assert_not_contains "${out}" "DRIFT" && ok
	rm -rf "${tmp}"
}

test_protocol_skips_when_no_lock_answers() {
	case_start "protocol: every lock stale is a skip with exit 0, naming how many were found and how many were dead"
	local tmp ide out status dead_a dead_b
	tmp="$(mktemp -d)"
	ide="${tmp}/ide"
	dead_a="$(dead_port 10001)"
	dead_b="$(dead_port $((dead_a + 1)))"
	make_lock "${ide}" "${dead_a}"
	make_lock "${ide}" "${dead_b}"

	out="$(run_protocol "${tmp}")"
	status=$?

	# An absent Zed is not a broken contract: the script's own header reserves
	# exit 0 for 'contract intact (or not askable)', and this is not askable.
	assert_status 0 "${status}" &&
		assert_contains "${out}" "2 lock files" &&
		assert_contains "${out}" "2 stale" &&
		assert_not_contains "${out}" "DRIFT" && ok
	rm -rf "${tmp}"
}

test_protocol_still_reports_drift_on_an_answering_lock() {
	case_start "protocol: a lock that answers and then fails the upgrade is still exit 1"
	local tmp ide out status pid live
	tmp="$(mktemp -d)"
	ide="${tmp}/ide"
	live="$(dead_port 64000)"
	pid="$(start_listener "${live}" "${tmp}/ready")"
	make_lock "${ide}" "${live}"

	out="$(run_protocol "${tmp}")"
	status=$?
	kill "${pid}" 2>/dev/null

	# The skip must not have eaten the failure it was added beside: 1 keeps
	# meaning the contract drifted, or status.sh's `|| true` starts swallowing
	# something different from what it was written to swallow.
	assert_status 1 "${status}" &&
		assert_contains "${out}" "DRIFT" &&
		assert_contains "${out}" "no websocket upgrade" && ok
	rm -rf "${tmp}"
}

# --- xvfb-proof.sh: a private display and an isolated Zeo (story 021) --------
#
# Every tool the harness drives is a stub on PATH: no X server starts, no Zeo
# runs. Each stub appends what it was asked to STUB_LOG, prefixed with the
# DISPLAY it saw, and the long-lived ones (Xvfb, the editor) record their PID in
# STUB_PIDS and exec into a sleep, so a case can prove they were stopped.

# make_xvfb_stubs <bindir> — Xvfb, xdotool, import, identify and a fake editor.
#
# Behaviour switches, read by the stubs at run time:
#   XVFB_STUB_DIE=1        Xvfb exits at once, creating no socket
#   XVFB_STUB_NO_SOCKET=1  Xvfb stays alive but never creates its socket
#   ZEO_STUB_NO_WINDOW=1   the editor never shows a window
#   ZEO_STUB_IGNORE_TERM=1 the editor ignores SIGTERM and must be killed
#   ZEO_STUB_CRASH_CHILD=<file> the editor forks a child, records its PID in
#                          <file> and exits at once, as a crash would
#   XDOTOOL_STUB_FAIL=<sub> xdotool exits 1 when its first argument is <sub>
#   IDENTIFY_STUB_GEOM     what identify reports ("1920 1080" when unset)
make_xvfb_stubs() {
	local bindir="$1"
	mkdir -p "${bindir}"
	cat >"${bindir}/Xvfb" <<'STUB'
#!/usr/bin/env bash
printf 'DISPLAY=%s Xvfb %s\n' "${DISPLAY-}" "$*" >>"${STUB_LOG}"
[[ -z "${XVFB_STUB_DIE-}" ]] || exit 1
if [[ -z "${XVFB_STUB_NO_SOCKET-}" ]]; then
	mkdir -p "${XVFB_PROOF_X11_ROOT}/.X11-unix"
	: >"${XVFB_PROOF_X11_ROOT}/.X11-unix/X${1#:}"
fi
printf '%s\n' "$$" >>"${STUB_PIDS}"
exec sleep 300
STUB
	cat >"${bindir}/zeo-editor" <<'STUB'
#!/usr/bin/env bash
printf 'DISPLAY=%s zeo %s\n' "${DISPLAY-}" "$*" >>"${STUB_LOG}"
printf 'env WAYLAND_DISPLAY=[%s] XDG_CACHE_HOME=%s XDG_STATE_HOME=%s ZED_ALLOW_EMULATED_GPU=%s ZED_STATELESS=%s\n' \
	"${WAYLAND_DISPLAY-unset}" "${XDG_CACHE_HOME-unset}" "${XDG_STATE_HOME-unset}" \
	"${ZED_ALLOW_EMULATED_GPU-unset}" "${ZED_STATELESS-unset}" >>"${STUB_LOG}"
udd=""
for ((i = 1; i < $#; i++)); do
	[[ "${!i}" == --user-data-dir ]] && j=$((i + 1)) && udd="${!j}"
done
printf 'config: %s\n' "$(cat "${udd}/config/settings.json" "${udd}/config/keymap.json" 2>/dev/null)" >>"${STUB_LOG}"
echo "zeo stub started"
[[ -n "${ZEO_STUB_NO_WINDOW-}" ]] || : >"${STUB_WINDOW}"
if [[ -n "${ZEO_STUB_CRASH_CHILD-}" ]]; then
	sleep 300 &
	printf '%s\n' "$!" >"${ZEO_STUB_CRASH_CHILD}"
	exit 3
fi
printf '%s\n' "$$" >>"${STUB_PIDS}"
# An ignored signal stays ignored across exec: the sleep below then shrugs off
# SIGTERM the way a hung editor would.
[[ -z "${ZEO_STUB_IGNORE_TERM-}" ]] || trap '' TERM
exec sleep 300
STUB
	cat >"${bindir}/xdotool" <<'STUB'
#!/usr/bin/env bash
printf 'DISPLAY=%s xdotool %s\n' "${DISPLAY-}" "$*" >>"${STUB_LOG}"
[[ "${1-}" != "${XDOTOOL_STUB_FAIL-}" ]] || exit 1
if [[ "${1-}" == search ]]; then
	[[ -e "${STUB_WINDOW}" ]] || exit 1
	echo 4194307
fi
exit 0
STUB
	cat >"${bindir}/import" <<'STUB'
#!/usr/bin/env bash
printf 'DISPLAY=%s import %s\n' "${DISPLAY-}" "$*" >>"${STUB_LOG}"
printf 'PNG' >"${!#}"
STUB
	cat >"${bindir}/identify" <<'STUB'
#!/usr/bin/env bash
printf 'DISPLAY=%s identify %s\n' "${DISPLAY-}" "$*" >>"${STUB_LOG}"
printf '%s' "${IDENTIFY_STUB_GEOM:-1920 1080}"
STUB
	chmod +x "${bindir}"/*
}

# run_xvfb_proof <tmp> <args...> — the harness against the stubs in <tmp>/bin.
# It execs, so a call put in the background leaves the harness itself in $!.
# Call it only in a subshell -- $(...), ( ... ) or & -- or it replaces this one.
# DISPLAY defaults to :0, the operator's display the harness must never drive.
run_xvfb_proof() {
	local tmp="$1"
	shift
	[[ -x "${tmp}/bin/Xvfb" ]] || make_xvfb_stubs "${tmp}/bin"
	PATH="${tmp}/bin:${PATH}" \
		DISPLAY="${XVFB_TEST_DISPLAY-:0}" \
		STUB_LOG="${tmp}/stub.log" \
		STUB_PIDS="${tmp}/stub.pids" \
		STUB_WINDOW="${tmp}/window" \
		XVFB_PROOF_X11_ROOT="${tmp}/x" \
		XVFB_PROOF_XVFB_TIMEOUT=2 \
		XVFB_PROOF_WINDOW_TIMEOUT="${XVFB_TEST_WINDOW_TIMEOUT:-5}" \
		exec bash "${SCRIPTS}/xvfb-proof.sh" --binary "${tmp}/bin/zeo-editor" "$@" 2>&1
}

# stub_log <tmp> — what the stubs were asked, or nothing when none ran.
stub_log() {
	[[ -f "$1/stub.log" ]] && cat "$1/stub.log"
	return 0
}

test_xvfb_proof_steps_valid_prints_plan() {
	case_start "xvfb-proof: --dry-run validates every kind and prints the plan, starting nothing (R2.1)"
	local tmp out status
	tmp="$(mktemp -d)"
	cat >"${tmp}/steps.json" <<'JSON'
[
  {"type": "agent: toggle focus"},
  {"key": ["ctrl+shift+p", "Return"]},
  {"click": [10, 20]},
  {"move": [30, 40]},
  {"sleep": 0.5},
  {"shot": "out/panel.png", "window": true}
]
JSON
	out="$(run_xvfb_proof "${tmp}" --steps "${tmp}/steps.json" --dry-run)"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "6 steps" &&
		assert_contains "${out}" "1 type" &&
		assert_contains "${out}" "6 shot" &&
		assert_equal "" "$(stub_log "${tmp}")" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_steps_unknown_kind_names_index() {
	case_start "xvfb-proof: an unknown kind exits 1 naming index and kind, before anything starts (R2.2)"
	local tmp out status
	tmp="$(mktemp -d)"
	printf '[{"type": "a"}, {"focus": "zed"}]' >"${tmp}/steps.json"
	# No --dry-run: a broken script must stop before the display or Zeo exist.
	out="$(run_xvfb_proof "${tmp}" --steps "${tmp}/steps.json")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "step 2" &&
		assert_contains "${out}" "focus" &&
		assert_equal "" "$(stub_log "${tmp}")" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_steps_missing_field_exits_1() {
	case_start "xvfb-proof: a step missing its field exits 1 naming index and kind (R2.2)"
	local tmp out status
	tmp="$(mktemp -d)"
	printf '[{"sleep": 0.1}, {"click": [10]}]' >"${tmp}/steps.json"
	out="$(run_xvfb_proof "${tmp}" --steps "${tmp}/steps.json" --dry-run)"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "step 2" &&
		assert_contains "${out}" "click" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_steps_unreadable_file_exits_2() {
	case_start "xvfb-proof: an unreadable step script exits 2"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(run_xvfb_proof "${tmp}" --steps "${tmp}/absent.json" --dry-run)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "absent.json" && ok
	rm -rf "${tmp}"
}

# one_step <tmp> <json> — a step script holding <json>, its path on stdout.
one_step() {
	printf '%s' "$2" >"$1/steps.json"
	printf '%s' "$1/steps.json"
}

test_xvfb_proof_display_skips_a_locked_display() {
	case_start "xvfb-proof: a display with a lock file is skipped; Xvfb starts on the next one (R1.1)"
	local tmp out
	tmp="$(mktemp -d)"
	mkdir -p "${tmp}/x"
	: >"${tmp}/x/.X90-lock"
	out="$(run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	assert_contains "$(stub_log "${tmp}")" "Xvfb :91 -screen 0 1920x1080x24" &&
		assert_not_contains "$(stub_log "${tmp}")" "Xvfb :90" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_display_refuses_the_operators_display() {
	case_start "xvfb-proof: a target equal to \$DISPLAY is refused with exit 1 and no input (R1.2)"
	local tmp out status
	tmp="$(mktemp -d)"
	# The operator's display is one the selection would pick: nothing on disk
	# marks :90 as taken, so only the guard stands between the run and it.
	out="$(XVFB_TEST_DISPLAY=:90 run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"key": ["Return"]}]')")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "refus" &&
		assert_contains "${out}" ":90" &&
		assert_not_contains "$(stub_log "${tmp}")" "xdotool key" &&
		assert_not_contains "$(stub_log "${tmp}")" " zeo " && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_display_exits_2_when_xvfb_dies() {
	case_start "xvfb-proof: an Xvfb that dies at start exits 2 naming the display (R1.1)"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(XVFB_STUB_DIE=1 run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" ":90" &&
		assert_not_contains "$(stub_log "${tmp}")" " zeo " && ok
	rm -rf "${tmp}"
}

# workdir_of <output> — the isolated directory the run announced.
workdir_of() {
	sed -n 's/^workdir: //p' <<<"$1" | head -n 1
}

test_xvfb_proof_launch_isolates_the_editor() {
	case_start "xvfb-proof: Zeo gets its own data, cache and state dirs on the private display, X11 forced (R1.3, R1.4)"
	local tmp out wd log
	tmp="$(mktemp -d)"
	out="$(ZED_STATELESS=1 run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	wd="$(workdir_of "${out}")"
	log="$(stub_log "${tmp}")"
	# ZED_STATELESS is exported on purpose: --keep only works if the harness
	# strips it, because a stateless Zeo writes no threads to reopen.
	[[ -n "${wd}" && "${#wd}" -le 60 ]] || no "workdir missing or over 60 bytes: [${wd}]"
	[[ -n "${wd}" && "${#wd}" -le 60 ]] &&
		assert_contains "${log}" "DISPLAY=:90 zeo --user-data-dir ${wd}" &&
		assert_contains "${log}" "WAYLAND_DISPLAY=[]" &&
		assert_contains "${log}" "XDG_CACHE_HOME=${wd}/cache" &&
		assert_contains "${log}" "XDG_STATE_HOME=${wd}/state" &&
		assert_contains "${log}" "ZED_ALLOW_EMULATED_GPU=1" &&
		assert_contains "${log}" "ZED_STATELESS=unset" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_launch_copies_settings_and_keymap() {
	case_start "xvfb-proof: --settings and --keymap land in the isolated config/ before launch (R1.5)"
	local tmp
	tmp="$(mktemp -d)"
	printf '{"SETTINGS": 1}' >"${tmp}/settings.json"
	printf '[{"KEYMAP": 1}]' >"${tmp}/keymap.json"
	(run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')" \
		--settings "${tmp}/settings.json" --keymap "${tmp}/keymap.json" >/dev/null)
	assert_contains "$(stub_log "${tmp}")" 'config: {"SETTINGS": 1}[{"KEYMAP": 1}]' && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_launch_window_timeout_names_the_log() {
	case_start "xvfb-proof: no window within the timeout exits 2 naming the timeout and Zeo's log (R2.3)"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(ZEO_STUB_NO_WINDOW=1 XVFB_TEST_WINDOW_TIMEOUT=1 run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "within 1 s" &&
		assert_contains "${out}" "$(workdir_of "${out}")/zeo.log" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_launch_refuses_an_overlong_path() {
	case_start "xvfb-proof: an isolated directory over 60 bytes exits 2 before anything starts (R1.3)"
	local tmp out status long
	tmp="$(mktemp -d)"
	long="${tmp}/$(printf 'd%.0s' {1..60})"
	mkdir -p "${long}"
	out="$(XVFB_PROOF_TMP_ROOT="${long}" run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "60 bytes" &&
		assert_equal "" "$(stub_log "${tmp}")" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_drive_sends_every_step_to_the_private_display() {
	case_start "xvfb-proof: each kind becomes its xdotool/import call, all on the private display (R2.1, R3.1)"
	local tmp out status log
	tmp="$(mktemp -d)"
	out="$(run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" "[
		{\"type\": \"agent: toggle focus\"},
		{\"key\": [\"ctrl+shift+p\", \"Return\"]},
		{\"click\": [10, 20]},
		{\"move\": [30, 40]},
		{\"sleep\": 0.01},
		{\"shot\": \"${tmp}/caps/panel.png\"}]")")"
	status=$?
	log="$(stub_log "${tmp}")"
	assert_status 0 "${status}" &&
		assert_contains "${log}" "DISPLAY=:90 xdotool type --delay 20 -- agent: toggle focus" &&
		assert_contains "${log}" "DISPLAY=:90 xdotool key -- ctrl+shift+p Return" &&
		assert_contains "${log}" "DISPLAY=:90 xdotool mousemove 10 20 click 1" &&
		assert_contains "${log}" "DISPLAY=:90 xdotool mousemove 30 40" &&
		assert_contains "${log}" "DISPLAY=:90 import -window root ${tmp}/caps/panel.png" &&
		assert_not_contains "${log}" "DISPLAY=:0 xdotool" &&
		assert_contains "${out}" "1920x1080" && {
		[[ -s "${tmp}/caps/panel.png" ]] || no "the capture was not kept"
		[[ -s "${tmp}/caps/panel.png" ]]
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_drive_deletes_a_degenerate_capture() {
	case_start "xvfb-proof: a capture under 200 px is deleted and exits 1 naming file and geometry (R3.2)"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(IDENTIFY_STUB_GEOM="1 1" run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" "[{\"shot\": \"${tmp}/tiny.png\"}]")")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "${tmp}/tiny.png" &&
		assert_contains "${out}" "1x1" && {
		[[ ! -e "${tmp}/tiny.png" ]] || no "the 1x1 capture was left behind"
		[[ ! -e "${tmp}/tiny.png" ]]
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_drive_failing_xdotool_names_the_step() {
	case_start "xvfb-proof: a failing xdotool exits 1 naming the step index; later steps never run"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(XDOTOOL_STUB_FAIL=key run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" "[
		{\"sleep\": 0.01}, {\"key\": [\"Return\"]}, {\"shot\": \"${tmp}/never.png\"}]")")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "step 2" &&
		assert_not_contains "$(stub_log "${tmp}")" "import" && ok
	rm -rf "${tmp}"
}

# stubs_stopped <tmp> — both long-lived stubs ran and none is left alive.
# A zombie counts as stopped: it is gone, only not yet reaped by its parent.
stubs_stopped() {
	local pid count=0
	[[ -f "$1/stub.pids" ]] || {
		no "no stub recorded a PID"
		return 1
	}
	while read -r pid; do
		count=$((count + 1))
		if kill -0 "${pid}" 2>/dev/null && [[ "$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null)" != Z ]]; then
			kill -KILL "${pid}" 2>/dev/null
			no "stub pid ${pid} outlived the harness"
			return 1
		fi
	done <"$1/stub.pids"
	[[ "${count}" -eq 2 ]] || {
		no "expected Xvfb and Zeo to record a PID, got ${count}"
		return 1
	}
}

test_xvfb_proof_lifecycle_stops_everything_on_success() {
	case_start "xvfb-proof: after a successful run Xvfb and Zeo are gone and the temp dir removed (R4.1, R4.2)"
	local tmp out status wd
	tmp="$(mktemp -d)"
	out="$(run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	status=$?
	wd="$(workdir_of "${out}")"
	assert_status 0 "${status}" && stubs_stopped "${tmp}" && {
		[[ -n "${wd}" && ! -e "${wd}" ]] || no "the temp dir survived: [${wd}]"
		[[ -n "${wd}" && ! -e "${wd}" ]]
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_lifecycle_stops_everything_on_failure() {
	case_start "xvfb-proof: a failed step still stops Xvfb and a Zeo deaf to SIGTERM, and removes the temp dir (R4.1, R4.2)"
	local tmp out status wd
	tmp="$(mktemp -d)"
	out="$(ZEO_STUB_IGNORE_TERM=1 IDENTIFY_STUB_GEOM="1 1" run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" "[{\"shot\": \"${tmp}/x.png\"}]")")"
	status=$?
	wd="$(workdir_of "${out}")"
	assert_status 1 "${status}" && stubs_stopped "${tmp}" && {
		[[ -n "${wd}" && ! -e "${wd}" ]] || no "the temp dir survived: [${wd}]"
		[[ -n "${wd}" && ! -e "${wd}" ]]
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_lifecycle_stops_everything_on_sigterm() {
	case_start "xvfb-proof: SIGTERM in the middle of a long sleep stops everything promptly (R4.1)"
	local tmp pid tries start elapsed wd children child orphans=""
	tmp="$(mktemp -d)"
	run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 30}]')" >"${tmp}/out" &
	pid=$!
	for ((tries = 100; tries > 0; tries--)); do
		grep -q '^step 1: sleep' "${tmp}/out" 2>/dev/null && break
		sleep 0.1
	done
	# Every child, the step's own sleep included: an orphan left sleeping is
	# exactly what outliving the run means.
	children="$(pgrep -P "${pid}")"
	start=${SECONDS}
	kill -TERM "${pid}"
	wait "${pid}"
	elapsed=$((SECONDS - start))
	wd="$(workdir_of "$(cat "${tmp}/out")")"
	for child in ${children}; do
		if kill -0 "${child}" 2>/dev/null && [[ "$(awk '{print $3}' "/proc/${child}/stat" 2>/dev/null)" != Z ]]; then
			orphans+=" ${child}($(cat "/proc/${child}/comm" 2>/dev/null))"
			kill -KILL "${child}"
		fi
	done
	[[ -n "${children}" ]] || no "the harness had no children to check"
	[[ -z "${orphans}" ]] || no "children outlived SIGTERM:${orphans}"
	[[ -n "${children}" && -z "${orphans}" ]] && {
		[[ "${elapsed}" -le 8 ]] || no "the harness took ${elapsed} s to honour SIGTERM"
		[[ "${elapsed}" -le 8 ]]
	} && stubs_stopped "${tmp}" && {
		[[ -n "${wd}" && ! -e "${wd}" ]] || no "the temp dir survived: [${wd}]"
		[[ -n "${wd}" && ! -e "${wd}" ]]
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_lifecycle_keep_reuses_and_preserves() {
	case_start "xvfb-proof: --keep uses the given dir, keeps it, and a second run reopens it (R4.3)"
	local tmp out1 out2 keep
	tmp="$(mktemp -d)"
	keep="${tmp}/keep"
	out1="$(run_xvfb_proof "${tmp}" --keep "${keep}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	: >"${keep}/thread-marker"
	out2="$(run_xvfb_proof "${tmp}" --keep "${keep}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	assert_equal "${keep}" "$(workdir_of "${out1}")" &&
		assert_equal "${keep}" "$(workdir_of "${out2}")" &&
		assert_contains "$(stub_log "${tmp}")" "zeo --user-data-dir ${keep}" && {
		[[ -e "${keep}/thread-marker" && -d "${keep}/config" ]] || no "the kept dir lost its contents"
		[[ -e "${keep}/thread-marker" && -d "${keep}/config" ]]
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_steps_chord_needs_two_names() {
	case_start "xvfb-proof: a chord with fewer than two names exits 1 naming index and kind (R2.2)"
	local tmp out status
	tmp="$(mktemp -d)"
	printf '[{"chord": ["Control_L", "Shift_L", "p"]}, {"chord": ["p"]}]' >"${tmp}/steps.json"
	out="$(run_xvfb_proof "${tmp}" --steps "${tmp}/steps.json" --dry-run)"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "step 2 (chord)" &&
		assert_not_contains "${out}" "step 1" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_drive_sends_a_chord_as_one_combination() {
	case_start "xvfb-proof: live-proof.py's chord becomes one xdotool key with + (R2.1)"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"chord": ["Control_L", "Shift_L", "p"]}]')")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "$(stub_log "${tmp}")" "DISPLAY=:90 xdotool key -- Control_L+Shift_L+p" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_steps_option_without_value_exits_2() {
	case_start "xvfb-proof: an option given without its value exits 2 naming the option"
	local tmp out status
	tmp="$(mktemp -d)"
	out="$(run_xvfb_proof "${tmp}" --steps)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "--steps" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_display_socketless_xvfb_times_out() {
	case_start "xvfb-proof: an Xvfb alive without its socket exits 2 naming the timeout, and is stopped (R1.1)"
	local tmp out status pid
	tmp="$(mktemp -d)"
	out="$(XVFB_STUB_NO_SOCKET=1 run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.01}]')")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "within 2 s" &&
		assert_not_contains "$(stub_log "${tmp}")" " zeo " && {
		pid="$(head -n 1 "${tmp}/stub.pids")"
		! kill -0 "${pid}" 2>/dev/null || {
			kill -KILL "${pid}"
			no "the socketless Xvfb outlived the run"
			false
		}
	} && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_drive_sends_punctuation_as_keysyms() {
	case_start "xvfb-proof: a one-character punctuation key reaches xdotool as its keysym, in key and chord (R2.1)"
	local tmp out status log
	tmp="$(mktemp -d)"
	out="$(run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"key": ["/", "a", "Return"]}, {"chord": ["Control_L", "."]}]')")"
	status=$?
	log="$(stub_log "${tmp}")"
	assert_status 0 "${status}" &&
		assert_contains "${log}" "xdotool key -- 0x2f a Return" &&
		assert_contains "${log}" "xdotool key -- Control_L+0x2e" && ok
	rm -rf "${tmp}"
}

test_xvfb_proof_lifecycle_stops_the_group_of_a_crashed_editor() {
	case_start "xvfb-proof: a Zeo that crashed early leaves no child behind (R4.1)"
	local tmp child
	tmp="$(mktemp -d)"
	(ZEO_STUB_CRASH_CHILD="${tmp}/child" run_xvfb_proof "${tmp}" --steps "$(one_step "${tmp}" '[{"sleep": 0.5}]')" >/dev/null)
	child="$(cat "${tmp}/child" 2>/dev/null)"
	if [[ -z "${child}" ]]; then
		no "the crashing stub recorded no child"
	elif kill -0 "${child}" 2>/dev/null; then
		kill -KILL "${child}"
		no "the crashed editor's child ${child} outlived the run"
	else
		ok
	fi
	rm -rf "${tmp}"
}

# Story 026 — selftest.sh cases for the changelog guard, the release notes and
# the release refusal. A fragment: paste it into selftest.sh above the
# "# --- runner ---" banner, and add the calls listed at the end to main().
#
# Every case runs on fixtures under mktemp -d and reads no real changelog.

# --- changelog guard: fixtures ----------------------------------------------

# cl_env <tmp> <pf>... — an overlay holding one fixture ebuild per PF (copies of
# the FIXTURE_PV one), so a script that resolves the version through lib.sh
# finds it, and a scratch repo for ZP_REPO.
cl_env() {
	local tmp="$1" pf
	shift
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	for pf in "$@"; do
		[[ "${pf}" == "${FIXTURE_PV}" ]] ||
			cp "${tmp}/overlay/app-editors/zeo/${FIXTURE_PV}.ebuild" \
				"${tmp}/overlay/app-editors/zeo/${pf}.ebuild"
	done
	mkdir -p "${tmp}/repo/scripts" "${tmp}/distfiles"
}

# run_check_changelog <tmp> <changelog|-> [<PF>] — the guard, with ZP_CHANGELOG
# pointing at <changelog>, or left unset when it is "-".
run_check_changelog() {
	local tmp="$1" changelog="$2"
	shift 2
	if [[ "${changelog}" == "-" ]]; then
		env -u ZP_CHANGELOG ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" \
			ZP_WORKROOT="${tmp}/work" ZP_REPO="${tmp}/repo" \
			bash "${SCRIPTS}/check-changelog.sh" "$@" 2>&1
	else
		ZP_CHANGELOG="${changelog}" ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" \
			ZP_WORKROOT="${tmp}/work" ZP_REPO="${tmp}/repo" \
			bash "${SCRIPTS}/check-changelog.sh" "$@" 2>&1
	fi
}

run_changelog_notes() {
	local tmp="$1" changelog="$2"
	shift 2
	ZP_CHANGELOG="${changelog}" ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" \
		ZP_WORKROOT="${tmp}/work" ZP_REPO="${tmp}/repo" \
		bash "${SCRIPTS}/changelog-notes.sh" "$@" 2>&1
}

# cl_header <file> — the Keep a Changelog preamble and an empty [Unreleased].
cl_header() {
	cat >"$1" <<-'EOS'
		# Changelog

		All notable changes to Zeo are documented here. The format follows
		[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the
		version [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

		## [Unreleased]

	EOS
}

# cl_with_0_1_1 <file> — a changelog whose 0.1.1 section exists, with a newer
# 0.1.10 above it whose name starts with the same characters.
cl_with_0_1_1() {
	cl_header "$1"
	cat >>"$1" <<-'EOS'
		## [0.1.10] — 2027-01-01

		### Fixed

		- TEN-BODY: a change that belongs to 0.1.10 only.

		## [0.1.1] — 2026-10-04

		### Added

		- ONE-BODY-ADDED: the agent tasks panel (patch 0035).

		### Fixed

		- ONE-BODY-FIXED: thread configuration survives a reopen (patch 0036).

		## [0.1.0] — 2026-10-01

		### Changed

		- ZERO-BODY: Zed rebranded as Zeo (patches 0019-0023, 0025).

		[0.1.10]: https://example.invalid/compare/v0.1.1...v0.1.10
		[0.1.1]: https://example.invalid/compare/v0.1.0...v0.1.1
		[0.1.0]: https://example.invalid/releases/v0.1.0
	EOS
}

# cl_without_0_1_1 <file> — every way 0.1.1 can APPEAR without having a
# section: a mention in prose, a deeper heading, an indented code block, a
# fenced code block, a link reference definition, a heading with an
# unescaped-dot look-alike, and the neighbouring 0.1.10 / 10.1.1 / 0.1.11.
cl_without_0_1_1() {
	cl_header "$1"
	cat >>"$1" <<-'EOS'
		The next release will open with a line such as ## [0.1.1] — 2026-10-04,
		written by hand when it is cut.

		### [0.1.1] — 2026-10-04

		    ## [0.1.1] — 2026-10-04

		```markdown
		## [0.1.1] — 2026-10-04
		```

		## [0x1x1] — 2026-10-03

		## [0.1.11] — 2026-10-02

		## [10.1.1] — 2026-10-02

		## [0.1.10] — 2026-10-02

		### Fixed

		- TEN-BODY: a change that belongs to 0.1.10 only.

		## [0.1.0] — 2026-10-01

		### Changed

		- ZERO-BODY: Zed rebranded as Zeo.

		[0.1.1]: https://example.invalid/compare/v0.1.0...v0.1.1
		[0.1.0]: https://example.invalid/releases/v0.1.0
	EOS
}

# --- check-changelog.sh (R3.1 - R3.3, R2.3) ---------------------------------

# Hostile first: 0.1.1 is MENTIONED in every way a careless match would accept,
# and never has a section of its own. It must not pass.
test_check_changelog_ignores_mentions_and_lookalikes() {
	case_start "check-changelog: 0.1.1 in prose, a fence, an h3, a link ref or as 0.1.10 is not a section (exit 1)"
	local tmp out status pf="zeo-0.1.1_p20261004"
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "${pf}"
	cl_without_0_1_1 "${tmp}/CHANGELOG.md"
	out="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "${pf}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0.1.1" &&
		assert_contains "${out}" "${tmp}/CHANGELOG.md" && ok
	rm -rf "${tmp}"
}

# The converse: 0.1.1 must not be confused with 0.1.10 when 0.1.10 is the one
# missing — the shorter section must not satisfy the longer version.
test_check_changelog_short_section_does_not_satisfy_longer_version() {
	case_start "check-changelog: a [0.1.1] section does not satisfy 0.1.10 (exit 1 naming 0.1.10)"
	local tmp out status pf="zeo-0.1.10_p20261004"
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "${pf}"
	cl_header "${tmp}/CHANGELOG.md"
	printf '## [0.1.1] — 2026-10-04\n\n### Added\n\n- ONE-BODY.\n' >>"${tmp}/CHANGELOG.md"
	out="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "${pf}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0.1.10" && ok
	rm -rf "${tmp}"
}

# Hostile split: the snapshot date and the -rN are NOT part of Zeo's version.
# A revision bump and a snapshot-only bump find the same section (R2.3).
test_check_changelog_ignores_snapshot_and_revision() {
	case_start "check-changelog: -r3 and another _p date resolve to the same [0.1.1] section (exit 0)"
	local tmp out1 out2 out3 s1 s2 s3
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "zeo-0.1.1_p20261004-r3" "zeo-0.1.1_p20991231" "zeo-0.1.1_p20261004"
	cl_with_0_1_1 "${tmp}/CHANGELOG.md"
	out1="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "zeo-0.1.1_p20261004-r3")"
	s1=$?
	out2="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "zeo-0.1.1_p20991231")"
	s2=$?
	out3="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "zeo-0.1.1_p20261004")"
	s3=$?
	assert_status 0 "${s1}" && assert_status 0 "${s2}" && assert_status 0 "${s3}" &&
		assert_not_contains "${out1}${out2}${out3}" "error" && ok
	rm -rf "${tmp}"
}

# -rN must not leak into the derived version on the failing side either: the
# refusal names 0.1.2, not 0.1.2-r1, and not the snapshot.
test_check_changelog_names_bare_version_when_missing() {
	case_start "check-changelog: a missing version exits 1 naming X.Y.Z and the changelog path"
	local tmp out status pf="zeo-0.1.2_p20261004-r1"
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "${pf}"
	cl_with_0_1_1 "${tmp}/CHANGELOG.md"
	out="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "${pf}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0.1.2" &&
		assert_contains "${out}" "${tmp}/CHANGELOG.md" &&
		assert_not_contains "${out}" "[0.1.2-r1]" && ok
	rm -rf "${tmp}"
}

test_check_changelog_unreadable_is_environment() {
	case_start "check-changelog: an unreadable changelog exits 2 naming the path"
	local tmp out status pf="zeo-0.1.1_p20261004"
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "${pf}"
	out="$(run_check_changelog "${tmp}" "${tmp}/absent/CHANGELOG.md" "${pf}")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "${tmp}/absent/CHANGELOG.md" && ok
	rm -rf "${tmp}"
}

test_check_changelog_unparsable_pf_is_environment() {
	case_start "check-changelog: a PF with no X.Y.Z exits 2 naming it"
	local tmp out status pf="zeo-banana_p20261004"
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "${pf}"
	cl_with_0_1_1 "${tmp}/CHANGELOG.md"
	out="$(run_check_changelog "${tmp}" "${tmp}/CHANGELOG.md" "${pf}")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "${pf}" && ok
	rm -rf "${tmp}"
}

# Benign last: the section exists, under the default path ../zeo/CHANGELOG.md
# beside the zed-patches repository (ZP_CHANGELOG unset).
test_check_changelog_default_path_passes() {
	case_start "check-changelog: [0.1.1] in ../zeo/CHANGELOG.md beside the repo exits 0"
	local tmp out status pf="zeo-0.1.1_p20261004"
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "${pf}"
	mkdir -p "${tmp}/zeo"
	cl_with_0_1_1 "${tmp}/zeo/CHANGELOG.md"
	out="$(run_check_changelog "${tmp}" "-" "${pf}")"
	status=$?
	assert_status 0 "${status}" && ok
	rm -rf "${tmp}"
}

# --- changelog-notes.sh (R4.1) ----------------------------------------------

test_changelog_notes_prints_only_its_section_body() {
	case_start "changelog-notes: 0.1.1 prints its body, not its heading, not 0.1.10's or 0.1.0's"
	local tmp out status
	tmp="$(mktemp -d)"
	cl_env "${tmp}"
	cl_with_0_1_1 "${tmp}/CHANGELOG.md"
	out="$(run_changelog_notes "${tmp}" "${tmp}/CHANGELOG.md" "0.1.1")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "ONE-BODY-ADDED" &&
		assert_contains "${out}" "ONE-BODY-FIXED" &&
		assert_contains "${out}" "### Fixed" &&
		assert_not_contains "${out}" "## [0.1.1]" &&
		assert_not_contains "${out}" "TEN-BODY" &&
		assert_not_contains "${out}" "ZERO-BODY" &&
		assert_not_contains "${out}" "## [0.1.0]" && ok
	rm -rf "${tmp}"
}

test_changelog_notes_accepts_a_pf() {
	case_start "changelog-notes: a PF with _p and -rN prints the same body as its X.Y.Z"
	local tmp by_version by_pf status
	tmp="$(mktemp -d)"
	cl_env "${tmp}" "zeo-0.1.1_p20261004-r3"
	cl_with_0_1_1 "${tmp}/CHANGELOG.md"
	by_version="$(run_changelog_notes "${tmp}" "${tmp}/CHANGELOG.md" "0.1.1")"
	by_pf="$(run_changelog_notes "${tmp}" "${tmp}/CHANGELOG.md" "zeo-0.1.1_p20261004-r3")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${by_pf}" "ONE-BODY-ADDED" &&
		assert_equal "${by_version}" "${by_pf}" && ok
	rm -rf "${tmp}"
}

test_changelog_notes_missing_section() {
	case_start "changelog-notes: a version mentioned but without a section exits 1 naming it"
	local tmp out status
	tmp="$(mktemp -d)"
	cl_env "${tmp}"
	cl_without_0_1_1 "${tmp}/CHANGELOG.md"
	out="$(run_changelog_notes "${tmp}" "${tmp}/CHANGELOG.md" "0.1.1")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0.1.1" &&
		assert_not_contains "${out}" "TEN-BODY" && ok
	rm -rf "${tmp}"
}

test_changelog_notes_unreadable() {
	case_start "changelog-notes: an unreadable changelog exits 2 naming the path"
	local tmp out status
	tmp="$(mktemp -d)"
	cl_env "${tmp}"
	out="$(run_changelog_notes "${tmp}" "${tmp}/absent/CHANGELOG.md" "0.1.1")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "${tmp}/absent/CHANGELOG.md" && ok
	rm -rf "${tmp}"
}

# --- check-sync.sh runs the guard (R3.4) ------------------------------------

run_checksync_changelog() {
	local tmp="$1" changelog="$2"
	shift 2
	ZP_CHANGELOG="${changelog}" ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" \
		ZP_WORKROOT="${tmp}/work" ZP_REPO="${tmp}/repo" \
		bash "${SCRIPTS}/check-sync.sh" "${FIXTURE_PV}" "$@" 2>&1
}

# checksync_changelog_env <tmp> — every other relation in sync, so only the
# changelog can decide the verdict.
checksync_changelog_env() {
	local tmp="$1"
	verify_env "${tmp}"
	add_ebuild_patches "${tmp}/overlay" "0001-first.patch" "0002-second.patch"
	run_sync "${tmp}" >/dev/null
}

test_checksync_changelog_missing_is_drift() {
	case_start "check-sync: a packaged version with no changelog section is drift naming it (exit 1)"
	local tmp out status
	tmp="$(mktemp -d)"
	checksync_changelog_env "${tmp}"
	# 0.9.9 only as 0.9.99 and in prose — no section of its own.
	cl_header "${tmp}/CHANGELOG.md"
	printf 'See ## [0.9.9] — 2026-01-01 once it ships.\n\n## [0.9.99] — 2026-01-02\n\n- NINES.\n' \
		>>"${tmp}/CHANGELOG.md"
	out="$(run_checksync_changelog "${tmp}" "${tmp}/CHANGELOG.md")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "DRIFT" &&
		assert_contains "${out}" "0.9.9" &&
		assert_contains "${out}" "${tmp}/CHANGELOG.md" &&
		assert_contains "${out}" "out of sync" && ok
	rm -rf "${tmp}"
}

test_checksync_changelog_unreadable_is_environment() {
	case_start "check-sync: an unreadable changelog propagates as exit 2"
	local tmp out status
	tmp="$(mktemp -d)"
	checksync_changelog_env "${tmp}"
	out="$(run_checksync_changelog "${tmp}" "${tmp}/absent/CHANGELOG.md")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "${tmp}/absent/CHANGELOG.md" && ok
	rm -rf "${tmp}"
}

test_checksync_changelog_present_is_checked_and_ok() {
	case_start "check-sync: a version with its section stays in sync and the check is reported"
	local tmp out status
	tmp="$(mktemp -d)"
	checksync_changelog_env "${tmp}"
	cl_header "${tmp}/CHANGELOG.md"
	printf '## [0.9.9] — 2026-01-01\n\n### Added\n\n- NINE.\n' >>"${tmp}/CHANGELOG.md"
	out="$(run_checksync_changelog "${tmp}" "${tmp}/CHANGELOG.md")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "in sync" &&
		assert_contains "${out,,}" "changelog" && ok
	rm -rf "${tmp}"
}

# --- release-portable.sh refuses an undocumented release (R4.2) --------------

# release_env <tmp> — every input release-portable.sh checks is present, and
# `docker` is a stub that only records how it was called; nothing is built.
release_env() {
	local tmp="$1" ebuild_dir
	verify_env "${tmp}"
	ebuild_dir="${tmp}/overlay/app-editors/zeo"
	printf 'DIST webrtc-m1-linux-x64-release.zip 1 BLAKE2B 0\n' >"${ebuild_dir}/Manifest"
	: >"${tmp}/distfiles/webrtc-m1-linux-x64-release.zip"
	mkdir -p "${ebuild_dir}/files"
	: >"${ebuild_dir}/files/app-icon-zeo.png"
	mkdir -p "${tmp}/repo/release/portable" "${tmp}/bin"
	: >"${tmp}/repo/release/portable/Containerfile"
	cat >"${tmp}/bin/docker" <<-EOS
		#!/usr/bin/env bash
		printf '%s\n' "\$*" >>"${tmp}/docker.log"
		exit 0
	EOS
	chmod +x "${tmp}/bin/docker"
	: >"${tmp}/docker.log"
}

run_release() {
	local tmp="$1" changelog="$2"
	shift 2
	PATH="${tmp}/bin:${PATH}" ZP_CHANGELOG="${changelog}" ZP_PORTABLE_DIR="${tmp}/portable" \
		ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/release-portable.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_release_refuses_version_without_changelog() {
	case_start "release-portable: no changelog section refuses with exit 1 before any container"
	local tmp out status log
	tmp="$(mktemp -d)"
	release_env "${tmp}"
	cl_without_0_1_1 "${tmp}/CHANGELOG.md"
	out="$(run_release "${tmp}" "${tmp}/CHANGELOG.md" --no-flatpak)"
	status=$?
	log="$(cat "${tmp}/docker.log")"
	assert_not_contains "${log}" "run " &&
		assert_not_contains "${log}" "build " &&
		assert_status 1 "${status}" &&
		assert_contains "${out}" "0.9.9" && ok
	rm -rf "${tmp}"
}

test_release_refuses_unreadable_changelog_as_environment() {
	case_start "release-portable: an unreadable changelog exits 2 naming it, not as a missing section"
	local tmp out status log
	tmp="$(mktemp -d)"
	release_env "${tmp}"
	out="$(run_release "${tmp}" "${tmp}/absent/CHANGELOG.md" --no-flatpak)"
	status=$?
	log="$(cat "${tmp}/docker.log")"
	assert_not_contains "${log}" "run " &&
		assert_not_contains "${log}" "build " &&
		assert_status 2 "${status}" &&
		assert_contains "${out}" "${tmp}/absent/CHANGELOG.md" &&
		assert_not_contains "${out}" "write its CHANGELOG.md section first" && ok
	rm -rf "${tmp}"
}

# The release scripts print their own header comment as their help, so a
# header that grows must not lose its last lines (story 028).
test_release_help_prints_whole_header() {
	case_start "release help: make-bin-release and release-zeo-bin print their whole header, exit 2"
	local mbr zeo s1 s2
	mbr="$(bash "${SCRIPTS}/make-bin-release.sh" 2>&1)"
	s1=$?
	zeo="$(bash "${SCRIPTS}/release-zeo-bin.sh" --help 2>&1)"
	s2=$?
	assert_status 2 "${s1}" && assert_status 2 "${s2}" &&
		assert_contains "${mbr}" "Exit: 0 written or already published" &&
		assert_contains "${mbr}" "name is already published with other bytes" &&
		assert_contains "${zeo}" "Environment: ZP_RELEASE_TMPDIR" &&
		assert_contains "${zeo}" "Exit: 0 written" &&
		assert_not_contains "${mbr}${zeo}" "#!/usr/bin/env bash" &&
		assert_not_contains "${mbr}${zeo}" "source " && ok
}

# --- runner -----------------------------------------------------------------

# main [<filter>...] — run every case, or only those whose function name contains
# ANY of the filters, each case once, in the order below. Filters that together
# match nothing fail rather than reporting a green zero.
main() {
	local -a filters=("$@")
	local t f ran=0 hit
	if [[ ! -f "${SCRIPTS}/lib.sh" ]]; then
		printf 'scripts not found under %s — nothing implemented yet\n' "${SCRIPTS}" >&2
	fi

	local tests=(
		test_lib_resolves_commit
		test_lib_rejects_ebuild_without_commit
		test_lib_falls_back_to_default_distdir
		test_lib_names_distfile_from_src_uri
		test_lib_distfile_expands_pf
		test_lib_rejects_ebuild_without_archive_rename
		test_lib_reads_overlay_from_config
		test_lib_env_overrides_config
		test_lib_rejects_config_naming_missing_dir
		test_lib_rejects_empty_config

		test_series_preserves_order
		test_series_group_carries_forward
		test_series_filter_returns_only_its_group
		test_series_lists_every_missing_entry

		test_prepare_refuses_missing_distfile
		test_prepare_refuses_mismatched_root
		test_prepare_is_idempotent
		test_prepare_leaves_pristine_baseline
		test_prepare_regenerates_a_patch

		test_verify_passes_whole_series
		test_verify_reports_failing_patch
		test_verify_requires_prepared_tree
		test_verify_leaves_tree_untouched
		test_verify_feature_filter
		test_verify_restores_baseline_tree
		test_verify_refuses_modified_tree
		test_verify_applies_series_cumulatively

		test_sync_refuses_unverified
		test_sync_copies_verified_series
		test_sync_dry_run_writes_nothing
		test_sync_reports_orphans
		test_sync_reports_zero_orphans_when_aligned

		test_branches_one_per_patch
		test_branches_leave_tree_on_baseline

		test_checksync_reports_in_sync
		test_checksync_detects_overlay_drift
		test_checksync_detects_ebuild_drift

		test_check_changelog_ignores_mentions_and_lookalikes
		test_check_changelog_short_section_does_not_satisfy_longer_version
		test_check_changelog_ignores_snapshot_and_revision
		test_check_changelog_names_bare_version_when_missing
		test_check_changelog_unreadable_is_environment
		test_check_changelog_unparsable_pf_is_environment
		test_check_changelog_default_path_passes

		test_checksync_changelog_missing_is_drift
		test_checksync_changelog_unreadable_is_environment
		test_checksync_changelog_present_is_checked_and_ok

		test_changelog_notes_prints_only_its_section_body
		test_changelog_notes_accepts_a_pf
		test_changelog_notes_missing_section
		test_changelog_notes_unreadable

		test_release_refuses_version_without_changelog
		test_release_refuses_unreadable_changelog_as_environment
		test_release_help_prints_whole_header

		test_refresh_preserves_source_set
		test_refresh_refuses_existing_destination
		test_refresh_stops_on_conflict

		test_advisory_skips_when_scanner_absent
		test_advisory_skips_when_offline
		test_advisory_reports_clean
		test_advisory_reports_findings_without_touching_the_exit_code
		test_advisory_reports_scan_failure_distinctly_from_clean
		test_advisory_skips_only_the_missing_lockfile

		test_status_calls_the_advisory_step_in_its_own_body

		test_protocol_picks_a_lock_that_answers
		test_protocol_skips_when_no_lock_answers
		test_protocol_refuses_a_lock_name_that_is_not_a_port
		test_protocol_still_reports_drift_on_an_answering_lock

		test_status_installed_agreeing_is_ok
		test_status_installed_behind_is_drift
		test_status_installed_absent_is_named

		test_xvfb_proof_steps_valid_prints_plan
		test_xvfb_proof_steps_unknown_kind_names_index
		test_xvfb_proof_steps_missing_field_exits_1
		test_xvfb_proof_steps_unreadable_file_exits_2

		test_xvfb_proof_display_skips_a_locked_display
		test_xvfb_proof_display_refuses_the_operators_display
		test_xvfb_proof_display_exits_2_when_xvfb_dies

		test_xvfb_proof_launch_isolates_the_editor
		test_xvfb_proof_launch_copies_settings_and_keymap
		test_xvfb_proof_launch_window_timeout_names_the_log
		test_xvfb_proof_launch_refuses_an_overlong_path

		test_xvfb_proof_drive_sends_every_step_to_the_private_display
		test_xvfb_proof_drive_deletes_a_degenerate_capture
		test_xvfb_proof_drive_failing_xdotool_names_the_step

		test_xvfb_proof_lifecycle_stops_everything_on_success
		test_xvfb_proof_lifecycle_stops_everything_on_failure
		test_xvfb_proof_lifecycle_stops_everything_on_sigterm
		test_xvfb_proof_lifecycle_keep_reuses_and_preserves

		test_xvfb_proof_steps_chord_needs_two_names
		test_xvfb_proof_drive_sends_a_chord_as_one_combination

		test_xvfb_proof_steps_option_without_value_exits_2
		test_xvfb_proof_display_socketless_xvfb_times_out

		test_xvfb_proof_drive_sends_punctuation_as_keysyms
		test_xvfb_proof_lifecycle_stops_the_group_of_a_crashed_editor
	)

	for t in "${tests[@]}"; do
		if ((${#filters[@]} > 0)); then
			hit=0
			for f in "${filters[@]}"; do
				[[ "${t}" == *"${f}"* ]] && hit=1 && break
			done
			((hit)) || continue
		fi
		ran=$((ran + 1))
		"${t}"
	done

	if [[ "${ran}" -eq 0 ]]; then
		printf 'no case matches the filter: %s\n' "${filters[*]}" >&2
		return 1
	fi
	printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
	[[ "${FAIL}" -eq 0 ]]
}

main "$@"
