#!/usr/bin/env bash
# Runs inside the portable build image (Containerfile). Mirrors what the
# app-editors/zeo ebuild does in src_prepare/src_compile/src_install, minus the
# Portage-only parts (offline git-crate rewrites: cargo fetches here).
#
# Inputs (read-only mounts):  /in/zed.tar.gz  /in/patches/{series,*.patch}
#                             /in/icons/app-icon-zeo{,@2x}.png  /in/webrtc.zip
# Cache (read-write):         /work   -- source tree and cargo target, this version's
#                             /cargo-home, /sccache -- shared by every version
# Output:                     /out/zeo-<PVR>/usr/...
# Environment:                ZEO_PV (e.g. 0.1.0_p20261003), ZEO_PVR (+ -rN),
#                             ZEO_COMMIT and ZEO_SOURCE_SHA256 (for PROVENANCE.txt)
set -euo pipefail

: "${ZEO_PV:?}" "${ZEO_PVR:?}" "${ZEO_COMMIT:?}" "${ZEO_SOURCE_SHA256:?}"
readonly src=/work/src stage="/out/zeo-${ZEO_PVR}"
readonly max_glibc=2.36

log() { printf '[portable] %s\n' "$*"; }

log "unpacking Zed"
rm -rf "${src}"
mkdir -p "${src}"
tar -xzf /in/zed.tar.gz -C "${src}" --strip-components=1

# release_patches -- the series as the release ships it: every group the
# package's default USE set enables. That is every group except `test` (tests
# only, applied by the ebuild under USE=test) and every group whose `@feature`
# line is followed by a `# @default: off` marker (its USE flag is off by
# default, e.g. ai-jail). The marker belongs to the group above it and is reset
# at the next `@feature`. Same order as the series.
release_patches() {
	local line group="" default_off=0
	while IFS= read -r line; do
		if [[ "${line}" =~ ^#[[:space:]]*@feature:[[:space:]]*([^[:space:]]+) ]]; then
			group="${BASH_REMATCH[1]}"
			default_off=0
			continue
		fi
		if [[ "${line}" =~ ^#[[:space:]]*@default:[[:space:]]*off[[:space:]]*$ ]]; then
			default_off=1
			continue
		fi
		[[ -z "${line}" || "${line}" == \#* || "${group}" == test ]] && continue
		((default_off)) && continue
		printf '%s\n' "${line}"
	done < /in/patches/series
}

log "applying the series"
cd "${src}"
n=0
while IFS= read -r patch; do
	patch -p1 --no-backup-if-mismatch --quiet < "/in/patches/${patch}"
	n=$((n + 1))
done < <(release_patches)
log "${n} patches applied"

# src_prepare: icons, release channel, desktop entry -- byte for byte the edits
# the ebuild makes, so a .deb and the Gentoo package carry the same entry.
cp /in/icons/app-icon-zeo.png /in/icons/app-icon-zeo@2x.png crates/zed/resources/
echo "zeo" > crates/zed/RELEASE_CHANNEL
export APP_CLI="zeo" APP_ID="dev.zeo.Zeo" APP_ICON="dev.zeo.Zeo" APP_NAME="Zeo" \
	APP_ARGS="%U" DO_STARTUP_NOTIFY="true"
envsubst < crates/zed/resources/zed.desktop.in > "${APP_ID}.desktop"
sed -i "/^Actions=/i StartupWMClass=${APP_ID}" "${APP_ID}.desktop"
sed -i "s|x-scheme-handler/zed|x-scheme-handler/zeo|" "${APP_ID}.desktop"
sed -i "s|^Keywords=zed;|Keywords=zeo;zed;|" "${APP_ID}.desktop"
desktop-file-validate "${APP_ID}.desktop"

log "unpacking the prebuilt WebRTC the ebuild uses"
rm -rf /work/webrtc
mkdir -p /work/webrtc
unzip -q /in/webrtc.zip -d /work/webrtc

# src_compile. RUSTFLAGS replaces .cargo/config.toml's rustflags instead of adding
# to them, so Zed's own two flags are repeated here next to the CPU target.
export RELEASE_VERSION="${ZEO_PV}" RELEASE_CHANNEL="zeo"
export ZED_UPDATE_EXPLANATION="Update Zeo where you installed it: your package manager, Flatpak, or a new AppImage from https://github.com/zeo-workspace/zeo/releases"
export LK_CUSTOM_WEBRTC=/work/webrtc/linux-x64-release
export RUSTFLAGS="-C target-cpu=x86-64-v3 -C symbol-mangling-version=v0 --cfg tokio_unstable"
export CFLAGS="-O2 -march=x86-64-v3" CXXFLAGS="-O2 -march=x86-64-v3"
# clang, as upstream's script/bundle-linux uses: Debian 12's GCC 12 rejects the
# prebuilt WebRTC headers ("declaration ... changes meaning of 'Network'"), and
# the -Wno-changes-meaning that webrtc-sys passes to silence it only exists from
# GCC 13 on. The diagnostic is GCC's alone.
export CC=clang CXX=clang++
export CARGO_TARGET_DIR=/work/target CARGO_HOME=/cargo-home
# sccache keys every entry on the exact rustc, so it only ever hits entries this
# image wrote -- which is why it is a cache of its own and not Portage's
# /var/cache/sccache (also unreadable here: its entries are mode 0600, portage's).
# The paths in the key (/work/src, /cargo-home) are the same for every version.
export RUSTC_WRAPPER=sccache SCCACHE_DIR=/sccache SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-30G}"
# Voice input (0067) compiles whisper.cpp through whisper-rs-sys, whose build.rs
# hands every GGML_*/WHISPER_* variable to CMake. GGML_NATIVE=OFF keeps ggml off
# -march=native (the build machine's CPU) and switches on its fixed x86-64-v3
# set instead: AVX, AVX2, FMA, F16C, BMI2, no AVX-512. WHISPER_DONT_GENERATE_BINDINGS
# uses the crate's bundled bindings, so no bindgen run on this machine decides
# them. ZEO_VOICE_CPU_BASELINE is read by voice_input at compile time (option_env!).
# GGML_CCACHE=OFF: ggml would otherwise wrap the C/C++ compiler with the ccache or
# sccache it finds (sccache is in this image), outside the build's own caching.
readonly voice_env="GGML_NATIVE=OFF GGML_CCACHE=OFF WHISPER_DONT_GENERATE_BINDINGS=1 ZEO_VOICE_CPU_BASELINE=x86-64-v3"
export GGML_NATIVE=OFF GGML_CCACHE=OFF WHISPER_DONT_GENERATE_BINDINGS=1 ZEO_VOICE_CPU_BASELINE=x86-64-v3
# whisper-rs-sys's build.rs reruns only when its wrapper.h changes, not when the
# environment does, so a persistent /work/target would keep the CMake flags of
# whichever build ran first. Cleaning that one package forces its CMake run.
# A series without the voice group has no whisper-rs-sys to clean or to check.
# --locked: `cargo clean -p` resolves the workspace and would otherwise rewrite a
# stale Cargo.lock, which the --locked build below would then accept.
voice=0
grep -qx 'name = "whisper-rs-sys"' Cargo.lock && voice=1
if ((voice)); then
	log "voice input: ${voice_env}"
	cargo clean --locked --release --package whisper-rs-sys
fi
sccache --zero-stats >/dev/null
log "building (cargo build --release --locked)"
cargo build --release --locked --package zed --package cli --features zed/mimalloc
# The CMake cache is what whisper.cpp was really configured with: there must be
# one, and every one found must say NATIVE, AVX-512 and the runtime-dispatched
# CPU variants are all off, and ggml has no ccache wrapper. build.rs forwards any GGML_* in the environment, so
# a stray GGML_AVX512=ON or GGML_CPU_ALL_VARIANTS=ON would reach CMake.
if ((voice)); then
	shopt -s nullglob
	caches=("${CARGO_TARGET_DIR}"/release/build/whisper-rs-sys-*/out/build/CMakeCache.txt)
	shopt -u nullglob
	if ((${#caches[@]} == 0)); then
		echo "error: no whisper.cpp CMakeCache.txt under ${CARGO_TARGET_DIR}/release/build" >&2
		exit 1
	fi
	for cache in "${caches[@]}"; do
		for setting in GGML_NATIVE GGML_AVX512 GGML_CPU_ALL_VARIANTS GGML_CCACHE; do
			if ! grep -q "^${setting}:BOOL=OFF\$" "${cache}"; then
				echo "error: whisper.cpp was not configured with ${setting}=OFF: ${cache}" >&2
				exit 1
			fi
		done
	done
	log "whisper.cpp CMakeCache: GGML_NATIVE, GGML_AVX512, GGML_CPU_ALL_VARIANTS, GGML_CCACHE :BOOL=OFF (${#caches[@]} checked)"
fi
sccache --show-stats | grep -E '^(Compile requests|Cache hits|Cache misses|Cache size)' |
	sed 's/^/[portable] sccache: /'
sccache --stop-server >/dev/null

# AVX-512, checked on the unstripped binary so each instruction has a function
# name. Hand-written assembly kernels that pick an AVX-512 path at run time
# (dav1d, aws-lc, and WebRTC's BoringSSL and libyuv) carry it on purpose and
# never run it on a CPU without it; they have plain C names and are exempt.
# Compiler-generated code does not check, so one Rust (_R), C++ (_Z, any form)
# or whisper.cpp (ggml_/whisper_/gguf_, plain C names) function using it
# means the binary dies with SIGILL on a CPU below AVX-512. That is exactly what
# Gentoo's zeo-bin shipped until 0.1.0_p20261003-r1: the host's Rust standard
# library was built for znver5. The whole disassembly is read (awk, no grep -q),
# because `objdump | grep -q` under pipefail reported 141 from SIGPIPE and the
# old check passed every time.
log "checking for compiler-generated AVX-512"
avx512_fns="$(objdump -d --no-show-raw-insn /work/target/release/zeo | awk '
	/^[0-9a-f]+ <.*>:$/ { fn = $2 }
	/%zmm[0-9]|\{%k[1-7]\}/ { if (fn ~ /^<(_R|_Z|ggml_|whisper_|gguf_)/) bad[fn] = 1 }
	END { for (f in bad) print f }')"
if [[ -n "${avx512_fns}" ]]; then
	echo "error: compiler-generated code uses AVX-512 (would SIGILL below AVX-512):" >&2
	printf '%s\n' "${avx512_fns}" | head -20 >&2
	exit 1
fi

# src_install, into a staging tree laid out like zeo-bin's.
log "staging ${stage}"
rm -rf "${stage}"
install -Dm755 /work/target/release/cli "${stage}/usr/bin/zeo"
install -Dm755 /work/target/release/zeo "${stage}/usr/libexec/zeo-editor"
install -Dm644 "${APP_ID}.desktop" "${stage}/usr/share/applications/${APP_ID}.desktop"
install -Dm644 crates/zed/resources/app-icon-zeo.png \
	"${stage}/usr/share/icons/hicolor/512x512/apps/${APP_ID}.png"
install -Dm644 crates/zed/resources/app-icon-zeo@2x.png \
	"${stage}/usr/share/icons/hicolor/1024x1024/apps/${APP_ID}.png"
strip --strip-unneeded "${stage}/usr/bin/zeo" "${stage}/usr/libexec/zeo-editor"

# The point of this build: refuse a binary that needs a newer glibc than the
# oldest distribution it claims.
for bin in "${stage}/usr/bin/zeo" "${stage}/usr/libexec/zeo-editor"; do
	need="$(objdump -T "${bin}" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
	if [[ "$(printf '%s\n%s\n' "${need}" "${max_glibc}" | sort -V | tail -1)" != "${max_glibc}" ]]; then
		echo "error: ${bin##*/} needs glibc ${need}, above ${max_glibc}" >&2
		exit 1
	fi
	log "${bin##*/}: highest glibc symbol ${need}"
done

# PROVENANCE.txt, in the format zeo-bin has always carried, naming this build's
# real toolchain instead of the Gentoo one.
{
	printf 'zeo %s -- provenance\n\n' "${ZEO_PVR}"
	printf 'built from     zed-patches release/portable (Debian 12 container), series zeo-%s\n' "${ZEO_PVR}"
	printf 'zeo version    %s (CHANGELOG.md section)\n' "${ZEO_PV%%_p*}"
	printf 'zed version    %s\n' "$(grep -m1 '^version' crates/zed/Cargo.toml | cut -d'"' -f2)"
	printf 'zed commit     %s\n' "${ZEO_COMMIT}"
	printf 'zed source     https://github.com/zed-industries/zed/archive/%s.tar.gz\n' "${ZEO_COMMIT}"
	printf 'source sha256  %s\n' "${ZEO_SOURCE_SHA256}"
	printf 'features       zed/mimalloc\n'
	printf 'rustc          %s (official toolchain, rustup)\n' "$(rustc --version)"
	printf 'cc / c++       %s\n' "$(clang --version | head -1)"
	printf 'CFLAGS         %s\n' "${CFLAGS}"
	printf 'RUSTFLAGS      %s\n' "${RUSTFLAGS}"
	if ((voice)); then
		printf 'whisper.cpp    %s (CMakeCache: GGML_NATIVE, GGML_AVX512, GGML_CPU_ALL_VARIANTS, GGML_CCACHE OFF)\n' "${voice_env}"
	fi
	printf 'glibc          needs %s at most (ceiling checked: %s)\n\n' \
		"$(objdump -T "${stage}/usr/libexec/zeo-editor" "${stage}/usr/bin/zeo" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -Vu | tail -1)" \
		"${max_glibc}"
	printf 'patches, in apply order (sha256):\n'
	while IFS= read -r patch; do
		printf '  %s  %s\n' "$(sha256sum "/in/patches/${patch}" | cut -d' ' -f1)" "${patch}"
	done < <(release_patches)
	printf '\nNEEDED (usr/libexec/zeo-editor):\n'
	objdump -p "${stage}/usr/libexec/zeo-editor" | awk '/NEEDED/ { print "  " $2 }'
	printf '\nThe Corresponding Source is the zed source above plus these patches,\n'
	printf 'published in the bentoo overlay under app-editors/zeo/files/.\n'
} > "${stage}/PROVENANCE.txt"
log "done"
