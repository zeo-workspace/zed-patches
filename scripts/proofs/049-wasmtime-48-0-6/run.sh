#!/usr/bin/env bash
# Story 049, task 4.1 — WebAssembly extensions and HTTPS still work on wasmtime 48.0.6 and
# rustls 0.23.46 (E2E).
#
#     run.sh --out <docs/assets/049-live-proof-DATE> [--binary <zeo-editor>] [--extension <dir>]
#            [--probe <extension id>] [--corrupt-wasm]
#
# What it proves (R4.1, R4.2, R4.5; Q11): a Zeo built from the patched tree, in an isolated
# --user-data-dir under a fresh mktemp dir (never the operator's profile), loads a COPY of the
# html extension (extension.wasm + grammars/html.wasm), opens an .html file, and the extension's
# WebAssembly is invoked -- vscode-html-language-server is requested, which only the extension's
# wasm can answer -- with no panic and no wasm compile/instantiate/load error in the log. A failed
# language-server download is the extension having run, not a failure.
#
# HTTPS (R4.5): the settings ask Zeo to auto-install a second, small extension (--probe, default
# toml). Zeo fetches it from the extension registry over HTTPS with its own client (rustls), so
# the probe landing in installed/ and in the extension index is a request that COMPLETED, not one
# that was only attempted. ZED_LOG raises rustls to debug, so the log must also show a negotiated
# TLS session, and no TLS error or alert (close_notify, the normal end of a connection, excepted).
#
# html itself is neither auto-installed nor auto-updated: a fresh download would replace the copy
# under test -- and would hide --corrupt-wasm. The run checks the file it tested is the one it put.
#
# Red is deferred to the run: --corrupt-wasm replaces the copy's extension.wasm with bytes that
# are not a component; the run must then exit 1.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager, real network. Not
# covered: Wayland, GPU, the highlight colours themselves (read from the capture by a human,
# recorded in the README), TLS to any host but the extension registry.
#
# Exit: 0 proven · 1 a check failed · 2 environment problem.

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run.sh: %s\n' "$*" >&2
	exit "${code}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
BINARY="/usr/libexec/zeo-editor"
EXT="${HOME}/.local/share/zeo/extensions/installed/html"
PROBE="toml"
OUT=""
CORRUPT=0
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--extension) EXT="${2:-}" && shift ;;
	--probe) PROBE="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--corrupt-wasm) CORRUPT=1 ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${OUT}" ]] || die 2 "--out <dir> is required"
[[ "${PROBE}" =~ ^[a-z0-9-]+$ && "${PROBE}" != "html" ]] || die 2 "--probe must be an extension id other than html: ${PROBE}"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
[[ -x "${BINARY}" ]] || die 2 "the editor is not executable: ${BINARY}"
[[ -f "${EXT}/extension.wasm" && -f "${EXT}/grammars/html.wasm" ]] ||
	die 2 "not a WebAssembly extension with a WebAssembly grammar: ${EXT}"
command -v jq >/dev/null || die 2 "jq is not on PATH"
getent hosts api.zed.dev >/dev/null || die 2 "api.zed.dev does not resolve: the HTTPS check needs the network"

ROOT="$(mktemp -d /tmp/z49.XXXXXX)"
trap 'rm -rf -- "${ROOT}"' EXIT
PROFILE="${ROOT}/p"
PROJ="${ROOT}/proj"
mkdir -p "${PROFILE}/extensions/installed" "${PROJ}" "${OUT}"
cp -a -- "${EXT}" "${PROFILE}/extensions/installed/html"
if ((CORRUPT)); then
	printf 'not a wasm component\n' >"${PROFILE}/extensions/installed/html/extension.wasm"
fi
cp -- "${PROFILE}/extensions/installed/html/extension.wasm" "${ROOT}/expected.wasm"
cat >"${PROJ}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head><title>049</title></head>
  <body><p class="note">wasmtime 48.0.6, rustls 0.23.46</p></body>
</html>
HTML
jq -n --arg probe "${PROBE}" '{
	"use_system_path_prompts": false,
	"session": {"trust_all_worktrees": true},
	"auto_install_extensions": {"html": false, ($probe): true},
	"auto_update_extensions": {"html": false}
}' >"${ROOT}/settings.json"
jq -n --arg proj "${PROJ}/" --arg out "${OUT}" '[
	{"sleep": 10}, {"shot": ($out + "/049-0-started.png")},
	{"chord": ["ctrl", "o"]}, {"sleep": 2}, {"type": $proj}, {"key": ["Return"]}, {"sleep": 5},
	{"chord": ["ctrl", "p"]}, {"sleep": 2}, {"type": "index.html"}, {"key": ["Return"]}, {"sleep": 20},
	{"shot": ($out + "/049-1-index-html.png")}
]' >"${ROOT}/steps.json"

"${HARNESS}" --dry-run --steps "${ROOT}/steps.json" >/dev/null || die 2 "xvfb-proof.sh refused the steps"
status=0
# zlog reads ZED_LOG; the harness passes the environment through to Zeo.
ZED_LOG="info,rustls=debug" "${HARNESS}" --binary "${BINARY}" --settings "${ROOT}/settings.json" \
	--keep "${PROFILE}" --steps "${ROOT}/steps.json" || status=$?
((status == 0)) || die 2 "xvfb-proof.sh exited ${status}"

LOG="${OUT}/zeo-log.txt"
cat -- "${PROFILE}/zeo.log" "${PROFILE}"/logs/*.log >"${LOG}" 2>/dev/null || true
[[ -s "${LOG}" ]] || die 2 "no log was written under ${PROFILE}"

fail=0
check() {
	if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "${LABEL}"; else printf 'FAIL %s\n' "${LABEL}"; fail=1; fi
}
absent() { ! grep -qiE "$1" "$2"; }
tls_clean() { ! grep -viE 'CloseNotify' "$1" | grep -qiE '(tls|ssl).*(error|alert|fail)|alert received|InvalidCertificate'; }
LABEL="no panic in the log" check absent 'panic' "${LOG}"
LABEL="no wasm compile, instantiate or extension/language load error" check absent \
	'failed to compile wasm component|failed to instantiate|failed to load extension|failed to load language|wasm trap|wasmtime.*error' "${LOG}"
LABEL="the html extension is indexed" check jq -e '.extensions.html' "${PROFILE}/extensions/index.json"
LABEL="the extension tested is the copy this run placed" check cmp -s "${ROOT}/expected.wasm" \
	"${PROFILE}/extensions/installed/html/extension.wasm"
LABEL="the extension's wasm was asked for its language server" check grep -q 'vscode-html-language-server' "${LOG}"
LABEL="the ${PROBE} download was requested" check grep -q "installing extension ${PROBE} latest version" "${LOG}"
# shellcheck disable=SC2016 # $p is a jq variable, not a shell one
LABEL="an HTTPS request completed: ${PROBE} was downloaded and indexed" check jq -e --arg p "${PROBE}" \
	'.extensions[$p]' "${PROFILE}/extensions/index.json"
LABEL="rustls negotiated a TLS session" check grep -qE 'Using ciphersuite|TLS1\.3 encrypted extensions' "${LOG}"
LABEL="no TLS error or alert in the log" check tls_clean "${LOG}"
LABEL="both captures exist" check test -s "${OUT}/049-0-started.png" -a -s "${OUT}/049-1-index-html.png"

if ((fail)); then
	printf 'run.sh: NOT proven (log: %s)\n' "${LOG}"
	exit 1
fi
printf 'run.sh: proven -- captures and log in %s\n' "${OUT}"
