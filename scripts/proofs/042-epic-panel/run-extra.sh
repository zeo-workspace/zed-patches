#!/usr/bin/env bash
# Story 042, task 8.1 — the three tech-review fixes no automated test covers, proven on a
# private X display (E2E), beside run.sh.
#
#     run-extra.sh --binary <zeo-editor built from dev-042> --out <docs/assets/042-live-proof-DATE>
#
# What it proves, over a temp project holding a COPY of this workspace's .epic/ (gitignored):
#   extra-1  a story directory deleted and recreated while Zeo runs (rm -rf, mkdir, a new
#            tasks.md): the row reads the new tasks.md's progress;
#   extra-2  a box ticked inside that recreated directory: the row follows it, so the watch was
#            re-armed on the new directory (deviation 21, sync_dirs);
#   extra-3  the whole .epic deleted: the panel falls back to "No .epic/ directory in this project";
#   extra-4  .epic recreated (a new inode) holding a story the old one never had: its row appears;
#   extra-5  a box ticked inside the recreated .epic: the row follows it, so the watch was rebuilt
#            on the new inode (deviation 15, tech review M1);
#   extra-6  a second worktree with a long name, both worktrees holding .epic, and the right dock
#            narrowed from the keyboard: the worktree headers, "Open EPIC.md" lines and story rows
#            stay one line each and do not overlap (deviation 17, L1-L5). Checked with tesseract's
#            line boxes inside the dock, and by eye (the README says what the capture shows).
#
# Never touches the operator's profile (xvfb-proof.sh isolates Zeo under --keep) nor the
# workspace's .epic/ (only copies under $STATE are shown and edited; the digest is compared).
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused).

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run-extra.sh: %s\n' "$*" >&2
	exit "${code}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
HUB="$(cd -- "${HERE}/../../../.." && pwd)"
CORPUS="${HUB}/.epic"
BINARY=""
OUT=""
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
[[ -d "${CORPUS}/stories" ]] || die 2 "no corpus at ${CORPUS}"
for tool in tesseract xdotool Xvfb; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then
	MAGICK=(magick)
elif command -v convert >/dev/null; then
	MAGICK=(convert)
else
	die 2 "missing tool: magick (ImageMagick)"
fi
mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
# A capture left by an earlier run would release a background mutation before its time.
rm -f -- "${OUT}"/extra-[0-9]*.png

corpus_digest() {
	(cd -- "${CORPUS}" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
}
write_proof_settings() {
	cat >"${STATE}/settings.json" <<'JSON'
{"use_system_path_prompts": false, "session": {"trust_all_worktrees": true}}
JSON
}
harness() {
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "${STATE}/zeo" \
		--steps "$1" || die 2 "xvfb-proof.sh refused or failed on $1 (exit $?)"
}
# wait_for_file <path> — up to 5 min for a capture to land.
wait_for_file() {
	local tries
	for ((tries = 600; tries > 0; tries--)); do
		[[ -e "$1" ]] && return 0
		sleep 0.5
	done
	die 2 "timed out waiting for $1"
}
# Step fragments, each line ending in a comma: open a folder through Zeo's own path prompt
# (prefilled with $HOME, hence ctrl+a), and run a command-palette action by name.
open_folder_steps() {
	cat <<JSON
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "$1/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
JSON
}
palette_steps() {
	cat <<JSON
  {"chord": ["ctrl", "shift", "p"]}, {"sleep": 2},
  {"type": "$1"}, {"sleep": 2},
  {"key": ["Return"]}, {"sleep": 4},
JSON
}
# ocr <png> [crop geometry] — the capture's text on one line. tesseract here cannot read a PNG,
# so the capture goes through ImageMagick to a grey, enlarged, thresholded PNM first.
ocr() {
	local pnm="${STATE}/ocr.pnm" text crop=()
	[[ -z "${2-}" ]] || crop=(-crop "$2" +repage)
	"${MAGICK[@]}" "$1" "${crop[@]}" -colorspace Gray -resize 300% -threshold 70% "${pnm}" ||
		die 2 "cannot convert $1 for tesseract"
	text="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read ${pnm} (from $1)"
	tr '\n' ' ' <<<"${text}"
}
check() {
	local shot="$1" needle="$2" why="$3" text
	text="$(ocr "${OUT}/${shot}")"
	if [[ "${text}" == *"${needle}"* ]]; then
		printf 'ok    %s reads "%s" (%s)\n' "${shot}" "${needle}" "${why}"
	else
		printf 'FAIL  %s does not read "%s" (%s)\n' "${shot}" "${needle}" "${why}"
		failed=1
	fi
}
# The right dock's area at the harness's 1920x1080 screen (window 1536 wide, centred): wide
# enough for the default 300 px dock, so the narrowed dock sits inside it with editor background
# (empty: no file is open) to its left.
readonly DOCK_CROP="300x1010+1430+36"
# check_no_overlap <png> <why> <needle...> — inside the dock, every needle reads (a row that
# wrapped onto its neighbour garbles them), and tesseract's text lines, sorted by top, never
# reach into the next one by more than 2 px (of the 3x enlargement).
check_no_overlap() {
	local shot="$1" why="$2" pnm="${STATE}/overlap.pnm" text tsv overlaps needle
	shift 2
	text="$(ocr "${OUT}/${shot}" "${DOCK_CROP}")"
	for needle in "$@"; do
		if [[ "${text}" != *"${needle}"* ]]; then
			printf 'FAIL  %s: the narrow dock does not read "%s" (%s)\n' "${shot}" "${needle}" "${why}"
			failed=1
			return 0
		fi
	done
	"${MAGICK[@]}" "${OUT}/${shot}" -crop "${DOCK_CROP}" +repage -colorspace Gray -resize 300% \
		-threshold 70% "${pnm}" || die 2 "cannot convert ${shot} for tesseract"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not read ${pnm}"
	# Level 4 rows are text lines: left top width height at fields 7-10.
	overlaps="$(awk -F'\t' '$1 == 4 { print $8, $8 + $10 }' <<<"${tsv}" | sort -n |
		awk 'NR > 1 && $1 < bottom - 2 { n++; printf "lines at y %d (ends %d) and y %d; ", top, bottom, $1 }
		     { top = $1; bottom = $2 } END { exit n > 0 }')" || {
		printf 'FAIL  %s: text lines overlap in the narrow dock: %s(%s)\n' "${shot}" "${overlaps}" "${why}"
		failed=1
		return 0
	}
	printf 'ok    %s: %d text lines in the narrow dock, none overlapping; reads %s (%s)\n' "${shot}" \
		"$(awk -F'\t' '$1 == 4' <<<"${tsv}" | wc -l)" "$(printf '"%s" ' "$@")" "${why}"
}
check_corpus_untouched() {
	if [[ "$(corpus_digest)" == "${CORPUS_BEFORE}" ]]; then
		printf 'ok    the workspace .epic/ is byte-identical after the run\n'
	else
		printf 'FAIL  the workspace .epic/ changed during the run\n'
		failed=1
	fi
}

STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp042x-XXXX")"
PROJECT="${STATE}/projects/epic-proof"
LONG_NAME="zeo-epic-panel-proof-worktree-with-a-deliberately-long-name"
LONG="${STATE}/projects/${LONG_NAME}"
SAVED="${STATE}/epic-recreated"
mkdir -p -- "${PROJECT}" "${LONG}"
printf '.epic/\n' >"${PROJECT}/.gitignore"
printf 'epic proof\n' >"${PROJECT}/README"
printf '.epic/\n' >"${LONG}/.gitignore"
printf 'long worktree name\n' >"${LONG}/README"
CORPUS_BEFORE="$(corpus_digest)"
cp -a -- "${CORPUS}" "${PROJECT}/.epic"

# write_story <story dir> <title> <boxes> — a story.md and a tasks.md with <boxes> open boxes.
write_story() {
	local dir="$1" title="$2" boxes="$3" i
	mkdir -p -- "${dir}"
	printf -- '---\ntitle: "%s"\nstatus: draft\ntype: feature\n---\n\n# %s\n' "${title}" "${title}" \
		>"${dir}/story.md"
	{
		printf '# Tasks\n\n'
		for ((i = 1; i <= boxes; i++)); do
			printf -- '- [ ] %d. step %d\n' "${i}" "${i}"
		done
	} >"${dir}/tasks.md"
}

# The recreated story: the last active one, so its row sits just above "Archived (N)". Its new
# tasks.md has a box count no story of the copy has, so "0/97" and "1/97" can only be its row.
REARM="$(find "${PROJECT}/.epic/stories" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-*' | sort | tail -n 1)"
[[ -n "${REARM}" ]] || die 2 "the copy has no active story to recreate"
REARM_SLUG="${REARM##*/}"
REARM_SLUG="${REARM_SLUG#*-}"
REARM_BOXES=97
INODE_DIR="098-inode-watch-proof"
INODE_SLUG="${INODE_DIR#*-}"
INODE_BOXES=89
for boxes in "${REARM_BOXES}" "${INODE_BOXES}"; do
	if grep -rqsE "^[[:space:]]*- \[[ x~]\] ${boxes}\. " "${PROJECT}/.epic/stories"/*/tasks.md; then
		die 2 "a story of the copy already reaches ${boxes} boxes; pick another count"
	fi
done
# The .epic the run recreates: the copy as it is now, plus a story the live copy never has.
cp -a -- "${PROJECT}/.epic" "${SAVED}"
write_story "${SAVED}/stories/${INODE_DIR}" "Inode watch proof" "${INODE_BOXES}"
printf 'recreated story: %s (-> 0/%s, 1/%s); recreated .epic adds %s (-> 0/%s, 1/%s)\n' \
	"${REARM##*/}" "${REARM_BOXES}" "${REARM_BOXES}" "${INODE_DIR}" "${INODE_BOXES}" "${INODE_BOXES}"

# The long-named worktree: an .epic of its own, so both worktrees get a header (R2.5).
mkdir -p -- "${LONG}/.epic/stories" "${LONG}/.epic/archive"
printf '# EPIC\n' >"${LONG}/.epic/EPIC.md"
write_story "${LONG}/.epic/stories/001-a-story-with-a-long-slug-that-has-to-truncate-in-a-narrow-dock" \
	"Long slug" 2

write_proof_settings

# Each mutation waits for the capture before it, so the harness's own start-up time cannot
# shift it against the steps. tick <tasks.md> marks its first open box.
tick() { sed -i '0,/^\([[:space:]]*\)- \[ \]/s//\1- [x]/' "$1"; }
mutate() {
	wait_for_file "${OUT}/extra-0-before.png"
	sleep 2
	rm -rf -- "${REARM}"
	mkdir -- "${REARM}"
	write_story "${REARM}" "Recreated story" "${REARM_BOXES}"
	printf 'mutation: %s deleted and recreated with 0/%s\n' "${REARM##*/}" "${REARM_BOXES}"
	wait_for_file "${OUT}/extra-1-story-recreated.png"
	sleep 2
	tick "${REARM}/tasks.md"
	printf 'mutation: one box ticked in the recreated %s\n' "${REARM##*/}"
	wait_for_file "${OUT}/extra-2-tick-in-recreated-story.png"
	sleep 2
	rm -rf -- "${PROJECT}/.epic"
	printf 'mutation: .epic deleted\n'
	wait_for_file "${OUT}/extra-3-epic-deleted.png"
	sleep 2
	cp -a -- "${SAVED}" "${PROJECT}/.epic"
	printf 'mutation: .epic recreated (inode %s)\n' "$(stat -c %i -- "${PROJECT}/.epic")"
	wait_for_file "${OUT}/extra-4-epic-recreated.png"
	sleep 2
	tick "${PROJECT}/.epic/stories/${INODE_DIR}/tasks.md"
	printf 'mutation: one box ticked in the recreated .epic\n'
}

# 1 — the live-watch cases, one Zeo run; every capture waits 12 s after its mutation started.
cat >"${STATE}/steps-1.json" <<JSON
[
  {"sleep": 15},
$(open_folder_steps "${PROJECT}")
$(palette_steps "epic panel: toggle focus")
  {"shot": "${OUT}/extra-0-before.png"},
  {"sleep": 14},
  {"shot": "${OUT}/extra-1-story-recreated.png"},
  {"sleep": 14},
  {"shot": "${OUT}/extra-2-tick-in-recreated-story.png"},
  {"sleep": 14},
  {"shot": "${OUT}/extra-3-epic-deleted.png"},
  {"sleep": 14},
  {"shot": "${OUT}/extra-4-epic-recreated.png"},
  {"sleep": 14},
  {"shot": "${OUT}/extra-5-tick-in-recreated-epic.png"}
]
JSON
mutate &
MUTATOR=$!
harness "${STATE}/steps-1.json"
wait "${MUTATOR}" || die 2 "a background mutation failed"

# 2 — two worktrees with .epic, one with a long name; the right dock narrowed from the keyboard
# (workspace::DecreaseActiveDockSize, one UI font size per press).
cat >"${STATE}/steps-2.json" <<JSON
[
  {"sleep": 15},
$(palette_steps "workspace: add folder to project")
  {"chord": ["ctrl", "a"]}, {"type": "${LONG}/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
$(palette_steps "epic panel: toggle focus")
  {"shot": "${OUT}/extra-6a-two-worktrees.png"},
$(for _ in 1 2 3 4 5 6 7 8 9 10; do printf '  {"chord": ["ctrl", "alt", "minus"]}, {"sleep": 1},\n'; done)
  {"sleep": 2},
  {"shot": "${OUT}/extra-6b-narrow-dock.png"}
]
JSON
harness "${STATE}/steps-2.json"

failed=0
check extra-0-before.png "Open EPIC.md" "control: the panel is open on the copy"
check extra-1-story-recreated.png "0/${REARM_BOXES}" "${REARM_SLUG}'s row read the recreated tasks.md"
check extra-2-tick-in-recreated-story.png "1/${REARM_BOXES}" "the watch was re-armed on the recreated story directory"
check extra-3-epic-deleted.png "No .epic/ directory in this project" "the deleted .epic is noticed"
check extra-4-epic-recreated.png "${INODE_SLUG}" "the recreated .epic is read (a story only it holds)"
check extra-4-epic-recreated.png "0/${INODE_BOXES}" "control: the new story's progress before the tick"
check extra-5-tick-in-recreated-epic.png "1/${INODE_BOXES}" "the watch was rebuilt on the recreated .epic's inode"
check extra-6a-two-worktrees.png "${LONG_NAME:0:20}" "control: the long-named worktree's header"
check_no_overlap extra-6b-narrow-dock.png "rows stay one line each in the narrow dock" \
	"Open EPIC" "Archived"
check_corpus_untouched
printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
