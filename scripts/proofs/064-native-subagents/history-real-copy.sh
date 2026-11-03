#!/usr/bin/env bash
# Story 064, task 3.2 — history step 7 on a scratch copy of the operator's real database
# (R2.2; Q5: "every pre-existing row reads back unchanged").
#
# Never writes to the live database: the copy is taken with `sqlite3 .backup` from a read-only
# connection into a fresh mktemp directory, which is removed on exit whatever the outcome.
# Two independent readers judge the same before/after:
#   1. the Rust test `history_db_subagent_step_real_copy_keeps_every_row` (ignored by default),
#      which migrates the copy with the real `AgentTaskHistoryDb::MIGRATIONS` through sqlez;
#   2. this script's own sqlite3 dump of all 18 pre-existing columns (`hex(quote())`d), diffed.
#
# Usage:
#   history-real-copy.sh [--snapshot-only] [LIVE_DB]
#     LIVE_DB          default: ~/.local/share/zeo/db/0-zeo/db.sqlite
#     --snapshot-only  copy and dump only, no build (checks the script's own mechanics)
#   ZEO_064_TREE      the story worktree to build in (default: <hub>/zed-patches/work/zed-064)
#
# Exit: 0 = step 7 applied and 0 row diffs; 1 = a diff or a failed check; 2 = environment.
set -euo pipefail

log() { printf '{"proof":"064-history-real-copy","event":"%s"%s}\n' "$1" "${2:+,$2}"; }
die_env() {
	log environment_error "\"reason\":\"$1\""
	exit 2
}

snapshot_only=0
if [[ ${1:-} == --snapshot-only ]]; then
	snapshot_only=1
	shift
fi
live_db=${1:-$HOME/.local/share/zeo/db/0-zeo/db.sqlite}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hub=$(cd "$script_dir/../../../.." && pwd)
tree=${ZEO_064_TREE:-$hub/zed-patches/work/zed-064}

command -v sqlite3 >/dev/null || die_env "sqlite3 not found"
[[ -f $live_db ]] || die_env "no database at $live_db"

columns=(session_id task_id thread_title project kind description background status started_at
	ended_at tokens tool_uses archived label tool_call_id log_bytes origin deleted)
quoted=""
for column in "${columns[@]}"; do
	quoted+="${quoted:+ || '|' || }quote($column)"
done
# hex() keeps one row per line: descriptions carry newlines, and quote() does not escape them.
dump_sql="SELECT hex($quoted) FROM agent_task_history ORDER BY session_id, task_id;"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/zeo-064-history.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
copy=$scratch/db.sqlite

sqlite3 -readonly "file:$live_db?mode=ro" ".backup '$copy'" || die_env "backup of $live_db failed"
rows=$(sqlite3 "$copy" "SELECT COUNT(*) FROM agent_task_history;") ||
	die_env "the copy has no agent_task_history"
steps=$(sqlite3 "$copy" "SELECT COUNT(*) FROM migrations WHERE domain = 'AgentTaskHistoryDb';")
sqlite3 "$copy" "$dump_sql" >"$scratch/before.txt"
log copied "\"rows\":$rows,\"recorded_steps\":$steps"

if ((snapshot_only)); then
	lines=$(wc -l <"$scratch/before.txt")
	[[ $lines -eq $rows ]] || {
		log check_failed "\"reason\":\"dump has $lines lines for $rows rows\""
		exit 1
	}
	log snapshot_ok "\"dump_lines\":$lines"
	exit 0
fi

[[ -d $tree ]] || die_env "no story worktree at $tree"
(
	cd "$tree"
	ZEO_064_HISTORY_DB_COPY=$copy cargo test -p agent_tasks_panel \
		history_db_subagent_step_real_copy -- --ignored
) || {
	log check_failed '"reason":"the Rust real-copy test failed"'
	exit 1
}

sqlite3 "$copy" "$dump_sql" >"$scratch/after.txt"
if ! diff -u "$scratch/before.txt" "$scratch/after.txt" >"$scratch/diff.txt"; then
	log check_failed "\"reason\":\"pre-existing columns changed\",\"diff_lines\":$(wc -l <"$scratch/diff.txt")"
	exit 1
fi
# Revision 1: step 7 adds only child_session_id; origin keeps every old value (the diff above), no
# row may read acp_subagent, and no `source` column may exist.
read -r total native no_child new_steps source_columns < <(sqlite3 -separator ' ' "$copy" \
	"SELECT COUNT(*), COALESCE(SUM(origin = 'acp_subagent'), 0), COALESCE(SUM(child_session_id IS NULL), 0),
	        (SELECT COUNT(*) FROM migrations WHERE domain = 'AgentTaskHistoryDb'),
	        (SELECT COUNT(*) FROM pragma_table_info('agent_task_history') WHERE name = 'source')
	 FROM agent_task_history;")
if [[ $total -ne $rows || $native -ne 0 || $no_child -ne $rows || $new_steps -ne $((steps + 1)) || $source_columns -ne 0 ]]; then
	log check_failed "\"rows\":$total,\"acp_subagent\":$native,\"no_child\":$no_child,\"steps\":$new_steps,\"source_columns\":$source_columns"
	exit 1
fi
log passed "\"rows\":$rows,\"row_diffs\":0,\"steps\":$new_steps"
