#!/usr/bin/env python3
"""Story 049, task 5.1 — the fix recorded under [Unreleased] in zeo/CHANGELOG.md (R3.1).

    [ZP_CHANGELOG=<zeo/CHANGELOG.md>] [ZP_REF=main] [ZP_PF=<PF>] [ZP_FIX_NUMBER=NNNN] python3 test_changelog.py

The entry must sit in a `### Security` group of the Unreleased section, name the reachable
wasmtime and rustls advisories (RUSTSEC-2026-0314, -0325, -0359, -0363, -0364, -0349) in ONE entry, and
end with `(patch NNNN)` where NNNN is the fix patch's number in the PF's directory on the ref.
"""

import os
import pathlib
import re
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import CHANGELOG_IDS, fix_patches, hub  # noqa: E402


def unreleased(text: str) -> str:
    m = re.search(r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    return m.group(1) if m else ""


def entry_violations(text: str, number: str) -> list:
    section = unreleased(text)
    m = re.search(r"^### Security[^\n]*\n(.*?)(?=^### |\Z)", section, re.M | re.S)
    if not m:
        return ["no ### Security group under ## [Unreleased]"]
    entries = re.split(r"\n(?=- )", m.group(1))
    for e in entries:
        # zeo/CHANGELOG.md entries end "(patch NNNN)." -- the period is house style, optional here.
        if all(i in e for i in CHANGELOG_IDS) and re.search(rf"\(patch {number}\)\.?\s*$", e.strip()):
            return []
    return [f"no Security entry names {', '.join(CHANGELOG_IDS)} and ends with (patch {number})"]


IDS = ", ".join(CHANGELOG_IDS)
GOOD = "- An extension could crash Zeo or corrupt WebAssembly memory, and HTTPS could be weakened ({ids}); wasmtime 48.0.6 and rustls 0.23.46 fix them (patch 0064)\n"


class HostileFixtures(unittest.TestCase):
    def test_an_entry_in_a_released_section_does_not_count(self):
        text = "## [Unreleased]\n\n## [0.5.0] — 2026-10-14\n### Security\n" + GOOD.format(ids=IDS)
        self.assertEqual(len(entry_violations(text, "0064")), 1)

    # Third element: another patch number in the same section must not satisfy it.
    def test_another_patch_number_does_not_stand_in(self):
        text = "## [Unreleased]\n### Security\n" + GOOD.format(ids=IDS).replace("0064", "0063")
        self.assertEqual(len(entry_violations(text, "0064")), 1)

    def test_the_entry_under_another_group_does_not_count(self):
        text = "## [Unreleased]\n### Fixed\n" + GOOD.format(ids=IDS)
        self.assertEqual(len(entry_violations(text, "0064")), 1)

    def test_ids_split_across_entries_do_not_count(self):
        text = ("## [Unreleased]\n### Security\n- RUSTSEC-2026-0314, RUSTSEC-2026-0325, RUSTSEC-2026-0359 (patch 0064)\n"
                "- RUSTSEC-2026-0363, RUSTSEC-2026-0364, RUSTSEC-2026-0349 (patch 0064)\n")
        self.assertEqual(len(entry_violations(text, "0064")), 1)

    # The v1/v2 entries (0352 and 0326 claimed reachable) miss 0359, 0363 and 0364; and rustls's 0349 is required.
    def test_an_entry_with_the_superseded_ids_or_without_rustls_does_not_count(self):
        v1 = "RUSTSEC-2026-0352, RUSTSEC-2026-0314, RUSTSEC-2026-0325, RUSTSEC-2026-0326, RUSTSEC-2026-0349"
        self.assertEqual(len(entry_violations("## [Unreleased]\n### Security\n" + GOOD.format(ids=v1), "0064")), 1)
        no_rustls = ", ".join(i for i in CHANGELOG_IDS if i != "RUSTSEC-2026-0349")
        self.assertEqual(len(entry_violations("## [Unreleased]\n### Security\n" + GOOD.format(ids=no_rustls), "0064")), 1)

    def test_the_changelog_house_style_trailing_period_passes(self):
        text = "## [Unreleased]\n### Security\n" + GOOD.format(ids=IDS).replace("(patch 0064)", "(patch 0064).")
        self.assertEqual(entry_violations(text, "0064"), [])

    def test_a_well_formed_entry_passes(self):
        text = "## [Unreleased]\n### Added\n- x (patch 0063)\n\n### Security\n" + GOOD.format(ids=IDS) + "\n## [0.5.0]\n"
        self.assertEqual(entry_violations(text, "0064"), [])


class ZeoChangelog(unittest.TestCase):
    def test_r3_1_the_unreleased_security_entry(self):
        number = os.environ.get("ZP_FIX_NUMBER")  # override, e.g. before 3.1's patch is on the ref
        if not number:
            pf, found = fix_patches()
            self.assertEqual(len(found), 1, f"the fix patch's number is needed and patches/{pf or '<PF>'}/ holds no single fix patch")
            number = found[0][0]
        path = pathlib.Path(os.environ.get("ZP_CHANGELOG", hub() / "zeo" / "CHANGELOG.md"))
        v = entry_violations(path.read_text(), number)
        self.assertEqual(v, [], "\n".join(v))


if __name__ == "__main__":
    unittest.main(verbosity=2)
