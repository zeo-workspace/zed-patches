#!/usr/bin/env bash
# Build the Zeo Windows artefacts -- a portable .zip and an Inno Setup installer, both unsigned --
# for one packaged version, in the Windows build guest (release/windows/, W3).
#
#     release-windows.sh <PF> [--remote-server <file> | --no-remote-server]
#
# Mirrors release-portable.sh, with the compile moved into the guest:
#
#   1. host   the Zed archive from DISTDIR, the release's patch selection (the default USE
#             set, release/portable/release-patches.sh), the brand art the series leaves out
#             (the PNGs from the overlay's files/ as src_prepare copies them, the .ico from
#             zeo/brand/rendered/), RELEASE_CHANNEL=zeo, and the Linux zeo-remote-server that
#             0124 looks for beside the editor -> one tarball
#   2. host   the binary inputs Zed's build would download unchecked (WebRTC, AGS, ConPTY),
#             fetched once into the cache and checked against release/windows/build-inputs.lock
#   3. guest  release/windows/build.ps1: checks the inputs again, runs Zed's bundle-windows.ps1
#             for the zeo channel (0127), assembles the zip
#   4. host   PE checks on Zeo.exe and bin\zeo.exe, SHA256SUMS-windows-<PVR>, and
#             PROVENANCE-windows-<PVR>.txt, which must carry the guest's pinned toolchain
#
# The remote server comes from, in order: --remote-server <file>; release-portable.sh's staged
# tree for this version; the portable tarball of this version's GitHub release, checked against
# its SHA256SUMS-portable. --no-remote-server builds without it (the installer then skips it,
# and SSH projects need a server installed on the host by hand).
#
# Paths: ZP_WINDOWS_DIR (default /var/tmp/zeo-win/release) holds <PF>/ -- the tree, the tarball,
# the build log and dist/; ZEO_WIN_BUILD_CACHE (default /var/tmp/zeo-win/build-inputs) the
# pinned inputs, shared by every version. ZP_CHAIN_ROOT finds zeo/ (brand art, CHANGELOG) when
# this runs from a worktree outside the hub. ZP_WINDOWS_JOBS caps cargo's jobs (default: the
# guest's processor count).
#
# ZEO_WIN_HOST=lab builds in the guest on bentoo-lab (release/windows/guest-lab.sh) instead of
# the desktop's libvirt guest. Either way the guest is started for the build and stopped after it
# (ZEO_WIN_KEEP=1 leaves it running).
#
# The guest keeps C:\zeo\src\target between runs, so a rerun recompiles little. It never
# publishes: the artefacts land in ${ZP_WINDOWS_DIR}/<PF>/dist for a human to upload.
#
# Exit: 0 written · 1 a step or a check failed · 2 environment problem.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=release/portable/release-patches.sh
source "$(dirname "${BASH_SOURCE[0]}")/../release/portable/release-patches.sh"

log() { printf 'release-windows event=%s\n' "$*"; }

main() {
	local pf="" remote_server="" no_remote_server=0
	while (($# > 0)); do
		case "$1" in
		--remote-server)
			remote_server="${2:?--remote-server needs a file}"
			shift
			;;
		--no-remote-server) no_remote_server=1 ;;
		-*) die 2 "unknown option: $1" ;;
		*) pf="$1" ;;
		esac
		shift
	done
	[[ -n "${pf}" ]] || die 2 "usage: release-windows.sh <PF> [--remote-server <file> | --no-remote-server]"
	resolve_version "${pf}"
	local chain
	chain="$(_zp_chain_root)"
	export ZP_CHANGELOG="${ZP_CHANGELOG:-${chain}/zeo/CHANGELOG.md}"
	local changelog_status=0
	bash "$(dirname "${BASH_SOURCE[0]}")/check-changelog.sh" "${pf}" || changelog_status=$?
	case "${changelog_status}" in
	0) ;;
	1) die 1 "refusing to release ${pf}: write its CHANGELOG.md section first (zeo/docs/RELEASING.md)" ;;
	*) die 2 "cannot check the changelog for ${pf}" ;;
	esac

	local pvr="${pf#zeo-}" pv
	pv="${pvr%-r[0-9]*}"
	local here="${ZP_REPO}/release/windows"
	local guest=(bash "${here}/guest.sh")
	local root="${ZP_WINDOWS_DIR:-/var/tmp/zeo-win/release}/${pf}"
	local cache="${ZEO_WIN_BUILD_CACHE:-/var/tmp/zeo-win/build-inputs}"
	local patches="${ZP_REPO}/patches/${pf}"
	local files="${ZP_OVERLAY}/${ZP_CATEGORY_PATH}/files"
	local brand="${chain}/zeo/brand"
	local jobs="${ZP_WINDOWS_JOBS:-0}"
	[[ "${jobs}" =~ ^[0-9]+$ ]] || die 2 "ZP_WINDOWS_JOBS must be a number (0: one job per guest processor), got: ${jobs}"

	[[ -f "${ZP_DISTFILE}" ]] || die 2 "Zed archive missing: ${ZP_DISTFILE} (ebuild ... fetch first)"
	[[ -f "${patches}/series" ]] || die 2 "no series: ${patches}/series"
	[[ -f "${files}/app-icon-zeo.png" && -f "${files}/app-icon-zeo@2x.png" ]] || die 2 "icons missing from ${files}"
	[[ -f "${brand}/rendered/app-icon-zeo.ico" ]] || die 2 "no ${brand}/rendered/app-icon-zeo.ico (zeo/brand/build-ico.sh)"
	(cd "${brand}" && grep -E '  rendered/app-icon-zeo\.ico$' checksums.txt | sha256sum --check --status) ||
		die 1 "app-icon-zeo.ico does not match zeo/brand/checksums.txt"
	command -v python3 >/dev/null || die 2 "python3 is required for the PE checks"
	# The guest runs only for the build: started here, stopped on the way out, so on the lab its
	# slot reservation lasts exactly as long as the build. ZEO_WIN_KEEP=1 leaves it running.
	"${guest[@]}" start || die 2 "the guest did not start (release/windows/guest.sh status)"
	if [[ "${ZEO_WIN_KEEP:-0}" != 1 ]]; then
		# shellcheck disable=SC2064 # guest is fixed by now; expand it here.
		trap "${guest[*]} stop || true" EXIT
	fi
	"${guest[@]}" ssh "if (-not (Test-Path 'C:\\Program Files\\PowerShell\\7\\pwsh.exe')) { exit 3 }" ||
		die 2 "the guest lacks PowerShell 7 (release/windows/guest.sh provision)"

	mkdir -p "${root}" "${cache}"
	local inputs=() n url sum
	while IFS=$'\t' read -r n url sum; do
		[[ "${n}" =~ ^[[:space:]]*(#|$) ]] && continue
		if [[ ! -f "${cache}/${n}" ]]; then
			curl -fsSL --retry 3 -o "${cache}/${n}.part" "${url}" || die 1 "downloading ${n} failed"
			mv "${cache}/${n}.part" "${cache}/${n}"
		fi
		echo "${sum}  ${cache}/${n}" | sha256sum --check --status || die 1 "hash mismatch: ${n}"
		inputs+=("${cache}/${n}")
	done <"${here}/build-inputs.lock"
	log "inputs-checked count=${#inputs[@]}"

	local server_origin="absent"
	if ((! no_remote_server)); then
		remote_server="$(find_remote_server "${pvr}" "${remote_server}" "${root}")" || exit $?
		server_origin="${remote_server}"
	fi

	log "preparing-tree dir=${root}/src"
	local src="${root}/src"
	rm -rf "${src}"
	mkdir -p "${src}"
	tar -xzf "${ZP_DISTFILE}" -C "${src}" --strip-components=1
	local applied=() patch
	while IFS= read -r patch; do
		(cd "${src}" && patch -p1 --no-backup-if-mismatch --quiet <"${patches}/${patch}") ||
			die 1 "${patch} does not apply"
		applied+=("${patch}")
	done < <(release_patches "${patches}/series")
	log "series-applied count=${#applied[@]}"
	cp "${files}/app-icon-zeo.png" "${files}/app-icon-zeo@2x.png" "${src}/crates/zed/resources/"
	cp "${brand}/rendered/app-icon-zeo.ico" "${src}/crates/zed/resources/windows/"
	echo "zeo" >"${src}/crates/zed/RELEASE_CHANNEL"
	if ((! no_remote_server)); then
		# zed.iss installs it beside Zeo.exe when the resources directory carries it (0127).
		install -m 0755 "${remote_server}" "${src}/crates/zed/resources/windows/zeo-remote-server"
	fi
	# Seconds here instead of a failed compile in the guest: Linux never runs sql!'s SQLite check.
	python3 -I "${ZP_REPO}/scripts/check-sql-tokens.py" "${src}" ||
		die 1 "a sql!/query! body has a numeric literal glued to an identifier (list above)"
	tar -czf "${root}/src.tar.gz" -C "${src}" .

	log "uploading"
	# target\ survives a rerun; everything else in the guest's tree is replaced.
	"${guest[@]}" ssh "New-Item -ItemType Directory -Force -Path C:\\zeo\\src, C:\\zeo\\inputs | Out-Null; Get-ChildItem C:\\zeo\\src -Force | Where-Object Name -ne 'target' | Remove-Item -Recurse -Force; Get-ChildItem C:\\zeo\\inputs -Force | Remove-Item -Recurse -Force" ||
		die 1 "clearing the guest's tree failed"
	"${guest[@]}" put C:/zeo/inputs "${root}/src.tar.gz" "${here}/build.ps1" "${here}/build-inputs.lock" "${inputs[@]}"
	"${guest[@]}" ssh "tar.exe -xzf C:\\zeo\\inputs\\src.tar.gz -C C:\\zeo\\src; if (\$LASTEXITCODE) { exit 1 }" ||
		die 1 "unpacking the tree in the guest failed"

	log "building jobs=${jobs} log=${root}/build.log"
	local status=0
	"${guest[@]}" ssh "& 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File C:\\zeo\\inputs\\build.ps1 -Src C:\\zeo\\src -Inputs C:\\zeo\\inputs -Out C:\\zeo\\out -Version ${pv} -Pvr ${pvr} -Commit ${ZP_COMMIT} -Jobs ${jobs}; exit \$LASTEXITCODE" 2>&1 |
		tee "${root}/build.log" || status=$?
	((status == 0)) || die 1 "the guest build failed (exit ${status}); see ${root}/build.log"

	local dist="${root}/dist"
	rm -rf "${dist}"
	mkdir -p "${dist}"
	"${guest[@]}" get "C:/zeo/out/*" "${dist}"
	local zip="zeo-${pvr}-windows-x86_64.zip" setup="Zeo-${pvr}-x86_64-setup.exe"
	[[ -s "${dist}/${zip}" && -s "${dist}/${setup}" && -s "${dist}/build-info.txt" ]] ||
		die 1 "the guest returned no ${zip}, ${setup} or build-info.txt"
	check_artefacts "${dist}/${zip}" "${no_remote_server}"

	write_provenance "${dist}" "${pf}" "${pvr}" "${server_origin}" "${applied[@]}"
	mv "${dist}/build-info.txt" "${root}/build-info.txt"
	(cd "${dist}" && sha256sum -- "${zip}" "${setup}" "PROVENANCE-windows-${pvr}.txt" >"SHA256SUMS-windows-${pvr}")
	printf '\nartefacts in %s:\n' "${dist}"
	ls -la "${dist}"
}

# find_remote_server <pvr> <given> <root> -- print the Linux zeo-remote-server to bundle.
find_remote_server() {
	local pvr=$1 given=$2 root=$3
	if [[ -n "${given}" ]]; then
		[[ -f "${given}" ]] || die 2 "no such file: ${given}"
		printf '%s' "${given}"
		return 0
	fi
	local staged="${ZP_PORTABLE_DIR:-${HOME}/.cache/zeo-portable}/zeo-${pvr}/out/zeo-${pvr}/usr/libexec/zeo-remote-server"
	if [[ -f "${staged}" ]]; then
		printf '%s' "${staged}"
		return 0
	fi
	command -v gh >/dev/null || die 2 "no staged remote server and no gh to fetch the release's"
	local dl="${root}/portable"
	mkdir -p "${dl}"
	gh release download "v${pvr}" -R zeo-workspace/zeo --dir "${dl}" --clobber \
		-p "zeo-${pvr}-x86_64.tar.xz" -p "SHA256SUMS-portable-${pvr}" >&2 ||
		die 2 "release v${pvr} has no portable tarball; pass --remote-server or --no-remote-server"
	(cd "${dl}" && grep -E "  zeo-${pvr//./\\.}-x86_64\\.tar\\.xz\$" "SHA256SUMS-portable-${pvr}" | sha256sum --check --status) ||
		die 1 "the portable tarball does not match its SHA256SUMS"
	tar -xJf "${dl}/zeo-${pvr}-x86_64.tar.xz" -C "${dl}" "zeo-${pvr}/usr/libexec/zeo-remote-server" ||
		die 1 "the portable tarball has no usr/libexec/zeo-remote-server"
	printf '%s' "${dl}/zeo-${pvr}/usr/libexec/zeo-remote-server"
}

# check_artefacts <zip> <no_remote_server> -- the zip holds what the installer installs,
# and its executables are x86-64 PE files of the right subsystem: Zeo.exe a GUI program, the
# CLI a console one.
check_artefacts() {
	local zip=$1 no_remote_server=$2
	python3 -I - "${zip}" "${no_remote_server}" <<'EOF' || die 1 "the Windows artefacts failed their checks"
import struct, sys, zipfile

zip_path, no_server = sys.argv[1], sys.argv[2] == "1"
z = zipfile.ZipFile(zip_path)
names = {n.replace("\\", "/") for n in z.namelist()}
need = ["Zeo.exe", "bin/zeo.exe", "bin/zeo", "conpty.dll", "amd_ags_x64.dll", "x64/OpenConsole.exe"]
if not no_server:
    need.append("zeo-remote-server")
missing = [n for n in need if n not in names]
if missing:
    sys.exit(f"missing from the zip: {missing}")

def pe(name, want_subsystem):
    data = z.read(name)
    if data[:2] != b"MZ":
        sys.exit(f"{name}: not a PE file")
    off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[off:off + 4] != b"PE\0\0":
        sys.exit(f"{name}: no PE signature")
    machine = struct.unpack_from("<H", data, off + 4)[0]
    # Optional header follows the 20-byte COFF header; Subsystem sits at offset 68 in PE32+.
    subsystem = struct.unpack_from("<H", data, off + 24 + 68)[0]
    if machine != 0x8664:
        sys.exit(f"{name}: machine {machine:#x}, not x86-64")
    if subsystem != want_subsystem:
        sys.exit(f"{name}: subsystem {subsystem}, wanted {want_subsystem}")
    print(f"release-windows event=pe-ok file={name} machine=x86-64 subsystem={subsystem}")

pe("Zeo.exe", 2)      # IMAGE_SUBSYSTEM_WINDOWS_GUI
pe("bin/zeo.exe", 3)  # IMAGE_SUBSYSTEM_WINDOWS_CUI
if not no_server:
    elf = z.read("zeo-remote-server")[:20]
    if elf[:4] != b"\x7fELF" or struct.unpack_from("<H", elf, 18)[0] != 0x3E:
        sys.exit("zeo-remote-server: not an x86-64 ELF")
    print("release-windows event=elf-ok file=zeo-remote-server")
EOF
}

# write_provenance <dist> <pf> <pvr> <server-origin> <patch>... -- PROVENANCE-windows-<pvr>.txt.
# Refuses a build-info.txt that lacks any of the guest's pinned toolchain entries: an artefact
# whose toolchain cannot be named is not one to publish.
write_provenance() {
	local dist=$1 pf=$2 pvr=$3 origin=$4
	shift 4
	local info="${dist}/build-info.txt" key
	for key in windows visual-studio msvc windows-sdk rustc powershell cargo-about inno-setup cli-version; do
		grep -q "^${key}=." "${info}" || die 1 "build-info.txt has no ${key}= line: the guest toolchain is not the pinned one (guest.sh provision)"
	done
	{
		printf 'Zeo %s for Windows x86_64, unsigned.\n\n' "${pvr}"
		printf 'package        %s\n' "${pf}"
		printf 'zed commit     %s\n' "${ZP_COMMIT}"
		printf 'zed archive    %s  %s\n' "$(sha256sum "${ZP_DISTFILE}" | cut -d' ' -f1)" "${ZP_DISTFILE##*/}"
		# Where it came from, named by artefact: a path on the build host means nothing to a
		# reader of a published PROVENANCE, and the first one leaked a home directory.
		local label
		case "${origin}" in
		absent) label="" ;;
		*/portable/zeo-*/usr/libexec/zeo-remote-server) label="usr/libexec/zeo-remote-server of zeo-${pvr}-x86_64.tar.xz (release v${pvr})" ;;
		*/zeo-portable/*) label="usr/libexec/zeo-remote-server of release-portable.sh's staged tree for ${pf}" ;;
		*) label="${origin##*/} (--remote-server)" ;;
		esac
		if [[ -z "${label}" ]]; then
			printf 'remote server  absent (--no-remote-server)\n'
		else
			printf 'remote server  %s  %s\n' "$(sha256sum "${origin}" | cut -d' ' -f1)" "${label}"
		fi
		printf '\n# Build inputs (release/windows/build-inputs.lock)\n'
		grep -vE '^[[:space:]]*(#|$)' "${ZP_REPO}/release/windows/build-inputs.lock" | awk -F'\t' '{ print $3 "  " $1 }'
		printf '\n# Guest build (build-info.txt)\n'
		sed 's/\r$//' "${info}"
		printf '\n# Patches applied (%d)\n' "$#"
		printf '%s\n' "$@"
	} >"${dist}/PROVENANCE-windows-${pvr}.txt"
}

main "$@"
