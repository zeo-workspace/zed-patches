# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# Hugging Face commit the files are pinned to; PV is its date (2024-10-29).
# app-editors/zeo checks the same files by size and SHA-256 (story 044).
HF_COMMIT="5359861c739e955e79d9a303bcbc70fb988958b1"
HF_URI="https://huggingface.co/ggerganov/whisper.cpp/resolve/${HF_COMMIT}"

DESCRIPTION="Whisper speech recognition models in ggml format, for whisper.cpp users"
HOMEPAGE="
	https://huggingface.co/ggerganov/whisper.cpp
	https://github.com/ggml-org/whisper.cpp
"
SRC_URI="
	tiny? ( ${HF_URI}/ggml-tiny.bin -> whisper-ggml-tiny-${HF_COMMIT:0:7}.bin )
	base? ( ${HF_URI}/ggml-base.bin -> whisper-ggml-base-${HF_COMMIT:0:7}.bin )
	small? ( ${HF_URI}/ggml-small.bin -> whisper-ggml-small-${HF_COMMIT:0:7}.bin )
"
S="${WORKDIR}"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"
IUSE="tiny +base small"
REQUIRED_USE="|| ( tiny base small )"

src_unpack() {
	# The models are single files installed as they are, never unpacked.
	:
}

src_install() {
	local model
	insinto /usr/share/whisper-models
	for model in tiny base small; do
		use "${model}" || continue
		newins "${DISTDIR}/whisper-ggml-${model}-${HF_COMMIT:0:7}.bin" "ggml-${model}.bin"
	done
}
