#!/usr/bin/env python3
"""Story 061, task 4.1 -- the scratch ebuild describes exactly the patched a5c4ca8b source (Integration).

    ZP_EBUILD=<scratch>/app-editors/zeo/zeo-0.7.0_p20261025.ebuild \
    ZP_TREE=<zed-patches/work/zed-a5c4ca8b...>      (or ZP_LOCK=<a Cargo.lock>) \
    [ZP_SERIES=<patches/zeo-0.7.0_p20261025/series>] \
    [ZP_OLD_SERIES=<patches/zeo-0.7.0_p20261021/series>] \
    python3 -I test_ebuild.py -v

What it asserts (R2.2, R3.1, R3.2, R3.3; Q4):
  * EGIT_COMMIT is a5c4ca8bf6c4717a328a4a61b42d6d1d38949bcc;
  * CRATES is exactly the lock's registry packages, compared as name@version -- never by name,
    because the lock holds many crates at two versions;
  * GIT_CRATES has one entry per git package of the lock, each naming the lock's repository and
    the lock's full commit (the part after `#`, never the `?rev=` spelling, which may be short),
    and no entry the lock does not hold;
  * oo7 is listed exactly as R3.3 writes it, and lsp-types moved to 82d7fc66...;
  * the ebuild references patch 0064 nowhere (comment or PATCHES entry);
  * the new series lists the 0.7.0 series' patches in the same order, minus 0064 alone.

ZP_SERIES and ZP_OLD_SERIES default to the PF directories next to this file's repository
(zed-patches/patches/<PF>/series).

The parser itself is pinned first by fixtures (ComparisonHostileTests), each the input that would
make a check fire wrongly: a crate at two versions, two packages from one repository at one
commit, a `.git` suffix and a short `?rev=`, git and path packages that CRATES never holds, and
"0064" spelled inside a commit id, a crate version or a historical series comment.

Exit: unittest's -- 0 every assertion holds, 1 a failure or an error (an unset or unreadable input
is an error, never a pass).
"""

import os
import pathlib
import re
import sys
import tomllib
import unittest

A5C4 = "a5c4ca8bf6c4717a328a4a61b42d6d1d38949bcc"
OO7_ENTRY = "https://github.com/zed-industries/oo7;731c1215edb6905876c6137ab300428c7b8d7c13;oo7-%commit%/client"
LSP_TYPES_REV = "82d7fc66ebdfabcfeb26ba16bbed9f3d26211fc3"
DROPPED = "0064"
REPO = pathlib.Path(__file__).resolve().parents[3]  # zed-patches/scripts/proofs/061-a5c4-bump/
NEW_PF = "zeo-0.7.0_p20261025"
OLD_PF = "zeo-0.7.0_p20261021"


# ── Parsing: the ebuild ─────────────────────────────────────────────────────
def ebuild_crates(ebuild: str) -> set:
    m = re.search(r'^CRATES="\n(.*?)^"', ebuild, re.M | re.S)
    if not m:
        raise ValueError("no CRATES=\"...\" block in the ebuild")
    return {line.strip() for line in m.group(1).splitlines() if line.strip()}


def ebuild_git_crates(ebuild: str) -> dict:
    m = re.search(r"^declare -A GIT_CRATES=\(\n(.*?)^\)", ebuild, re.M | re.S)
    if not m:
        raise ValueError("no declare -A GIT_CRATES=( ... ) block in the ebuild")
    return dict(re.findall(r"^\s*\[([^\]]+)\]='([^']*)'", m.group(1), re.M))


def egit_commit(ebuild: str) -> str:
    m = re.search(r'^EGIT_COMMIT="([^"]*)"', ebuild, re.M)
    if not m:
        raise ValueError("no EGIT_COMMIT=\"...\" line in the ebuild")
    return m.group(1)


def references_patch(line: str, number: str) -> bool:
    """A patch is referenced by its file name (`0064-<slug>`) or by its number as a word in a
    comment. The digits inside a commit id, a crate version (`1.0064.0`) or a longer number are
    not a reference: a sha containing "0064" would make a plain grep fire."""
    if re.search(rf"(?<![0-9A-Za-z.@]){number}-[a-z]", line):
        return True
    comment = line.split("#", 1)[1] if "#" in line else ""
    return bool(re.search(rf"(?<![0-9A-Za-z.@]){number}(?![0-9A-Za-z.@])", comment))


# ── Parsing: the lock ───────────────────────────────────────────────────────
def lock_packages(lock_text: str) -> list:
    return tomllib.loads(lock_text).get("package", [])


def lock_registry(packages: list) -> set:
    return {f"{p['name']}@{p['version']}" for p in packages if p.get("source", "").startswith("registry+")}


def normalise_repo(url: str) -> str:
    url = url.rstrip("/")
    return url[: -len(".git")] if url.endswith(".git") else url


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


def series_entries(text: str) -> list:
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def shown(items, limit=20) -> str:
    items = sorted(items)
    more = f" ... and {len(items) - limit} more" if len(items) > limit else ""
    return ", ".join(items[:limit]) + more


# ── Fixtures: what would make a check fire wrongly, before what makes it hold ──
def pkg(name, version, source=None) -> str:
    return f'[[package]]\nname = "{name}"\nversion = "{version}"\n' + (f'source = "{source}"\n' if source else "")


REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


class ComparisonHostileTests(unittest.TestCase):
    # Wrongly collapse: two things that look alike and MUST stay apart.
    def test_1_hostile_a_crate_at_two_versions_is_two_crates(self):
        lock = lock_packages(pkg("foo", "1.0.0", REGISTRY) + pkg("foo", "2.0.0", REGISTRY))
        self.assertEqual(lock_registry(lock) - {"foo@1.0.0"}, {"foo@2.0.0"},
                         "a name-keyed comparison would call foo@1.0.0 enough")

    def test_2_hostile_two_packages_of_one_repo_at_one_commit_each_need_an_entry(self):
        src = "git+https://github.com/tree-sitter/tree-sitter?rev=43623ec#43623ec9bf0eaaf7113285c46e8a09018f181b18"
        lock = lock_git(lock_packages(pkg("tree-sitter", "0.26.0", src) + pkg("tree-sitter-language", "0.1.5", src)))
        git = {"tree-sitter": "https://github.com/tree-sitter/tree-sitter;43623ec9bf0eaaf7113285c46e8a09018f181b18;tree-sitter-%commit%/lib"}
        self.assertEqual(len(git_differences(lock, git)), 1, "a repository-keyed comparison would accept one entry")

    def test_3_hostile_a_moved_rev_is_a_difference(self):
        src = f"git+https://github.com/zed-industries/lsp-types?rev={LSP_TYPES_REV}#{LSP_TYPES_REV}"
        lock = lock_git(lock_packages(pkg("lsp-types", "0.95.1", src)))
        git = {"lsp-types": "https://github.com/zed-industries/lsp-types;f1783e63a7f4eb4397bf51d4148b4895a1f7ab16;lsp-types-%commit%"}
        self.assertEqual(len(git_differences(lock, git)), 1)

    def test_4_hostile_0064_inside_a_sha_or_a_version_is_not_a_reference(self):
        for line in ('EGIT_COMMIT="ab0064cdef0123456789abcdef0123456789abcd"',
                     "\tfoo@1.0064.0",
                     "\t[bar]='https://example.org/bar;9f00640000000000000000000000000000000000;bar-%commit%'",
                     "# 10064 and 00640 are other numbers"):
            self.assertFalse(references_patch(line, DROPPED), line)

    # Wrongly split: two spellings of the same thing that MUST come together.
    def test_5_hostile_dot_git_and_a_short_rev_are_the_same_source(self):
        lock = lock_git(lock_packages(
            pkg("async-process", "2.3.0", "git+https://github.com/zed-industries/async-process.git?rev=0b6d671#0b6d6713570af61806e1e5cb40e0f757cb93fd9d")
            + pkg("wprcontrol", "0.1.0", "git+https://github.com/zed-industries/wprcontrol?rev=cd811f7#cd811f7d744f65291e13131b1d907fda63ed91a1")))
        git = {"async-process": "https://github.com/zed-industries/async-process;0b6d6713570af61806e1e5cb40e0f757cb93fd9d;async-process-%commit%",
               "wprcontrol": "https://github.com/zed-industries/wprcontrol;cd811f7d744f65291e13131b1d907fda63ed91a1;wprcontrol-%commit%"}
        self.assertEqual(git_differences(lock, git), [])

    def test_6_hostile_git_and_path_packages_are_not_registry_crates(self):
        lock = lock_packages(pkg("zed", "1.27.0") + pkg("oo7", "0.6.0", "git+https://github.com/zed-industries/oo7?rev=731c121#731c1215edb6905876c6137ab300428c7b8d7c13")
                             + pkg("serde", "1.0.228", REGISTRY))
        self.assertEqual(lock_registry(lock), {"serde@1.0.228"})

    def test_7_hostile_a_historical_series_comment_is_not_an_entry(self):
        text = "# Numbered 0065 because 0064 was the last number taken (story 036).\n0063-devtools-panel.patch\n0065-agent-sidebar-drag-reorder.patch\n"
        self.assertEqual(series_entries(text), ["0063-devtools-panel.patch", "0065-agent-sidebar-drag-reorder.patch"])

    # Benign: the references the checks exist to find.
    def test_8_a_patches_entry_and_a_comment_reference_0064(self):
        self.assertTrue(references_patch('\t\t"${FILESDIR}/0064-wasmtime-48-0-6-rustls-0-23-46.patch"', DROPPED))
        self.assertTrue(references_patch("\t\t# 0064 moves wasmtime/wasmtime-wasi 48.0.1 -> 48.0.6", DROPPED))


# ── Real data: the scratch ebuild against the patched lock ──────────────────
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


class EbuildMatchesLockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ebuild = read(required("ZP_EBUILD"))
        lock = os.environ.get("ZP_LOCK") or str(pathlib.Path(required("ZP_TREE")) / "Cargo.lock")
        cls.packages = lock_packages(read(lock))
        if not cls.packages:
            raise RuntimeError(f"{lock} lists no [[package]]")
        cls.series = read(os.environ.get("ZP_SERIES") or REPO / "patches" / NEW_PF / "series")
        cls.old_series = read(os.environ.get("ZP_OLD_SERIES") or REPO / "patches" / OLD_PF / "series")

    def test_egit_commit_is_a5c4ca8b(self):
        self.assertEqual(egit_commit(self.ebuild), A5C4)

    def test_crates_equal_the_locks_registry_packages(self):
        crates, registry = ebuild_crates(self.ebuild), lock_registry(self.packages)
        missing, extra = registry - crates, crates - registry
        self.assertFalse(missing or extra,
                         f"\n  in the lock, not in CRATES ({len(missing)}): {shown(missing)}"
                         f"\n  in CRATES, not in the lock ({len(extra)}): {shown(extra)}")

    def test_git_crates_match_the_locks_git_packages(self):
        problems = git_differences(lock_git(self.packages), ebuild_git_crates(self.ebuild))
        self.assertEqual(problems, [], "\n  " + "\n  ".join(problems))

    def test_oo7_is_listed_as_r3_3_writes_it(self):
        self.assertEqual(ebuild_git_crates(self.ebuild).get("oo7"), OO7_ENTRY)

    def test_lsp_types_moved_to_82d7fc66(self):
        entry = ebuild_git_crates(self.ebuild).get("lsp-types", "")
        self.assertEqual(entry.split(";")[1:2], [LSP_TYPES_REV], entry)

    def test_the_ebuild_references_0064_nowhere(self):
        lines = [f"{n}: {line.strip()}" for n, line in enumerate(self.ebuild.splitlines(), 1)
                 if references_patch(line, DROPPED)]
        self.assertEqual(lines, [], "\n  " + "\n  ".join(lines))

    def test_the_series_drops_0064_and_nothing_else(self):
        old, new = series_entries(self.old_series), series_entries(self.series)
        expected = [entry for entry in old if not entry.startswith(f"{DROPPED}-")]
        self.assertEqual(len(expected), len(old) - 1, "the 0.7.0 series does not hold exactly one 0064 entry")
        self.assertEqual(new, expected, "the new series must be 0.7.0's, in order, minus 0064 alone")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
