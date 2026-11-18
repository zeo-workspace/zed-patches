#!/usr/bin/env bash
# Build the answers ISO for the Zeo Windows build guest.
#
#     release/windows/build-answers.sh <out.iso> [--edition "Windows 11 Home"]
#
# Home by default: the operator's licence key is a Home key (2026-11-17), and the edition must
# match the key for activation. Any edition builds Zeo.
#
# The ISO carries autounattend.xml (rendered from autounattend.xml.in), setup-ssh.ps1, the
# Win32-OpenSSH MSI from inputs.lock (checked by sha256) and this guest's public ssh key.
# Windows Setup finds autounattend.xml on any attached CD by itself.
#
# Secrets stay in ${ZEO_WIN_CONFIG:-~/.config/zeo-win} (0700): the guest's ssh key pair and the
# builder account's random password, made on the first run and reused after. They reach the ISO,
# which lives in the libvirt pool, never a repository.
#
# Exit: 0 written · 1 an input failed its hash · 2 environment problem.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:?usage: build-answers.sh <out.iso> [--edition NAME]}"
edition="Windows 11 Home"
if [[ "${2:-}" == --edition ]]; then
	edition="${3:?--edition needs a name}"
fi
# Microsoft's generic installation keys (published for exactly this): they pick the edition
# and activate nothing. Without one, Setup stops at the key page -- seen 2026-11-17.
case "${edition}" in
"Windows 11 Home") generic_key="YTMG3-N6DKC-DKB77-7M9GH-8HVX7" ;;
"Windows 11 Pro") generic_key="VK7JG-NPHTM-C97JM-9MPGT-3V66T" ;;
*)
	echo "build-answers event=unknown-edition edition=\"${edition}\"" >&2
	exit 2
	;;
esac
config="${ZEO_WIN_CONFIG:-${HOME}/.config/zeo-win}"
cache="${ZEO_WIN_CACHE:-/var/tmp/zeo-win/inputs}"

for tool in curl sha256sum xorriso ssh-keygen openssl; do
	command -v "${tool}" >/dev/null || {
		echo "build-answers event=missing-tool tool=${tool}" >&2
		exit 2
	}
done

install -d -m 0700 "${config}"
install -d "${cache}"
[[ -f "${config}/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C zeo-win-builder -f "${config}/id_ed25519"
if [[ ! -f "${config}/password" ]]; then
	(umask 077 && openssl rand -base64 24 | tr -d '/+=' >"${config}/password")
fi

# fetch <name>: the inputs.lock entry, downloaded once into the cache and checked every time.
fetch() {
	local name="$1" url sum
	read -r url sum < <(awk -F'\t' -v n="${name}" '$1 == n { print $2, $3 }' "${here}/inputs.lock")
	[[ -n "${url:-}" ]] || {
		echo "build-answers event=not-locked name=${name}" >&2
		exit 2
	}
	[[ -f "${cache}/${name}" ]] || curl -fsSL --retry 3 -o "${cache}/${name}.part" "${url}"
	[[ -f "${cache}/${name}.part" ]] && mv "${cache}/${name}.part" "${cache}/${name}"
	if ! echo "${sum}  ${cache}/${name}" | sha256sum --check --status; then
		echo "build-answers event=hash-mismatch name=${name} expected=${sum}" >&2
		exit 1
	fi
	echo "${sum}"
}

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

msi_sum="$(fetch OpenSSH-Win64.msi)"
cp "${cache}/OpenSSH-Win64.msi" "${stage}/"
echo "${msi_sum}  OpenSSH-Win64.msi" >"${stage}/OpenSSH-Win64.msi.sha256"
cp "${here}/setup-ssh.ps1" "${stage}/"
cp "${config}/id_ed25519.pub" "${stage}/authorized_key.pub"

# The password goes in through a file, not argv, so no process listing shows it.
python3 -I - "${here}/autounattend.xml.in" "${stage}/autounattend.xml" "${edition}" "${config}/password" "${generic_key}" <<'EOF'
import sys
from xml.sax.saxutils import escape
template, target, edition, password_file, generic_key = sys.argv[1:]
password = open(password_file).read().strip()
text = open(template).read()
text = (text.replace("@EDITION@", escape(edition)).replace("@PASSWORD@", escape(password))
        .replace("@GENERIC_KEY@", generic_key))
if any(p in text for p in ("@EDITION@", "@PASSWORD@", "@GENERIC_KEY@")):
    sys.exit("build-answers: a placeholder survived rendering")
# Setup rejects a malformed answer file silently: on build 26300 a "--" inside a comment made
# WinPE power off a second after it started, on every boot (2026-11-17). Parse before writing.
import xml.dom.minidom
xml.dom.minidom.parseString(text.encode())
open(target, "w").write(text)
EOF
chmod 0600 "${stage}/autounattend.xml"

xorriso -as mkisofs -quiet -J -r -V ZEOANSWERS -o "${out}" "${stage}"
chmod 0600 "${out}"
echo "build-answers event=written iso=${out} edition=\"${edition}\""
