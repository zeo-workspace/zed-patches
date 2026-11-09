#!/usr/bin/env python3
"""Rewrite agent-client-protocol 3.x module paths to the 5.0.0 layout.

    rewrite-acp5-paths.py --check <file.rs>...     exit 1 if any file would change
    rewrite-acp5-paths.py --write <file.rs>...     rewrite in place
    rewrite-acp5-paths.py --chain <repo> <base> <tip> <branch>
                                                   rewrite every snapshot of
                                                   base..tip into a new chain

Why it exists: agent-client-protocol 5.0.0 (Zed 4ec98df, 2026-11) moved the
schema modules from `schema::v1` / `schema::v2` to `v1::schema` / `v2::schema`.
About 26 patches of the series carry the old path in added or context lines, so
a per-commit hand edit cascades conflicts: once commit N says `v1::schema`,
commit N+1's context still says `schema::v1`. The method that worked on the
2026-09-28 bump (ACP schema v2, hub b40ff8f) is one deterministic rule applied
to every snapshot of the old chain, base included, then cherry-picking the
rewritten chain onto the new baseline. That run's script lived in /tmp and was
lost; this one is versioned on purpose (docs/ZEO-NEXT-PROPOSAL.md §4.1).

The rule must be the identity on the new baseline -- otherwise the first patch
absorbs upstream lines. Prove it with `--check` over the new tree first.

What it rewrites, all forms measured in upstream's a4b39c38..d2a4fb6d diff:
  agent_client_protocol::schema::v2 as acp   -> agent_client_protocol::v2::schema as acp
  agent_client_protocol::schema::v2::Foo     -> agent_client_protocol::v2::schema::Foo
  schema::v1::{self as acp_v1, ErrorCode}    -> v1::schema::{self as acp_v1, ErrorCode}
  agent_client_protocol::schema::{MaybeUndefined, v1 as acp_v1, v2 as acp_v2}
      -> agent_client_protocol::{schema::MaybeUndefined, v1::schema as acp_v1, v2::schema as acp_v2}
  ...::{Error, schema::{ProtocolVersion, v1 as acp_v1}} (nested group)
      -> ...::{Error, schema::ProtocolVersion, v1::schema as acp_v1}
A `schema::{...}` group naming neither v1 nor v2 is left alone, as upstream did.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# `schema::v1` / `schema::v2` as a path segment, not inside a longer identifier.
_DIRECT = re.compile(r"(?<![A-Za-z0-9_])schema::(v[12])(?![A-Za-z0-9_])")
_GROUP_START = re.compile(r"(?<![A-Za-z0-9_])schema::\{")
_VERSION_ITEM = re.compile(r"^(v[12])(?![A-Za-z0-9_])(.*)$", re.DOTALL)


def _split_top_level(body: str) -> list[str]:
    """Split a use-group body at depth-0 commas, keeping each item's whitespace."""
    items, depth, start = [], 0, 0
    for i, ch in enumerate(body):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == "," and depth == 0:
            items.append(body[start:i])
            start = i + 1
    items.append(body[start:])
    return items


def _rewrite_item(raw: str) -> str:
    lead = raw[: len(raw) - len(raw.lstrip())]
    trail = raw[len(raw.rstrip()) :]
    item = raw.strip()
    if not item:
        return raw
    m = _VERSION_ITEM.match(item)
    if m:
        version, rest = m.group(1), m.group(2)
        if rest.startswith("::"):
            new = f"{version}::schema{rest}"
        elif rest.strip().startswith("as "):
            new = f"{version}::schema {rest.strip()}"
        elif rest == "":
            new = f"{version}::schema as {version}"
        else:
            raise ValueError(f"unrecognised version item: {item!r}")
    else:
        new = f"schema::{item}"
    return f"{lead}{new}{trail}"


def _match_brace(text: str, open_idx: int) -> int:
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("unbalanced braces in a schema group")


def rewrite(text: str) -> str:
    out, pos = [], 0
    while True:
        m = _GROUP_START.search(text, pos)
        if not m:
            break
        open_idx = m.end() - 1
        close_idx = _match_brace(text, open_idx)
        body = text[open_idx + 1 : close_idx]
        items = _split_top_level(body)
        if not any(_VERSION_ITEM.match(i.strip()) for i in items):
            out.append(text[pos : close_idx + 1])
            pos = close_idx + 1
            continue
        new_body = ",".join(_rewrite_item(i) for i in items)
        prefix_start = m.start()
        nested = not text[:prefix_start].endswith("agent_client_protocol::")
        out.append(text[pos:prefix_start])
        if nested:
            # Inside a parent group: inline the items; the parent's braces remain.
            out.append(new_body.strip().rstrip(","))
        else:
            out.append("{" + new_body + "}")
        pos = close_idx + 1
    out.append(text[pos:])
    return _DIRECT.sub(r"\1::schema", "".join(out))


def _git(
    repo: str, *args: str, input: bytes | None = None, env: dict[str, str] | None = None
) -> bytes:
    return subprocess.run(
        ["git", "-C", repo, *args],
        input=input,
        check=True,
        capture_output=True,
        env={**os.environ, **(env or {})},
    ).stdout


_BLOB_CACHE: dict[str, str] = {}


def _rewrite_tree(repo: str, tree: str) -> tuple[str, int]:
    """Return the tree with every .rs blob rewritten, and how many blobs changed."""
    # One `git grep` per snapshot narrows thousands of .rs files to the few that
    # name `schema::`; a blob shared by many snapshots is rewritten once (cache).
    grep = subprocess.run(
        ["git", "-C", repo, "grep", "-l", "-z", "-F", "schema::", tree, "--", "*.rs"],
        check=False,
        capture_output=True,
    )
    if grep.returncode not in (0, 1):
        raise RuntimeError(grep.stderr.decode())
    paths = [p.split(b":", 1)[1] for p in grep.stdout.split(b"\0") if p]
    updates = []
    for path in paths:
        mode, _kind, blob = (
            _git(repo, "ls-tree", tree, "--", path.decode())
            .decode()
            .split("\t")[0]
            .split()
        )
        if blob not in _BLOB_CACHE:
            text = _git(repo, "cat-file", "blob", blob).decode()
            new = rewrite(text)
            _BLOB_CACHE[blob] = (
                _git(repo, "hash-object", "-w", "--stdin", input=new.encode())
                .decode()
                .strip()
                if new != text
                else blob
            )
        if _BLOB_CACHE[blob] != blob:
            updates.append(f"{mode} {_BLOB_CACHE[blob]}\t{path.decode()}\n")
    if not updates:
        return tree, 0
    with tempfile.TemporaryDirectory() as tmp:
        env = {"GIT_INDEX_FILE": str(Path(tmp) / "index")}
        _git(repo, "read-tree", tree, env=env)
        _git(
            repo,
            "update-index",
            "--index-info",
            input="".join(updates).encode(),
            env=env,
        )
        return _git(repo, "write-tree", env=env).decode().strip(), len(updates)


def rewrite_chain(repo: str, base: str, tip: str, branch: str) -> None:
    """Rewrite base and every commit up to tip, keeping messages and authorship."""
    commits = [base] + _git(
        repo, "rev-list", "--reverse", f"{base}..{tip}"
    ).decode().split()
    parent: str | None = None
    for commit in commits:
        tree, count = _rewrite_tree(
            repo, _git(repo, "rev-parse", f"{commit}^{{tree}}").decode().strip()
        )
        msg = _git(repo, "log", "-1", "--format=%B", commit)
        name, email, date = (
            _git(repo, "log", "-1", "--format=%an%x00%ae%x00%aI", commit)
            .decode()
            .strip()
            .split("\0")
        )
        env = {
            "GIT_AUTHOR_NAME": name,
            "GIT_AUTHOR_EMAIL": email,
            "GIT_AUTHOR_DATE": date,
        }
        args = ["commit-tree", tree] + (["-p", parent] if parent else [])
        parent = _git(repo, *args, input=msg, env=env).decode().strip()
        print(f"{commit[:12]} -> {parent[:12]} ({count} files rewritten)")
    _git(repo, "branch", "-f", branch, parent)


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] in ("--check", "--write"):
        dirty = 0
        for name in argv[1:]:
            path = Path(name)
            text = path.read_text()
            new = rewrite(text)
            if new != text:
                dirty += 1
                print(
                    f"would change: {name}"
                    if argv[0] == "--check"
                    else f"rewrote: {name}"
                )
                if argv[0] == "--write":
                    path.write_text(new)
        return 1 if dirty and argv[0] == "--check" else 0
    if len(argv) == 5 and argv[0] == "--chain":
        rewrite_chain(*argv[1:])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
