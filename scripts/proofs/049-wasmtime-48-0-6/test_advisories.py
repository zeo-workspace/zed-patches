#!/usr/bin/env python3
"""Story 049, task 2.2 — osv-scanner: the 22 wasmtime and four rustls advisories gone, nothing new (R1.3, Q7).

    ZP_TREE=<patched tree> [ZP_BASE_TREE=<unpatched tree>] [ZP_OSV_OFFLINE=1] python3 test_advisories.py

Online by default (osv.dev); ZP_OSV_OFFLINE=1 uses the scanner's cached local databases. A
scanner that breaks (exit other than 0 or 1, or 1 with no report) is an ERROR, never a pass.

osv-scanner infers the lockfile format from the file NAME: a copy called `base.lock` scans
nothing and, on some versions, reads as clean (measured 2026-10-17). So a lockfile not named
`Cargo.lock` is refused before the scanner runs, and a scan whose stderr does not report a
positive package count is refused after it.

Advisories are compared by their whole alias set, so one advisory reported under its GHSA id in
one run and its RUSTSEC id in the other is the same advisory, not a new one. A closed id is
looked for on EVERY package, not only on wasmtime/wasmtime-wasi/rustls: reported against any
crate, it is not closed.
"""

import json
import os
import pathlib
import re
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import CLOSED, base_tree, tree  # noqa: E402


def packages_scanned(stderr: str) -> int:
    m = re.search(r"found (\d+) packages", stderr)
    return int(m.group(1)) if m else 0


def scan(lockfile) -> list:
    """[(package, version, frozenset(id + aliases))]."""
    lockfile = pathlib.Path(lockfile)
    if lockfile.name != "Cargo.lock":
        raise ValueError(f"{lockfile}: osv-scanner infers the format from the name; a lockfile not named Cargo.lock scans nothing")
    cmd = ["osv-scanner", "scan", "source", "--format", "json", "--lockfile", str(lockfile)]
    if os.environ.get("ZP_OSV_OFFLINE") == "1":
        cmd[3:3] = ["--offline-vulnerabilities"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode not in (0, 1) or (r.returncode == 1 and not r.stdout.strip()):
        raise RuntimeError(f"osv-scanner exited {r.returncode}: {r.stderr.strip()[-400:]}")
    if packages_scanned(r.stderr) == 0:
        raise RuntimeError(f"osv-scanner reports no package scanned in {lockfile}: {r.stderr.strip()[-400:]}")
    return parse(json.loads(r.stdout)) if r.returncode == 1 else []


def parse(report: dict) -> list:
    out = []
    for result in report.get("results", []):
        for pkg in result.get("packages", []):
            for vuln in pkg.get("vulnerabilities", []):
                ids = frozenset([vuln["id"], *vuln.get("aliases", [])])
                out.append((pkg["package"]["name"], pkg["package"]["version"], ids))
    return out


def closed_still_reported(findings: list) -> list:
    return sorted(
        f"{name} {version}: {sorted(ids & set(CLOSED))}"
        for name, version, ids in findings
        if ids & set(CLOSED)
    )


def new_advisories(base: list, patched: list) -> list:
    known = [ids for _, _, ids in base]
    return sorted(
        f"{name} {version}: {sorted(ids)}"
        for name, version, ids in patched
        if not any(ids & k for k in known)
    )


def report(*findings) -> dict:
    return {"results": [{"packages": [
        {"package": {"name": n, "version": v}, "vulnerabilities": [{"id": i, "aliases": list(a)}]}
        for n, v, i, a in findings
    ]}]}


class HostileFixtures(unittest.TestCase):
    # The scanner reads nothing from a misnamed lockfile; that must never read as clean.
    def test_a_lockfile_not_named_cargo_lock_is_refused(self):
        with self.assertRaisesRegex(ValueError, "not named Cargo.lock"):
            scan("/tmp/zp049-nonexistent/base.lock")

    def test_a_scan_that_found_no_package_is_refused(self):
        self.assertEqual(packages_scanned("End status: 0 dirs visited, 1 inodes visited, 0 Extract calls"), 0)
        self.assertEqual(packages_scanned("Scanned /t/Cargo.lock file and found 1798 packages"), 1798)

    # A closed advisory reported only under its GHSA id must still count as reported.
    def test_a_closed_advisory_matched_only_by_alias_is_still_reported(self):
        f = parse(report(("wasmtime-wasi", "48.0.4", "GHSA-m9f7-9w4p-gv38", ["RUSTSEC-2026-0352"])))
        self.assertEqual(len(closed_still_reported(f)), 1)

    # Third element: a closed id reported against another crate of the family is still open.
    def test_a_closed_advisory_on_another_crate_is_still_reported(self):
        f = parse(report(("wasmtime-environ", "48.0.6", "RUSTSEC-2026-0325", [])))
        self.assertEqual(closed_still_reported(f), ["wasmtime-environ 48.0.6: ['RUSTSEC-2026-0325']"])

    def test_every_rustls_id_counts(self):
        f = parse(report(*[("rustls", "0.23.45", f"RUSTSEC-2026-{n:04d}", []) for n in (346, 347, 348, 349)]))
        self.assertEqual(len(closed_still_reported(f)), 4)

    # Wrongly split: the same advisory under its other id is not new.
    def test_the_same_advisory_under_its_other_id_is_not_new(self):
        base = parse(report(("quick-xml", "0.1.0", "RUSTSEC-2099-0001", ["GHSA-aaaa"])))
        new = parse(report(("quick-xml", "0.1.0", "GHSA-aaaa", ["RUSTSEC-2099-0001"])))
        self.assertEqual(new_advisories(base, new), [])

    # Wrongly collapsed: a different advisory on a crate already reported is new.
    def test_a_different_advisory_on_an_already_reported_crate_is_new(self):
        base = parse(report(("quick-xml", "0.1.0", "RUSTSEC-2099-0001", [])))
        new = parse(report(("quick-xml", "0.1.0", "RUSTSEC-2099-0001", []), ("quick-xml", "0.1.0", "RUSTSEC-2099-0002", [])))
        self.assertEqual(len(new_advisories(base, new)), 1)

    # Wrongly collapsed: rustls-pemfile's advisory is not rustls's, and is not one of the 26.
    def test_an_advisory_on_a_rustls_named_crate_is_not_a_closed_one(self):
        f = parse(report(("rustls-pemfile", "2.2.0", "RUSTSEC-2025-0134", [])))
        self.assertEqual(closed_still_reported(f), [])

    def test_a_clean_tree_passes(self):
        f = parse(report(("rsa", "0.9.10", "RUSTSEC-2023-0071", [])))
        self.assertEqual(closed_still_reported(f), [])


class PatchedTree(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patched = scan(tree() / "Cargo.lock")
        cls.base = scan(base_tree() / "Cargo.lock")

    def test_r1_3_the_26_advisories_are_gone(self):
        v = closed_still_reported(self.patched)
        self.assertEqual(v, [], "\n" + "\n".join(v))

    def test_q7_no_advisory_absent_from_the_baseline(self):
        v = new_advisories(self.base, self.patched)
        self.assertEqual(v, [], "\n" + "\n".join(v))


if __name__ == "__main__":
    unittest.main(verbosity=2)
