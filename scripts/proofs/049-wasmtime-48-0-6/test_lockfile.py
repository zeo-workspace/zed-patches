#!/usr/bin/env python3
"""Story 049, task 2.1 — the patched tree resolves wasmtime 48.0.6 and rustls 0.23.46 (R1.1, R1.2, R1.4, R1.5).

    ZP_TREE=<patched tree> [ZP_BASE_TREE=<unpatched tree>] python3 test_lockfile.py

The hostile fixtures run first: they pin what each rule must REFUSE (a stale 48.0.1 beside
48.0.6, a family member outside wasmtime's own tree left behind, a family crate stopped at
48.0.4, rustls left at 0.23.45, another wasm-tools line moving, an unrelated crate moving or
dropped) and what it must NOT refuse (wasm-tools names, rustls-* names, workspace members the
series adds, a crate dropped because every dependent of it moved). Comparison is on registry and
git packages only: the series adds workspace members to Cargo.lock, never registry crates.
"""

import collections
import sys
import tomllib
import unittest

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    FIX_VERSION, REGISTRY, RUSTLS_FIX, RUSTLS_OLD, WASM_TOOLS, base_tree, is_family,
    lock_dependents, lock_packages, tree, ver,
)

CRANELIFT_FLOOR, CRANELIFT_CAP = (0, 135, 6), (0, 136, 0)  # wasmtime 48.0.6 asks ^0.135.6


def family_violations(pkgs: list) -> list:
    seen = collections.defaultdict(list)
    for name, version, kind in pkgs:
        if kind != "local" and is_family(name):
            seen[name].append(version)
    out = []
    for name in ("wasmtime", "wasmtime-wasi"):
        if name not in seen:
            out.append(f"{name}: not in the lockfile")
    for name, versions in sorted(seen.items()):
        if len(versions) > 1:
            out.append(f"{name}: {len(versions)} versions locked ({', '.join(sorted(versions))}); the family must resolve to one")
        for v in versions:
            if name.startswith("cranelift-"):
                if not CRANELIFT_FLOOR <= ver(v) < CRANELIFT_CAP:
                    out.append(f"{name} {v}: outside ^0.135.6")
            elif v != FIX_VERSION:
                out.append(f"{name} {v}: expected {FIX_VERSION}")
    return out


def rustls_violations(pkgs: list) -> list:
    versions = sorted(v for n, v, k in pkgs if n == "rustls" and k != "local")
    if not versions:
        return ["rustls: not in the lockfile"]
    return [f"rustls {v}: expected {RUSTLS_FIX}" for v in versions if v != RUSTLS_FIX]


def move_violations(base: list, patched: list, base_dependents: dict | None = None) -> list:
    before = {p for p in base if p[2] != "local"}
    after = {p for p in patched if p[2] != "local"}
    added, removed = after - before, before - after
    removed_ids = {(n, v) for n, v, _ in removed}
    out = []
    if not any(n == "wasmtime" for n, _, _ in added):
        out.append("wasmtime did not move")
    if not any(n == "rustls" for n, _, _ in added):
        out.append("rustls did not move")
    for name, version, kind in sorted(added):
        if is_family(name):
            continue
        if name == "rustls" and version == RUSTLS_FIX and any(rn == "rustls" and rv == RUSTLS_OLD for rn, rv, _ in removed):
            continue
        same_line_left = any(rn == name and ver(rv)[:2] == (0, 254) for rn, rv, _ in removed)
        if name in WASM_TOOLS and ver(version)[:2] == (0, 254) and ver(version) >= (0, 254, 1) and same_line_left:
            continue
        out.append(f"{name} {version} ({kind}) entered the lockfile; it is not the wasmtime family, rustls {RUSTLS_FIX} or a 0.254 wasm-tools patch move")
    added_names = {n for n, _, _ in added}
    for name, version, kind in sorted(removed):
        if is_family(name) or name in added_names:
            continue  # a family crate 48.0.6 no longer uses, or a move judged on its added side
        # A drop is the updates' doing only when every package that depended on it left too.
        dependents = (base_dependents or {}).get((name, version), set())
        if not dependents or not dependents <= removed_ids:
            stays = sorted(f"{n} {v}" for n, v in dependents - removed_ids)
            out.append(f"{name} {version} ({kind}) left the lockfile while {stays or 'no moved package'} still depended on it")
    return out


def _floor(entry) -> tuple:
    """(version, the other keys) of a [workspace.dependencies] entry, string or table."""
    if isinstance(entry, str):
        return entry, {}
    if isinstance(entry, dict):
        return entry.get("version"), {k: v for k, v in entry.items() if k != "version"}
    return None, None


def manifest_violations(cargo_toml: str, base_cargo_toml: str) -> list:
    deps = tomllib.loads(cargo_toml).get("workspace", {}).get("dependencies", {})
    base = tomllib.loads(base_cargo_toml).get("workspace", {}).get("dependencies", {})
    out = []
    for name, want_version in (("wasmtime", FIX_VERSION), ("wasmtime-wasi", FIX_VERSION), ("rustls", RUSTLS_FIX)):
        version, rest = _floor(deps.get(name))
        _, base_rest = _floor(base.get(name))
        if version is None:
            out.append(f"[workspace.dependencies] {name}: no version ({deps.get(name)!r})")
            continue
        if version != want_version:
            out.append(f"[workspace.dependencies] {name}: version {version!r}, expected {want_version!r}")
        if name != "rustls" and rest.get("default-features") is not False:
            out.append(f"[workspace.dependencies] {name}: default-features is not false")
        want, got = set((base_rest or {}).get("features", [])), set(rest.get("features", []))
        if want != got:
            out.append(f"[workspace.dependencies] {name}: features missing {sorted(want - got)}, added {sorted(got - want)}")
        others = lambda d: {k: v for k, v in (d or {}).items() if k != "features"}  # noqa: E731
        if others(rest) != others(base_rest):
            out.append(f"[workspace.dependencies] {name}: keys other than version changed: {others(base_rest)} -> {others(rest)}")
    return out


def lock(*pkgs) -> str:
    """Fixture Cargo.lock; each package is (name, version, kind[, [dependency, ...]])."""
    parts = []
    for name, version, kind, *deps in pkgs:
        src = {"registry": f'source = "{REGISTRY}"\n', "git": 'source = "git+https://example.invalid/x#0"\n', "local": ""}[kind]
        dep = "dependencies = [" + ", ".join(f'"{d}"' for d in deps[0]) + "]\n" if deps else ""
        parts.append(f'[[package]]\nname = "{name}"\nversion = "{version}"\n{src}{dep}')
    return "\n".join(parts)


R = "registry"
FAMILY_OK = [("wasmtime", "48.0.6", R), ("wasmtime-wasi", "48.0.6", R),
             ("cranelift-codegen", "0.135.6", R), ("pulley-interpreter", "48.0.6", R), ("rustls", "0.23.46", R)]
FAMILY_OLD = [("wasmtime", "48.0.1", R), ("wasmtime-wasi", "48.0.1", R),
              ("cranelift-codegen", "0.135.1", R), ("pulley-interpreter", "48.0.1", R), ("rustls", "0.23.45", R)]
MANIFEST = """
[workspace.dependencies]
rustls = {r}
tokio-rustls = {{ version = "0.26", default-features = false }}
wasmtime = {{ version = "{v}", default-features = false, features = [{f}] }}
wasmtime-wasi = {{ version = "{v}", default-features = false, features = ["p2"] }}
[profile.dev.package]
wasmtime = {{ opt-level = 3 }}
"""
FEATURES = '"async", "runtime", "component-model"'
BASE_MANIFEST = MANIFEST.format(v="48", f=FEATURES, r='"0.23.26"')


def pkgs(*p):
    return lock_packages(lock(*p))


class HostileFixtures(unittest.TestCase):
    # R1.1 — wrongly split: the fixed version present, the vulnerable one still beside it.
    def test_a_stale_48_0_1_beside_48_0_6_is_refused(self):
        v = family_violations(pkgs(*FAMILY_OK, ("wasmtime", "48.0.1", R)))
        self.assertTrue(any("2 versions" in m for m in v), v)

    # R1.1 — third element: a wasmtime-* crate that depends ON wasmtime is not moved by
    # `cargo update -p wasmtime --precise`; tree-sitter's grammar path uses it.
    def test_wasmtime_c_api_impl_left_at_48_0_1_is_refused(self):
        v = family_violations(pkgs(*FAMILY_OK, ("wasmtime-c-api-impl", "48.0.1", R)))
        self.assertIn("wasmtime-c-api-impl 48.0.1: expected 48.0.6", v)

    # R1.1 — the v1 target is not the v2 target: a family crate stopped at 48.0.4 stays open to 0352.
    def test_a_family_crate_at_48_0_4_is_refused(self):
        v = family_violations(pkgs(*FAMILY_OK, ("wasmtime-wasi-io", "48.0.4", R)))
        self.assertIn("wasmtime-wasi-io 48.0.4: expected 48.0.6", v)

    def test_cranelift_below_the_floor_is_refused(self):
        v = family_violations(pkgs(*FAMILY_OK, ("cranelift-entity", "0.135.4", R)))
        self.assertIn("cranelift-entity 0.135.4: outside ^0.135.6", v)

    # R1.5 — wrongly split: 0.23.46 present, 0.23.45 still beside it.
    def test_rustls_left_at_0_23_45_is_refused(self):
        self.assertEqual(rustls_violations(pkgs(*FAMILY_OK, ("rustls", "0.23.45", R))), ["rustls 0.23.45: expected 0.23.46"])
        self.assertEqual(rustls_violations(pkgs(*FAMILY_OLD)), ["rustls 0.23.45: expected 0.23.46"])

    # R1.5 — wrongly collapsed: rustls-* and *-rustls crates are other packages, not rustls.
    def test_rustls_named_crates_are_not_rustls(self):
        p = pkgs(("tokio-rustls", "0.23.46", R), ("rustls-pemfile", "0.23.46", R))
        self.assertEqual(rustls_violations(p), ["rustls: not in the lockfile"])
        self.assertEqual(rustls_violations(pkgs(*FAMILY_OK, ("rustls-pemfile", "2.2.0", R), ("tokio-rustls", "0.26.4", R))), [])

    # R1.1 — wrongly collapsed: wasm-tools names share the "wasm" prefix, not the family.
    def test_wasm_tools_names_are_not_the_family(self):
        v = family_violations(pkgs(*FAMILY_OK, ("wasm-encoder", "0.244.0", R), ("wasmparser", "0.254.2", R)))
        self.assertEqual(v, [])

    # R1.4 — wrongly collapsed: wasmparser has several lines locked; only 0.254 may move.
    def test_another_wasm_tools_line_moving_is_refused(self):
        base = pkgs(*FAMILY_OLD, ("wasmparser", "0.244.0", R), ("wasmparser", "0.254.0", R))
        new = pkgs(*FAMILY_OK, ("wasmparser", "0.244.1", R), ("wasmparser", "0.254.2", R))
        v = move_violations(base, new)
        self.assertEqual(len(v), 1, v)
        self.assertIn("wasmparser 0.244.1", v[0])

    def test_a_wasm_tools_crate_outside_the_measured_six_moving_is_refused(self):
        base = pkgs(*FAMILY_OLD, ("wat", "0.254.0", R))
        new = pkgs(*FAMILY_OK, ("wat", "0.254.2", R))
        self.assertTrue(any(m.startswith("wat 0.254.2") for m in move_violations(base, new)))

    def test_an_unrelated_crate_moving_is_refused(self):
        base = pkgs(*FAMILY_OLD, ("tokio", "1.0.0", R))
        new = pkgs(*FAMILY_OK, ("tokio", "1.1.0", R))
        self.assertTrue(any(m.startswith("tokio 1.1.0") for m in move_violations(base, new)))

    # R1.4 — rustls past the --precise target is not the move the story asked for.
    def test_rustls_moving_past_0_23_46_is_refused(self):
        new = pkgs(*FAMILY_OK[:-1], ("rustls", "0.23.47", R))
        self.assertTrue(any(m.startswith("rustls 0.23.47") for m in move_violations(pkgs(*FAMILY_OLD), new)))

    # R1.4 — a drop is allowed only when everything that used the crate left with it.
    def test_an_unrelated_crate_dropped_is_refused(self):
        text = lock(*FAMILY_OLD, ("tokio", "1.0.0", R), ("zed", "0.1.0", "local", ["tokio"]))
        v = move_violations(lock_packages(text), pkgs(*FAMILY_OK, ("zed", "0.1.0", "local")), lock_dependents(text))
        self.assertTrue(any(m.startswith("tokio 1.0.0 (registry) left the lockfile") for m in v), v)

    # Third element: cap-std used by the moved wasmtime-wasi AND by a crate that stays.
    def test_a_dropped_crate_still_used_by_a_crate_that_stays_is_refused(self):
        text = lock(*FAMILY_OLD[:1], ("wasmtime-wasi", "48.0.1", R, ["cap-std"]), *FAMILY_OLD[2:],
                    ("cap-std", "4.0.3", R), ("fs-utils", "1.0.0", R, ["cap-std"]))
        v = move_violations(lock_packages(text), pkgs(*FAMILY_OK, ("fs-utils", "1.0.0", R)), lock_dependents(text))
        self.assertTrue(any("cap-std 4.0.3" in m and "fs-utils 1.0.0" in m for m in v), v)

    # R1.4 — same name, different thing: a workspace member is not a registry crate.
    def test_a_workspace_member_is_not_a_registry_change(self):
        base = pkgs(*FAMILY_OLD)
        self.assertEqual(move_violations(base, pkgs(*FAMILY_OK, ("devtools_bridge", "0.1.0", "local"))), [])
        v = move_violations(base, pkgs(*FAMILY_OK, ("devtools_bridge", "0.1.0", R)))
        self.assertTrue(any(m.startswith("devtools_bridge 0.1.0 (registry)") for m in v), v)

    def test_a_lockfile_where_nothing_moved_is_refused(self):
        same = pkgs(*FAMILY_OLD)
        v = move_violations(same, same)
        self.assertIn("wasmtime did not move", v)
        self.assertIn("rustls did not move", v)

    # R1.2 — the profile entry `wasmtime = { opt-level = 3 }` is not the dependency.
    def test_the_dependency_table_is_read_not_the_profile_entry(self):
        v = manifest_violations(BASE_MANIFEST, BASE_MANIFEST)
        self.assertEqual(len(v), 3, v)  # wasmtime, wasmtime-wasi still "48"; rustls still "0.23.26"

    def test_an_exact_pin_is_not_the_floor(self):
        v = manifest_violations(MANIFEST.format(v="=48.0.6", f=FEATURES, r='"=0.23.46"'), BASE_MANIFEST)
        self.assertEqual(len([m for m in v if "expected" in m]), 3, v)

    def test_a_dropped_feature_is_refused_and_a_reordered_list_is_not(self):
        dropped = MANIFEST.format(v="48.0.6", f='"async", "runtime"', r='"0.23.46"')
        reordered = MANIFEST.format(v="48.0.6", f='"component-model", "runtime", "async"', r='"0.23.46"')
        self.assertTrue(any("missing ['component-model']" in m for m in manifest_violations(dropped, BASE_MANIFEST)))
        self.assertEqual(manifest_violations(reordered, BASE_MANIFEST), [])

    # R1.5 — the floor moves, nothing else about the entry: no default-features slipped in.
    def test_a_rustls_floor_that_changes_the_entrys_shape_is_refused(self):
        table = MANIFEST.format(v="48.0.6", f=FEATURES, r='{ version = "0.23.46", default-features = false }')
        self.assertTrue(any(m.startswith("[workspace.dependencies] rustls: keys other") for m in manifest_violations(table, BASE_MANIFEST)))
        same_shape = MANIFEST.format(v="48.0.6", f=FEATURES, r='{ version = "0.23.46" }')
        self.assertEqual(manifest_violations(same_shape, BASE_MANIFEST), [])

    # Benign: the end state cargo produces (measured in a scratch copy, 2026-10-17).
    def test_the_expected_end_state_passes(self):
        text = lock(*FAMILY_OLD[:1], ("wasmtime-wasi", "48.0.1", R, ["cap-fs-ext"]), *FAMILY_OLD[2:],
                    ("wasmparser", "0.244.0", R), ("wasmparser", "0.254.0", R),
                    ("cap-fs-ext", "4.0.3", R, ["cap-std"]), ("cap-std", "4.0.3", R))
        new = pkgs(*FAMILY_OK, ("wasmparser", "0.244.0", R), ("wasmparser", "0.254.2", R))
        self.assertEqual(family_violations(new), [])
        self.assertEqual(rustls_violations(new), [])
        self.assertEqual(move_violations(lock_packages(text), new, lock_dependents(text)), [])
        self.assertEqual(manifest_violations(MANIFEST.format(v="48.0.6", f=FEATURES, r='"0.23.46"'), BASE_MANIFEST), [])


class PatchedTree(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = lock_packages((tree() / "Cargo.lock").read_text())
        base_text = (base_tree() / "Cargo.lock").read_text()
        cls.base_lock = lock_packages(base_text)
        cls.base_dependents = lock_dependents(base_text)
        cls.toml = (tree() / "Cargo.toml").read_text()
        cls.base_toml = (base_tree() / "Cargo.toml").read_text()

    def test_r1_1_the_family_resolves_to_48_0_6(self):
        v = family_violations(self.lock)
        self.assertEqual(v, [], "\n" + "\n".join(v))

    def test_r1_5_rustls_resolves_to_0_23_46(self):
        v = rustls_violations(self.lock)
        self.assertEqual(v, [], "\n" + "\n".join(v))

    def test_r1_4_only_the_crates_the_four_updates_require_moved(self):
        v = move_violations(self.base_lock, self.lock, self.base_dependents)
        self.assertEqual(v, [], "\n" + "\n".join(v))

    def test_r1_2_r1_5_the_manifest_floors_with_every_feature_kept(self):
        v = manifest_violations(self.toml, self.base_toml)
        self.assertEqual(v, [], "\n" + "\n".join(v))


if __name__ == "__main__":
    unittest.main(verbosity=2)
