#!/usr/bin/env python3
"""Story 072, task 4.1 -- the scratch ebuild and the regenerated series describe exactly the patched
a4b39c38 source (Integration).

    ZP_TREE=<zed-patches/work/zed-a4b39c38...>      (or ZP_LOCK=<a Cargo.lock>) \
    [ZP_EBUILD=<scratch>/app-editors/zeo/zeo-0.7.1_p20261101.ebuild] \
    [ZP_NEW_PATCHES=<zed-patches/patches/zeo-0.7.1_p20261101>] \
    [ZP_OLD_PATCHES=<zed-patches/patches/zeo-0.7.0_p20261025>] \
    python3 -I test_ebuild.py -v

ZP_EBUILD defaults to /var/tmp/zeo-scratch-1101/app-editors/zeo/zeo-0.7.1_p20261101.ebuild (the
story's scratch overlay); the two patch directories default to the PF directories of the
zed-patches repository this file lives in.

What it asserts (R2.5, R2.6, R2.7, R3.1, R3.2, R3.3; Q4):
  * EGIT_COMMIT is a4b39c38e0056a5631a6f49f7fb13d4d1c4b6a9c;
  * CRATES is exactly the lock's registry packages, compared as name@version -- never by name,
    because the lock holds many crates at two versions;
  * tree-sitter-go and crash-context, registry crates at 0.7.0, are in CRATES at no version: the
    lock now takes both from git;
  * GIT_CRATES has one entry per git package of the lock, each naming the lock's repository and
    the lock's full commit (the part after `#`, never a short `?rev=`), and no other entry;
  * the six moves of R3.3, pinned here by their full hashes so a stale lock cannot vouch for a
    stale ebuild: livekit-rust-sdks fbda05eb (7 crates), wgpu/naga cddb2f5d (14), tree-sitter and
    tree-sitter-language 803c6eba (tree-sitter still under lib/), zed-scap b5c86ec5, and the two
    new entries tree-sitter-go 6862a49e (repository root) and crash-context 911b04e0
    (crates/crash-context), written exactly;
  * the new patch directory holds the same 67 patch files as 0.7.0_p20261025's, and its series
    lists them in the same order;
  * every patch header above `---` is 0.7.0_p20261025's, byte for byte, but for whole paragraphs
    that open with "a4b39c38 review:" (R2.6, R4.6);
  * no line the regenerated series adds below `---` names a checkpoint (R2.5, R2.7).

The parsers are pinned first by fixtures (ParserHostileTests), each the input that would make a
check fire wrongly -- the case that wrongly collapses two things, then the case that wrongly
splits one -- and only then the benign case.

Exit: unittest's -- 0 every assertion holds, 1 a failure or an error (an unset or unreadable input
is an error, never a pass).
"""

import os
import pathlib
import re
import sys
import tomllib
import unittest

A4B3 = "a4b39c38e0056a5631a6f49f7fb13d4d1c4b6a9c"
REPO = pathlib.Path(__file__).resolve().parents[3]  # zed-patches/scripts/proofs/072-a4b3-bump/
NEW_PF = "zeo-0.7.1_p20261101"
OLD_PF = "zeo-0.7.0_p20261025"
SCRATCH_EBUILD = f"/var/tmp/zeo-scratch-1101/app-editors/zeo/{NEW_PF}.ebuild"
SERIES_SIZE = 67
REVIEW_OPENER = "a4b39c38 review:"

# R3.3, with the full commits read from the patched a4b39c38 lock on 2026-10-31.
LIVEKIT = "fbda05eb278b4a7c5be8fc9b2a92e9b62e732236"
WGPU = "cddb2f5d80dc0009b2ef6767635140cacf90a007"
TREE_SITTER = "803c6ebaac27d69e1808b45058482e868d073ceb"
SCAP = "b5c86ec58dd4b6b7732bf6ac8be03d6b1f190a82"
MOVES = {
    **{name: LIVEKIT for name in ("livekit", "livekit-api", "livekit-protocol", "livekit-runtime",
                                  "libwebrtc", "webrtc-sys", "webrtc-sys-build")},
    **{name: WGPU for name in ("wgpu", "wgpu-core", "wgpu-core-deps-apple", "wgpu-core-deps-emscripten",
                               "wgpu-core-deps-linux-android-bsd", "wgpu-core-deps-wasm",
                               "wgpu-core-deps-windows", "wgpu-hal", "wgpu-naga-bridge", "wgpu-sync",
                               "wgpu-types", "naga", "naga-types")},
    "tree-sitter": TREE_SITTER,
    "tree-sitter-language": TREE_SITTER,
    "zed-scap": SCAP,
}
TREE_SITTER_ENTRY = f"https://github.com/tree-sitter/tree-sitter;{TREE_SITTER};tree-sitter-%commit%/lib"
NEW_GIT_ENTRIES = {
    "tree-sitter-go": "https://github.com/zed-industries/tree-sitter-go;"
                      "6862a49e3c5a7567a6c576420e9a8f944e198a85;tree-sitter-go-%commit%",
    "crash-context": "https://github.com/rust-minidump/minidump-writer;"
                     "911b04e09b79b736cc15cbe712e83e2d3f348bb9;minidump-writer-%commit%/crates/crash-context",
}


# ── Parsing: the ebuild ─────────────────────────────────────────────────────
def ebuild_crates(ebuild: str) -> set:
    m = re.search(r'^CRATES="\n(.*?)^"', ebuild, re.MULTILINE | re.DOTALL)
    if not m:
        raise ValueError("no CRATES=\"...\" block in the ebuild")
    return {line.strip() for line in m.group(1).splitlines() if line.strip()}


def ebuild_git_crates(ebuild: str) -> dict:
    m = re.search(r"^declare -A GIT_CRATES=\(\n(.*?)^\)", ebuild, re.MULTILINE | re.DOTALL)
    if not m:
        raise ValueError("no declare -A GIT_CRATES=( ... ) block in the ebuild")
    return dict(re.findall(r"^\s*\[([^\]]+)\]='([^']*)'", m.group(1), re.MULTILINE))


def egit_commit(ebuild: str) -> str:
    m = re.search(r'^EGIT_COMMIT="([^"]*)"', ebuild, re.MULTILINE)
    if not m:
        raise ValueError("no EGIT_COMMIT=\"...\" line in the ebuild")
    return m.group(1)


def crates_named(crates: set, name: str) -> set:
    """The CRATES entries whose crate name is exactly `name`, at any version. `tree-sitter-gomod`
    is not `tree-sitter-go`, and `crash-handler` is not `crash-context`: a prefix test would
    report both."""
    return {entry for entry in crates if entry.rpartition("@")[0] == name}


# ── Parsing: the lock ───────────────────────────────────────────────────────
def lock_packages(lock_text: str) -> list:
    return tomllib.loads(lock_text).get("package", [])


def lock_registry(packages: list) -> set:
    return {f"{p['name']}@{p['version']}" for p in packages if p.get("source", "").startswith("registry+")}


def normalise_repo(url: str) -> str:
    url = url.rstrip("/")
    return url.removesuffix(".git")


def lock_git(packages: list) -> dict:
    """name -> (repository, full commit). The commit is the `#` fragment: `?rev=` may be short
    (wprcontrol's is `cd811f7`), and GIT_CRATES names the full commit."""
    out = {}
    for p in packages:
        source = p.get("source", "")
        if not source.startswith("git+"):
            continue
        base, _, commit = source[len("git+"):].partition("#")
        out[p["name"]] = (normalise_repo(base.split("?", 1)[0]), commit)
    return out


def git_differences(lock: dict, git_crates: dict) -> list:
    """Every way GIT_CRATES disagrees with the lock's git packages, one line each."""
    problems = []
    for name, (repo, commit) in sorted(lock.items()):
        entry = git_crates.get(name)
        if entry is None:
            problems.append(f"{name}: in the lock ({repo} {commit}), not in GIT_CRATES")
            continue
        fields = entry.split(";")
        if len(fields) != 3:
            problems.append(f"{name}: GIT_CRATES entry is not url;commit;path: {entry}")
            continue
        if normalise_repo(fields[0]) != repo:
            problems.append(f"{name}: GIT_CRATES repository {fields[0]}, lock {repo}")
        if fields[1] != commit:
            problems.append(f"{name}: GIT_CRATES commit {fields[1]}, lock {commit}")
    for name in sorted(set(git_crates) - set(lock)):
        problems.append(f"{name}: in GIT_CRATES, not a git package of the lock")
    return problems


# ── Parsing: the series ─────────────────────────────────────────────────────
def series_entries(text: str) -> list:
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def split_patch(text: str) -> tuple:
    """(header, body): the header is every line above the FIRST line that is exactly `---`; the
    body is everything after it. A later `---` (a removed line reading `--`) stays in the body."""
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.rstrip("\n") == "---":
            return "".join(lines[:index]), "".join(lines[index + 1:])
    raise ValueError("no `---` separator line: not a patch in the series' format")


def without_review_paragraphs(header: str) -> str:
    """The header with every paragraph that OPENS with "a4b39c38 review:" removed (R2.6 lets the
    carry append exactly those). A paragraph that only mentions the phrase, or a review of another
    snapshot, stays -- so any other edit still shows."""
    paragraphs = header.rstrip("\n").split("\n\n")
    kept = [p for p in paragraphs if not p.lstrip("\n").startswith(REVIEW_OPENER)]
    return "\n\n".join(kept)


def added_checkpoint_lines(body: str) -> list:
    """The lines a patch ADDS (`+`, not the `+++` file header) that name a checkpoint, any case."""
    return [line for line in body.splitlines()
            if line.startswith("+") and not line.startswith("+++ ") and "checkpoint" in line.lower()]


def shown(items, limit=20) -> str:
    items = sorted(items)
    more = f" ... and {len(items) - limit} more" if len(items) > limit else ""
    return ", ".join(items[:limit]) + more


# ── Fixtures: what would make a check fire wrongly, before what makes it hold ──
def pkg(name, version, source=None) -> str:
    return f'[[package]]\nname = "{name}"\nversion = "{version}"\n' + (f'source = "{source}"\n' if source else "")


REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def patch(header: str, body: str) -> str:
    return f"{header}---\n\n{body}"


OLD_HEADER = ("From 1111 Mon Sep 17 00:00:00 2001\nFrom: zed-patches <zed-patches@localhost>\n"
              "Subject: [PATCH] agent_ui: a thing\n\nWhy it exists.\n\nCo-Authored-By: X <x@localhost>\n")


class ParserHostileTests(unittest.TestCase):
    # Wrongly collapse: things that look alike and MUST stay apart.
    def test_01_hostile_a_crate_at_two_versions_is_two_crates(self):
        lock = lock_packages(pkg("foo", "1.0.0", REGISTRY) + pkg("foo", "2.0.0", REGISTRY))
        self.assertEqual(lock_registry(lock) - {"foo@1.0.0"}, {"foo@2.0.0"})

    def test_02_hostile_like_named_crates_are_not_tree_sitter_go_or_crash_context(self):
        crates = {"tree-sitter-gomod@1.1.1", "tree-sitter-gowork@0.0.1", "tree-sitter-go-mod@1.0.0",
                  "crash-handler@0.6.3", "crash-context-ext@0.1.0"}
        self.assertEqual(crates_named(crates, "tree-sitter-go"), set())
        self.assertEqual(crates_named(crates, "crash-context"), set())

    def test_03_hostile_two_packages_of_one_repo_at_one_commit_each_need_an_entry(self):
        src = f"git+https://github.com/tree-sitter/tree-sitter?rev={TREE_SITTER}#{TREE_SITTER}"
        lock = lock_git(lock_packages(pkg("tree-sitter", "0.28.0", src) + pkg("tree-sitter-language", "0.1.8", src)))
        self.assertEqual(len(git_differences(lock, {"tree-sitter": TREE_SITTER_ENTRY})), 1)

    def test_04_hostile_a_header_edit_beside_a_review_paragraph_is_still_an_edit(self):
        new = OLD_HEADER.replace("Why it exists.", "Why it exists now.") + f"\n{REVIEW_OPENER} fine.\n"
        self.assertNotEqual(without_review_paragraphs(new), without_review_paragraphs(OLD_HEADER))

    def test_05_hostile_a_mention_or_another_snapshots_review_is_not_strippable(self):
        for extra in (f"See the {REVIEW_OPENER} below.", "a5c4ca8b review: an older note."):
            new = OLD_HEADER.replace("\nCo-Authored-By", f"\n{extra}\n\nCo-Authored-By")
            self.assertNotEqual(without_review_paragraphs(new), without_review_paragraphs(OLD_HEADER), extra)

    def test_06_hostile_checkpoint_outside_an_added_line_is_not_an_addition(self):
        header = OLD_HEADER.replace("Why it exists.", f"{REVIEW_OPENER} upstream removed checkpoints\n"
                                                      "+checkpoint: None, quoted in the message")
        body = ("diff --git a/crates/checkpoint/a.rs b/crates/checkpoint/a.rs\n"
                "--- a/crates/checkpoint/a.rs\n+++ b/crates/checkpoint/a.rs\n"
                "@@ -1,2 +1,1 @@\n         checkpoint: None,\n-        checkpoint: None,\n")
        head, rest = split_patch(patch(header, body))
        self.assertEqual(added_checkpoint_lines(rest), [])
        self.assertIn("checkpoint", head)

    # Wrongly split: different spellings of one thing that MUST come together.
    def test_07_hostile_dot_git_and_a_short_rev_are_the_same_source(self):
        lock = lock_git(lock_packages(
            pkg("async-process", "2.5.0", "git+https://github.com/zed-industries/async-process.git?rev=0b6d671#0b6d6713570af61806e1e5cb40e0f757cb93fd9d")
            + pkg("wprcontrol", "0.1.0", "git+https://github.com/zed-industries/wprcontrol?rev=cd811f7#cd811f7d744f65291e13131b1d907fda63ed91a1")))
        git = {"async-process": "https://github.com/zed-industries/async-process;0b6d6713570af61806e1e5cb40e0f757cb93fd9d;async-process-%commit%",
               "wprcontrol": "https://github.com/zed-industries/wprcontrol;cd811f7d744f65291e13131b1d907fda63ed91a1;wprcontrol-%commit%"}
        self.assertEqual(git_differences(lock, git), [])

    def test_08_hostile_a_review_paragraph_anywhere_or_wrapped_leaves_the_header_equal(self):
        review = f"{REVIEW_OPENER} checkpoint removal (#65989) touches only\nthis patch's test literals."
        before_trailer = OLD_HEADER.replace("\nCo-Authored-By", f"\n{review}\n\nCo-Authored-By")
        appended = OLD_HEADER + f"\n{review}\n"
        two = appended + f"\n{REVIEW_OPENER} a second upstream change.\n"
        for new in (before_trailer, appended, two):
            self.assertEqual(without_review_paragraphs(new), without_review_paragraphs(OLD_HEADER), new)

    def test_09_hostile_checkpoint_in_any_case_on_an_added_line_counts(self):
        body = "+                checkpoint: None,\n+    let c = Checkpoint::new();\n+GitCheckpoint\n"
        self.assertEqual(len(added_checkpoint_lines(body)), 3)

    def test_10_hostile_a_later_dashes_line_stays_in_the_body(self):
        head, rest = split_patch(patch(OLD_HEADER, "@@ -1 +1 @@\n---\n+    checkpoint: None,\n"))
        self.assertEqual(head, OLD_HEADER)
        self.assertEqual(len(added_checkpoint_lines(rest)), 1)

    # Benign: the forms the checks exist to read.
    def test_11_git_and_path_packages_are_not_registry_crates(self):
        lock = lock_packages(pkg("zed", "1.28.0") + pkg("tree-sitter-go", "0.25.0", "git+https://github.com/zed-industries/tree-sitter-go?rev=6862a49e3c5a7567a6c576420e9a8f944e198a85#6862a49e3c5a7567a6c576420e9a8f944e198a85")
                             + pkg("serde", "1.0.228", REGISTRY))
        self.assertEqual(lock_registry(lock), {"serde@1.0.228"})

    def test_12_a_registry_spelling_is_found_at_any_version(self):
        self.assertEqual(crates_named({"tree-sitter-go@0.25.0", "crash-context@0.8.0"}, "tree-sitter-go"),
                         {"tree-sitter-go@0.25.0"})

    def test_13_series_comments_are_not_entries(self):
        text = "# Numbered 0065 because 0064 was the last number taken.\n0063-devtools-panel.patch\n0065-x.patch\n"
        self.assertEqual(series_entries(text), ["0063-devtools-panel.patch", "0065-x.patch"])


# ── Real data ───────────────────────────────────────────────────────────────
def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is not set (see the module docstring)")
    return value


def read(path) -> str:
    try:
        return pathlib.Path(path).read_text()
    except OSError as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error


def patch_dir(variable: str, pf: str) -> pathlib.Path:
    path = pathlib.Path(os.environ.get(variable) or REPO / "patches" / pf)
    if not path.is_dir():
        raise RuntimeError(f"{variable}: {path} is not a directory")
    return path


class EbuildMatchesLockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ebuild = read(os.environ.get("ZP_EBUILD") or SCRATCH_EBUILD)
        lock = os.environ.get("ZP_LOCK") or str(pathlib.Path(required("ZP_TREE")) / "Cargo.lock")
        cls.packages = lock_packages(read(lock))
        if not cls.packages:
            raise RuntimeError(f"{lock} lists no [[package]]")
        cls.git = ebuild_git_crates(cls.ebuild)

    def test_egit_commit_is_a4b39c38(self):
        self.assertEqual(egit_commit(self.ebuild), A4B3)

    def test_crates_equal_the_locks_registry_packages(self):
        crates, registry = ebuild_crates(self.ebuild), lock_registry(self.packages)
        missing, extra = registry - crates, crates - registry
        self.assertFalse(missing or extra,
                         f"\n  in the lock, not in CRATES ({len(missing)}): {shown(missing)}"
                         f"\n  in CRATES, not in the lock ({len(extra)}): {shown(extra)}")

    def test_tree_sitter_go_and_crash_context_left_crates(self):
        crates = ebuild_crates(self.ebuild)
        left = crates_named(crates, "tree-sitter-go") | crates_named(crates, "crash-context")
        self.assertEqual(left, set(), "now git packages of the lock; a registry spelling would fetch the wrong source")

    def test_git_crates_match_the_locks_git_packages(self):
        problems = git_differences(lock_git(self.packages), self.git)
        self.assertEqual(problems, [], "\n  " + "\n  ".join(problems))

    def test_the_moved_git_crates_name_their_new_full_commits(self):
        wrong = [f"{name}: {self.git.get(name, '<missing>')}" for name, commit in sorted(MOVES.items())
                 if self.git.get(name, "").split(";")[1:2] != [commit]]
        self.assertEqual(wrong, [], "\n  " + "\n  ".join(wrong))

    def test_tree_sitter_is_still_under_lib(self):
        self.assertEqual(self.git.get("tree-sitter"), TREE_SITTER_ENTRY)

    def test_tree_sitter_go_and_crash_context_are_new_git_entries(self):
        self.assertEqual({name: self.git.get(name) for name in NEW_GIT_ENTRIES}, NEW_GIT_ENTRIES)


class SeriesCarriedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.new = patch_dir("ZP_NEW_PATCHES", NEW_PF)
        cls.old = patch_dir("ZP_OLD_PATCHES", OLD_PF)
        cls.old_series = series_entries(read(cls.old / "series"))
        if len(cls.old_series) != SERIES_SIZE:
            raise RuntimeError(f"{cls.old}/series lists {len(cls.old_series)} patches, not {SERIES_SIZE}")

    def test_the_directory_holds_the_same_67_patch_files_and_nothing_else(self):
        new = {p.name for p in self.new.iterdir()}
        old = {p.name for p in self.old.iterdir()}
        self.assertFalse(new ^ old, f"\n  only in {self.new.name}: {shown(new - old)}"
                                    f"\n  only in {self.old.name}: {shown(old - new)}")

    def test_the_series_lists_them_in_the_same_order(self):
        self.assertEqual(series_entries(read(self.new / "series")), self.old_series)

    def test_headers_are_preserved_but_for_review_paragraphs(self):
        changed = []
        for name in self.old_series:
            old_header, _ = split_patch(read(self.old / name))
            new_header, _ = split_patch(read(self.new / name))
            if without_review_paragraphs(new_header) != without_review_paragraphs(old_header):
                changed.append(name)
        self.assertEqual(changed, [], "headers edited beyond an appended 'a4b39c38 review:' paragraph")

    def test_the_series_adds_no_checkpoint_line(self):
        hits = []
        for name in self.old_series:
            _, body = split_patch(read(self.new / name))
            hits += [f"{name}: {line.strip()}" for line in added_checkpoint_lines(body)]
        self.assertEqual(hits, [], "\n  " + "\n  ".join(hits))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
