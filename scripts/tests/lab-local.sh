#!/usr/bin/env bash
# lab.sh against ZP_LAB_HOST=local: the "host" is a temporary directory, and
# release-portable.sh is a stub that records how it was called and writes a dist/.
#
# Proves: build sends the working tree (an untracked patch included, an ignored file
# not), the changelog, the overlay package and the two distfiles; the detached run
# gets podman, the job cap and the lab paths; status walks running -> done; a second
# build is refused while one holds the lock; fetch brings dist/ back and checks it;
# a failed build reports state=failed with exit 1; clean drops the version.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${ZP_REPO:-$(cd "${here}/../.." && pwd)}"
for f in scripts/lab.sh scripts/lib.sh; do
	[[ -f "${repo}/${f}" ]] || {
		echo "FAIL: ${repo}/${f} not found" >&2
		exit 1
	}
done

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

pf="zeo-0.9.9_p20260101"
commit="1111111111111111111111111111111111111111"

# --- the local side: a git repository, an overlay, a DISTDIR, a changelog -------
src="${tmp}/ws/zed-patches"
mkdir -p "${src}/scripts" "${src}/patches/${pf}" "${tmp}/ws/zeo"
cp "${repo}/scripts/lab.sh" "${repo}/scripts/lib.sh" "${src}/scripts/"
cat >"${src}/scripts/release-portable.sh" <<'EOS'
#!/usr/bin/env bash
# stub: record the call, honour LAB_STUB_SLEEP / LAB_STUB_RC, write a dist/
env | grep -E '^ZP_(CONTAINER_ENGINE|PORTABLE_JOBS|PORTABLE_DIR|OVERLAY|DISTDIR|REPO)=' | sort
echo "args=$*"
sleep "${LAB_STUB_SLEEP:-0}"
[[ "${LAB_STUB_RC:-0}" == 0 ]] || exit "${LAB_STUB_RC}"
dist="${ZP_PORTABLE_DIR}/$1/out/dist"
mkdir -p "${dist}"
printf 'tarball' >"${dist}/zeo-0.9.9_p20260101-x86_64.tar.xz"
(cd "${dist}" && sha256sum -- *.tar.xz >SHA256SUMS-portable-0.9.9_p20260101)
EOS
printf 'series-entry\n' >"${src}/patches/${pf}/series"
printf 'ignored\n' >"${src}/.zp-overlay"
printf '.zp-overlay\nwork/\n' >"${src}/.gitignore"
git -C "${src}" init -q
git -C "${src}" add .
git -C "${src}" -c user.name=t -c user.email=t@t commit -qm fixture
printf 'untracked patch\n' >"${src}/patches/${pf}/0124-new.patch"

printf '# Changelog\n\n## [0.9.9] — 2026-01-01\n\n- A fixture.\n' >"${tmp}/ws/zeo/CHANGELOG.md"
ov="${tmp}/overlay/app-editors/zeo"
mkdir -p "${ov}/files"
{
	echo 'EAPI=8'
	echo "EGIT_COMMIT=\"${commit}\""
	# shellcheck disable=SC2016  # ebuild syntax, verbatim
	echo 'SRC_URI="https://example.invalid/${EGIT_COMMIT}.tar.gz -> zed-${EGIT_COMMIT}.tar.gz"'
} >"${ov}/${pf}.ebuild"
printf 'DIST webrtc-m1-linux-x64-release.zip 1 BLAKE2B 0\n' >"${ov}/Manifest"
: >"${ov}/files/app-icon-zeo.png"
mkdir -p "${tmp}/distfiles"
printf 'zed' >"${tmp}/distfiles/zed-${commit}.tar.gz"
printf 'webrtc' >"${tmp}/distfiles/webrtc-m1-linux-x64-release.zip"

# the host's precheck wants podman; the stub build never calls it
mkdir -p "${tmp}/bin"
printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/podman"
chmod +x "${tmp}/bin/podman"

lab="${tmp}/lab"
lab_sh() {
	# env -u: the caller (selftest) exports ZP_REPO for this file; lab.sh must
	# resolve the fixture repository from its own location instead
	env -u ZP_REPO -u ZP_CHANGELOG -u ZP_WORKROOT -u ZP_PORTABLE_DIR -u ZP_PORTABLE_JOBS \
		PATH="${tmp}/bin:${PATH}" ZP_LAB_HOST=local ZP_LAB_ROOT="${lab}" ZP_LAB_MIN_FREE_GB=0 ZP_LAB_FETCH_DIR="${tmp}/fetched" \
		ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" \
		bash "${src}/scripts/lab.sh" "$@"
}
wait_done() {
	for _ in $(seq 1 100); do
		[[ -f "${lab}/jobs/${pf}/rc" ]] && return 0
		sleep 0.1
	done
	fail "the detached build never finished"
}

# --- a build that succeeds ------------------------------------------------------
out="$(LAB_STUB_SLEEP=1 lab_sh build "${pf}" --jobs 5)"
[[ "${out}" == *"event=started pf=${pf} jobs=5"* ]] || fail "build did not report its start: ${out}"

[[ -f "${lab}/src/zed-patches/patches/${pf}/0124-new.patch" ]] || fail "the untracked patch was not sent"
[[ ! -e "${lab}/src/zed-patches/.zp-overlay" ]] || fail "an ignored file was sent"
[[ -f "${lab}/src/zeo/CHANGELOG.md" ]] || fail "the changelog was not sent"
[[ -f "${lab}/overlay/app-editors/zeo/${pf}.ebuild" ]] || fail "the ebuild was not sent"
[[ -f "${lab}/overlay/app-editors/zeo/files/app-icon-zeo.png" ]] || fail "files/ was not sent"
[[ -f "${lab}/distfiles/zed-${commit}.tar.gz" && -f "${lab}/distfiles/webrtc-m1-linux-x64-release.zip" ]] ||
	fail "the distfiles were not sent"

set +e
lab_sh status "${pf}" >"${tmp}/st" 2>&1
st=$?
lab_sh build "${pf}" >"${tmp}/busy" 2>&1
busy=$?
set -e
if ! [[ "${st}" == 3 ]] || ! grep -q 'state=running' "${tmp}/st"; then fail "a running build is not exit 3 state=running: $(cat "${tmp}/st")"; fi
if ! [[ "${busy}" == 2 ]] || ! grep -q 'already running' "${tmp}/busy"; then fail "a second build was not refused: $(cat "${tmp}/busy")"; fi

wait_done
lab_sh status "${pf}" >"${tmp}/st" || fail "a finished build is not exit 0: $(cat "${tmp}/st")"
grep -q 'state=done' "${tmp}/st" || fail "no state=done: $(cat "${tmp}/st")"
log="$(lab_sh log "${pf}")"
for want in ZP_CONTAINER_ENGINE=podman ZP_PORTABLE_JOBS=5 "ZP_PORTABLE_DIR=${lab}/portable" \
	"ZP_OVERLAY=${lab}/overlay" "ZP_DISTDIR=${lab}/distfiles" "ZP_REPO=${lab}/src/zed-patches" \
	"args=${pf} --no-flatpak" "event=done pf=${pf} rc=0"; do
	[[ "${log}" == *"${want}"* ]] || fail "the run's log lacks ${want}"
done

out="$(lab_sh fetch "${pf}")" || fail "fetch failed: ${out}"
[[ -f "${tmp}/fetched/${pf}/zeo-0.9.9_p20260101-x86_64.tar.xz" ]] || fail "fetch brought nothing back"
printf 'tampered' >"${tmp}/fetched/${pf}/zeo-0.9.9_p20260101-x86_64.tar.xz"
printf 'tampered' >"${lab}/portable/${pf}/out/dist/zeo-0.9.9_p20260101-x86_64.tar.xz"
if lab_sh fetch "${pf}" >/dev/null 2>&1; then fail "fetch accepted a checksum mismatch"; fi

# --- a build that fails ---------------------------------------------------------
LAB_STUB_RC=1 lab_sh build "${pf}" >/dev/null
wait_done
set +e
lab_sh status "${pf}" >"${tmp}/st" 2>&1
st=$?
set -e
if ! [[ "${st}" == 1 ]] || ! grep -q 'state=failed pf=.* rc=1' "${tmp}/st"; then fail "a failed build is not exit 1 state=failed: $(cat "${tmp}/st")"; fi

# --- a build that is stopped ---------------------------------------------------
LAB_STUB_SLEEP=60 lab_sh build "${pf}" >/dev/null
sleep 0.5
out="$(lab_sh stop "${pf}")" || fail "stop failed: ${out}"
[[ "${out}" == *"event=stopped pf=${pf}"* ]] || fail "stop did not report: ${out}"
if pgrep -f "${lab}/jobs/${pf}/run.sh" >/dev/null; then fail "the runner survived stop"; fi
set +e
lab_sh status "${pf}" >"${tmp}/st" 2>&1
st=$?
set -e
if ! [[ "${st}" == 1 ]] || ! grep -q 'state=stopped' "${tmp}/st"; then fail "a stopped build is not exit 1 state=stopped: $(cat "${tmp}/st")"; fi
LAB_STUB_SLEEP=0 lab_sh build "${pf}" >/dev/null || fail "the lock was not released by stop"
wait_done
out="$(lab_sh stop "${pf}" 2>&1)" && fail "stop of a finished build succeeded: ${out}"
[[ "${out}" == *"not running"* ]] || fail "stop of a finished build did not say so: ${out}"

# --- clean, and bad input -------------------------------------------------------
lab_sh clean "${pf}" >/dev/null
[[ ! -e "${lab}/jobs/${pf}" && ! -e "${lab}/portable/${pf}" ]] || fail "clean left the version behind"
if lab_sh status "zeo-nope" >/dev/null 2>&1; then fail "a malformed PF was accepted"; fi

echo "PASS: lab.sh sends the tree, runs detached under podman, reports, fetches with checks, cleans"
