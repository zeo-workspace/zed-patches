#!/usr/bin/env python3
"""Story 049, task 5.2 — the overlay revision fetches what the patched lockfile names (R2.1, R2.2).

    ZP_EBUILD=<zeo-<PF>-rN.ebuild> ZP_TREE=<patched tree> [ZP_BASE_TREE=<unpatched tree>]
    [ZP_REF=main] [ZP_PF=<PF>] [ZP_OVERLAY=/tmp/zp-overlay-049] [ZP_DISTDIR=/var/cache/distfiles]
    python3 test_ebuild.py

The fix patch's file name is read from the PF's directory on the ref. With ZP_OVERLAY set, every
crate in CRATES that the unpatched lockfile did not hold needs a Manifest DIST line in
<overlay>/app-editors/zeo/Manifest, and the .crate downloaded into ZP_DISTDIR must match its
size, BLAKE2B and SHA512. A .crate that was never downloaded is a failure: a DIST line nobody
checked against the file is the trap story 033 fell into.
"""

import hashlib
import os
import pathlib
import re
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    FIX_VERSION, OLD_VERSION, RUSTLS_FIX, RUSTLS_OLD, base_tree, ebuild_text, fix_patches, lock_packages, tree,
)

PINS = (f"wasmtime@{FIX_VERSION}", f"wasmtime-wasi@{FIX_VERSION}", f"rustls@{RUSTLS_FIX}")
FILE = "0064-wasmtime-48-0-6-rustls-0-23-46.patch"


def crates(ebuild: str) -> set:
    m = re.search(r'^CRATES="\n(.*?)^"', ebuild, re.M | re.S)
    return {l.strip() for l in (m.group(1) if m else "").splitlines() if l.strip()}


def split_crate(entry: str) -> tuple:
    name, _, version = entry.partition("@")
    return name, version


def registry_set(lock_text: str) -> set:
    return {f"{n}@{v}" for n, v, k in lock_packages(lock_text) if k == "registry"}


def pin_violations(entries: set) -> list:
    out = [f"{p} not in CRATES" for p in PINS if p not in entries]
    for entry in sorted(entries):
        name, version = split_crate(entry)
        if (name.startswith("wasmtime") or name.startswith("pulley-")) and version == OLD_VERSION:
            out.append(f"{entry} left in CRATES")
        if name == "rustls" and version == RUSTLS_OLD:
            out.append(f"{entry} left in CRATES")
    return out


def patch_depths(ebuild: str, filename: str) -> list:
    """Nesting depth of each non-comment line in src_prepare() that names filename."""
    out, depth, inside = [], 0, False
    for line in ebuild.splitlines():
        s = line.strip()
        if re.match(r"^src_prepare\(\)\s*\{", s):
            inside, depth = True, 0
            continue
        if not inside or s.startswith("#"):
            continue
        if s == "}" and depth == 0:
            break
        if re.match(r"^(if|case)\b", s):
            depth += 1
        if filename in s:
            out.append(depth)
        if re.match(r"^(fi|esac)\b", s):
            depth -= 1
    return out


def dist_violations(manifest: str, new: set, distdir: pathlib.Path) -> list:
    out = []
    for entry in sorted(new):
        name, version = split_crate(entry)
        fname = f"{name}-{version}.crate"
        m = re.search(rf"^DIST {re.escape(fname)} (\d+) BLAKE2B ([0-9a-f]+) SHA512 ([0-9a-f]+)$", manifest, re.M)
        if not m:
            out.append(f"no DIST line for {fname}")
            continue
        f = distdir / fname
        if not f.is_file():
            out.append(f"{fname} is not in {distdir}: its DIST line was never checked against the file")
            continue
        data = f.read_bytes()
        if (str(len(data)), hashlib.blake2b(data).hexdigest(), hashlib.sha512(data).hexdigest()) != m.groups():
            out.append(f"DIST line for {fname} does not match the downloaded file")
    return out


GOOD_PINS = {"wasmtime@48.0.6", "wasmtime-wasi@48.0.6", "wasmtime-c-api-impl@48.0.6", "rustls@0.23.46", "tokio-rustls@0.26.4"}


class HostileFixtures(unittest.TestCase):
    # Build metadata is part of the version, and of the distfile name.
    def test_build_metadata_stays_in_the_version(self):
        self.assertEqual(split_crate("ash@0.38.0+1.3.281"), ("ash", "0.38.0+1.3.281"))

    # Wrongly collapsed: two lines of one crate are two entries, not one.
    def test_two_lines_of_one_crate_are_two_entries(self):
        e = 'CRATES="\n\twasmparser@0.244.0\n\twasmparser@0.254.2\n"\n'
        self.assertEqual(crates(e), {"wasmparser@0.244.0", "wasmparser@0.254.2"})

    # Wrongly split: a stale 48.0.1 left beside 48.0.6 is an extra entry the lock lacks.
    def test_a_stale_entry_beside_the_new_one_is_a_difference(self):
        e = 'CRATES="\n\twasmtime@48.0.1\n\twasmtime@48.0.6\n"\n'
        self.assertEqual(crates(e) - {"wasmtime@48.0.6"}, {"wasmtime@48.0.1"})
        self.assertEqual(pin_violations(GOOD_PINS | crates(e)), ["wasmtime@48.0.1 left in CRATES"])

    def test_a_family_crate_or_rustls_left_behind_is_refused(self):
        v = pin_violations(GOOD_PINS | {"wasmtime-c-api-impl@48.0.1", "rustls@0.23.45"})
        self.assertEqual(v, ["rustls@0.23.45 left in CRATES", "wasmtime-c-api-impl@48.0.1 left in CRATES"])

    # Third element: a longer name holding the right version does not stand in for the pin.
    def test_a_longer_name_does_not_stand_in_for_a_pin(self):
        v = pin_violations({"wasmtime-wasi@48.0.6", "tokio-rustls@0.23.46"})
        self.assertEqual(v, ["wasmtime@48.0.6 not in CRATES", "rustls@0.23.46 not in CRATES"])

    def test_the_fixed_pins_pass(self):
        self.assertEqual(pin_violations(GOOD_PINS), [])

    def test_a_patch_inside_a_use_block_is_not_unconditional(self):
        e = ('src_prepare() {\n\tPATCHES+=( "${FILESDIR}/0018-a.patch" )\n'
             f'\t# 0064 is the fix: {FILE}\n'
             f'\tif use x; then\n\t\tPATCHES+=( "${{FILESDIR}}/{FILE}" )\n\tfi\n\tcargo_src_prepare\n}}\n')
        self.assertEqual(patch_depths(e, FILE), [1])

    # A comment, or a line in another phase, is not the patch being applied.
    def test_a_mention_outside_src_prepares_code_does_not_count(self):
        e = (f'pkg_setup() {{\n\tPATCHES+=( "${{FILESDIR}}/{FILE}" )\n}}\n'
             f'src_prepare() {{\n\t# {FILE} carries the fix\n\tcargo_src_prepare\n}}\n')
        self.assertEqual(patch_depths(e, FILE), [])

    def test_a_patch_applied_twice_is_two_lines(self):
        e = f'src_prepare() {{\n\tPATCHES+=( "${{FILESDIR}}/{FILE}" )\n\tPATCHES+=( "${{FILESDIR}}/{FILE}" )\n}}\n'
        self.assertEqual(patch_depths(e, FILE), [0, 0])

    def test_a_patch_at_top_level_is_unconditional(self):
        e = f'src_prepare() {{\n\tif use y; then\n\t\t:\n\tfi\n\tPATCHES+=( "${{FILESDIR}}/{FILE}" )\n}}\n'
        self.assertEqual(patch_depths(e, FILE), [0])

    def test_a_dist_line_that_does_not_match_the_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "x-1.0.0.crate").write_bytes(b"crate")
            good = hashlib.blake2b(b"crate").hexdigest(), hashlib.sha512(b"crate").hexdigest()
            ok = f"DIST x-1.0.0.crate 5 BLAKE2B {good[0]} SHA512 {good[1]}\n"
            bad = f"DIST x-1.0.0.crate 6 BLAKE2B {good[0]} SHA512 {good[1]}\n"
            self.assertEqual(dist_violations(ok, {"x@1.0.0"}, pathlib.Path(d)), [])
            self.assertEqual(len(dist_violations(bad, {"x@1.0.0"}, pathlib.Path(d))), 1)

    def test_a_dist_line_for_a_crate_never_downloaded_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            line = f"DIST y-1.0.0.crate 5 BLAKE2B {'0' * 128} SHA512 {'0' * 128}\n"
            v = dist_violations(line, {"y@1.0.0"}, pathlib.Path(d))
            self.assertTrue(v and "never checked" in v[0], v)


class OverlayRevision(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ebuild = ebuild_text()
        cls.crates = crates(cls.ebuild)
        cls.lock = registry_set((tree() / "Cargo.lock").read_text())

    def test_r2_1_crates_equal_the_patched_lockfiles_registry_packages(self):
        self.assertEqual(sorted(self.crates - self.lock), [], "in CRATES, not in Cargo.lock")
        self.assertEqual(sorted(self.lock - self.crates), [], "in Cargo.lock, not in CRATES")

    def test_r2_1_crates_carry_wasmtime_48_0_6_and_rustls_0_23_46(self):
        v = pin_violations(self.crates)
        self.assertEqual(v, [], "\n" + "\n".join(v))

    def test_the_patch_is_applied_once_and_unconditionally(self):
        pf, found = fix_patches()
        self.assertEqual(len(found), 1, f"no single NNNN-wasmtime-48-0-6-rustls-0-23-46.patch in patches/{pf or '<PF>'}/")
        filename = found[0][1].rsplit("/", 1)[1]
        self.assertEqual(patch_depths(self.ebuild, filename), [0])

    def test_r2_2_every_new_crate_has_a_matching_dist_line(self):
        overlay = os.environ.get("ZP_OVERLAY")
        if not overlay:
            self.skipTest("ZP_OVERLAY not set: the /tmp overlay copy is checked by `ebuild … prepare`")
        manifest = (pathlib.Path(overlay) / "app-editors" / "zeo" / "Manifest").read_text()
        new = self.crates - registry_set((base_tree() / "Cargo.lock").read_text())
        self.assertTrue(new, "no crate in CRATES is new against the unpatched lockfile: nothing moved")
        v = dist_violations(manifest, new, pathlib.Path(os.environ.get("ZP_DISTDIR", "/var/cache/distfiles")))
        self.assertEqual(v, [], "\n" + "\n".join(v))


if __name__ == "__main__":
    unittest.main(verbosity=2)
