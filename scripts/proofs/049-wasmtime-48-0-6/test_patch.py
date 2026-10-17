#!/usr/bin/env python3
"""Story 049, task 3.1 — the fix as one unconditional, explained series patch on main (R3.2, R1.4, Q1, R4.3).

    [ZP_REF=main] [ZP_PF=<PF>] python3 test_patch.py

Reads the series and the patch from the git ref, never from a checkout (the zed-patches checkout
is shared between sessions). The PF is ZP_PF when set, else the newest patches/<PF>/ directory
on the ref that holds an NNNN-wasmtime-48-0-6-rustls-0-23-46.patch, newest by package version.
"""

import collections
import re
import sys
import unittest

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from _common import CLOSED, OLD_VERSION, RUSTLS_OLD, choose_pf, fix_patches, git, git_show, pf_key, ref, ver  # noqa: E402

FILE = "0063-wasmtime-48-0-6-rustls-0-23-46.patch"


def header(text: str):
    lines = text.splitlines()
    return lines[: lines.index("---")] if "---" in lines else None


def diff_paths(text: str) -> list:
    return re.findall(r"^diff --git a/(\S+) b/", text, re.M)


def lock_changes(text: str) -> tuple:
    """([(name, old, new)], [(name, old)]) — moves and drops read from the patch's Cargo.lock hunks.

    The old side's package name comes from context and '-' lines, the new side's from context
    and '+' lines, so a block the diff removed and re-added is still one move.
    """
    removed, added = collections.defaultdict(list), collections.defaultdict(list)
    old_name = new_name = None
    in_lock = False
    for line in text.splitlines():
        if line.startswith("diff --git "):
            in_lock = line == "diff --git a/Cargo.lock b/Cargo.lock"
            old_name = new_name = None
            continue
        if not in_lock:
            continue
        m = re.match(r'^([ +-])name = "(.+)"$', line)
        if m:
            sign, name = m.groups()
            if sign in " -":
                old_name = name
            if sign in " +":
                new_name = name
            continue
        m = re.match(r'^([+-])version = "(.+)"$', line)
        if m:
            if m.group(1) == "-" and old_name:
                removed[old_name].append(m.group(2))
            elif m.group(1) == "+" and new_name:
                added[new_name].append(m.group(2))
    moves, drops = [], []
    for name in sorted(removed):
        olds, news = sorted(removed[name], key=ver), sorted(added.get(name, []), key=ver)
        moves += [(name, o, n) for o, n in zip(olds, news)]
        drops += [(name, o) for o in olds[len(news):]]
    return moves, drops


def _word(name: str):
    return re.compile(rf"(?<![\w-]){re.escape(name)}(?![\w-])")


def header_move_violations(head: list, moves: list, drops: list | None = None) -> list:
    drops = drops or []
    out = []
    for name, old, new in moves:
        if not any(_word(name).search(l) and old in l and new in l for l in head):
            out.append(f"header does not list {name} {old} -> {new}")
    for name, old in drops:
        if not any(_word(name).search(l) and old in l and re.search(r"(?i)\b(dropped|removed)\b", l) for l in head):
            out.append(f"header does not list {name} {old} as dropped")
    return out


def series_violations(series: str, files: list, number: str, filename: str) -> list:
    out = []
    lines = series.splitlines()
    entries = [l.strip() for l in lines if l.strip() and not l.lstrip().startswith("#")]
    if entries.count(filename) != 1:
        out.append(f"{filename} is registered {entries.count(filename)} times in series")
    numbered = [f for f in files if f[:4] == number] + [e for e in entries if e[:4] == number and e != filename]
    if len(set(numbered)) != 1:
        out.append(f"number {number} is not unique: {sorted(set(numbered))}")
    feature = next((i for i, l in enumerate(lines) if l.startswith("# @feature:")), len(lines))
    at = next((i for i, l in enumerate(lines) if l.strip() == filename), None)
    if at is not None and at > feature:
        out.append(f"{filename} sits under a USE-flag group; it must be unconditional")
    if at is not None and not any(l.startswith("#") and number in l for l in lines[max(0, at - 15):at]):
        out.append(f"no series comment names {number} above its entry")
    return out


class HostileFixtures(unittest.TestCase):
    SERIES = f"# 0018: x\n0018-a.patch\n# 0063: the fix\n{FILE}\n\n# @feature: claude-agent-acp-plus\n0001-b.patch\n"

    # The PF is chosen by package version: string order would pick -r2 over -r10, 0.9 over 0.10.
    def test_the_newest_pf_is_the_newest_version_not_the_last_string(self):
        self.assertGreater(pf_key("zeo-0.5.0_p20261016-r10"), pf_key("zeo-0.5.0_p20261016-r2"))
        self.assertGreater(pf_key("zeo-0.10.0_p20261101"), pf_key("zeo-0.9.0_p20261201"))
        self.assertGreater(pf_key("zeo-0.5.0_p20261016-r1"), pf_key("zeo-0.5.0_p20261016"))
        self.assertGreater(pf_key("zeo-0.1.0_p20261001"), pf_key("zed-1.24.0_pre20261001-r1"))
        found = [(pf, "0063", f"patches/{pf}/{FILE}") for pf in
                 ("zeo-0.5.0_p20261016-r2", "zeo-0.5.0_p20261016-r10", "zed-1.24.0_pre20261001-r1")]
        self.assertEqual(choose_pf(found, None)[0], "zeo-0.5.0_p20261016-r10")

    # ZP_PF names one directory: a patch present only in another PF must not stand in for it.
    def test_a_pinned_pf_without_the_patch_finds_nothing(self):
        found = [("zeo-0.5.0_p20261016-r1", "0063", f"patches/zeo-0.5.0_p20261016-r1/{FILE}")]
        self.assertEqual(choose_pf(found, "zeo-0.5.0_p20261017"), ("zeo-0.5.0_p20261017", []))

    def test_an_unparseable_pf_name_is_an_error_not_a_guess(self):
        with self.assertRaises(ValueError):
            pf_key("scratch")

    def test_a_number_another_patch_already_holds_is_refused(self):
        files = ["0018-a.patch", "0001-b.patch", FILE, "0063-other.patch"]
        v = series_violations(self.SERIES, files, "0063", FILE)
        self.assertTrue(any("not unique" in m for m in v), v)

    def test_a_patch_registered_twice_is_refused(self):
        v = series_violations(self.SERIES + FILE + "\n", ["0018-a.patch", FILE], "0063", FILE)
        self.assertTrue(any("registered 2 times" in m for m in v), v)

    def test_a_patch_under_a_use_flag_group_is_refused(self):
        series = f"# 0018: x\n0018-a.patch\n# @feature: claude-code-ide\n# 0063: the fix\n{FILE}\n"
        v = series_violations(series, ["0018-a.patch", FILE], "0063", FILE)
        self.assertTrue(any("USE-flag group" in m for m in v), v)

    # Third element: "wasmtime-wasi 48.0.1 -> 48.0.6" contains "wasmtime" but does not list it.
    def test_a_longer_name_does_not_stand_in_for_wasmtime(self):
        head = ["  wasmtime-wasi 48.0.1 -> 48.0.6"]
        self.assertEqual(header_move_violations(head, [("wasmtime", "48.0.1", "48.0.6")]),
                         ["header does not list wasmtime 48.0.1 -> 48.0.6"])

    # Same shape for rustls: tokio-rustls and rustls-pemfile are not rustls.
    def test_a_rustls_named_crate_does_not_stand_in_for_rustls(self):
        head = ["  tokio-rustls 0.23.45 -> 0.23.46", "  rustls-pemfile 0.23.45 -> 0.23.46"]
        self.assertEqual(len(header_move_violations(head, [("rustls", "0.23.45", "0.23.46")])), 1)

    # Several wasmparser lines are locked; the header must name the line that moved.
    def test_the_moved_line_of_a_multi_version_crate_is_the_one_listed(self):
        diff = ("diff --git a/Cargo.lock b/Cargo.lock\n"
                ' name = "wasmparser"\n version = "0.244.0"\n'
                ' name = "wasmparser"\n-version = "0.254.0"\n+version = "0.254.2"\n')
        moves, drops = lock_changes(diff)
        self.assertEqual((moves, drops), ([("wasmparser", "0.254.0", "0.254.2")], []))
        self.assertEqual(len(header_move_violations(["wasmparser 0.244.0 -> 0.254.2"], moves)), 1)
        self.assertEqual(header_move_violations(["wasmparser 0.254.0 -> 0.254.2"], moves), [])

    # R1.4 — a dropped crate is part of what moved, and must be listed as such.
    def test_a_dropped_crate_must_be_listed_as_dropped(self):
        diff = ("diff --git a/Cargo.lock b/Cargo.lock\n"
                '-[[package]]\n-name = "cap-std"\n-version = "4.0.3"\n-source = "registry+x"\n'
                ' [[package]]\n name = "wasmtime"\n-version = "48.0.1"\n+version = "48.0.6"\n')
        moves, drops = lock_changes(diff)
        self.assertEqual((moves, drops), ([("wasmtime", "48.0.1", "48.0.6")], [("cap-std", "4.0.3")]))
        head = ["wasmtime 48.0.1 -> 48.0.6", "cap-std 4.0.3"]
        self.assertEqual(header_move_violations(head, moves, drops), ["header does not list cap-std 4.0.3 as dropped"])
        self.assertEqual(header_move_violations(head[:1] + ["cap-std 4.0.3 dropped"], moves, drops), [])

    # A block the diff removed and re-added under the same name is one move, not a drop.
    def test_a_rewritten_block_is_a_move_not_a_drop(self):
        diff = ("diff --git a/Cargo.lock b/Cargo.lock\n"
                '-name = "rustls"\n-version = "0.23.45"\n+name = "rustls"\n+version = "0.23.46"\n')
        self.assertEqual(lock_changes(diff), ([("rustls", "0.23.45", "0.23.46")], []))

    def test_a_well_formed_registration_passes(self):
        v = series_violations(self.SERIES, ["0018-a.patch", "0001-b.patch", FILE], "0063", FILE)
        self.assertEqual(v, [])


class MainPatch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pf, found = fix_patches()
        if len(found) != 1:
            raise AssertionError(
                f"expected one NNNN-wasmtime-48-0-6-rustls-0-23-46.patch in patches/{pf or '<PF>'}/ on {ref()}, "
                f"found {[p for _, p in found]}")
        cls.pf = pf
        cls.number, cls.path = found[0]
        cls.text = git_show(cls.path)
        cls.head = header(cls.text)

    def test_the_header_keeps_its_separator_and_carries_reasoning(self):
        self.assertIsNotNone(self.head, "no '---' line: was the patch made with --no-stat?")
        assert self.head is not None
        self.assertGreaterEqual(len(self.head), 30)

    def test_q1_r4_3_only_cargo_toml_and_cargo_lock_change(self):
        self.assertEqual(sorted(diff_paths(self.text)), ["Cargo.lock", "Cargo.toml"])

    def test_r3_2_the_header_names_every_advisory_and_upstreams_state(self):
        text = "\n".join(self.head or [])
        missing = [i for i in CLOSED if i not in text]
        self.assertEqual(missing, [], "advisories not named in the header")
        self.assertIn(OLD_VERSION, text)
        self.assertIn(RUSTLS_OLD, text)
        self.assertRegex(text, r"(?i)upstream")

    def test_r1_4_the_header_lists_every_moved_and_dropped_crate(self):
        moves, drops = lock_changes(self.text)
        self.assertTrue(any(n == "wasmtime" for n, _, _ in moves), "the patch does not move wasmtime")
        self.assertTrue(any(n == "rustls" for n, _, _ in moves), "the patch does not move rustls")
        v = header_move_violations(self.head or [], moves, drops)
        self.assertEqual(v, [], "\n" + "\n".join(v))

    def test_registered_once_unconditionally_under_a_unique_number(self):
        series = git_show(f"patches/{self.pf}/series")
        files = [p.rsplit("/", 1)[1] for p in git("ls-tree", "--name-only", ref(), f"patches/{self.pf}/").splitlines()]
        v = series_violations(series, [f for f in files if f.endswith(".patch")], self.number, self.path.rsplit("/", 1)[1])
        self.assertEqual(v, [], "\n" + "\n".join(v))


if __name__ == "__main__":
    unittest.main(verbosity=2)
