"""Shared readers for story 049's checks (wasmtime 48.0.6, rustls 0.23.46). Stdlib only, offline.

Environment:
  ZP_HUB        the chain root (default: four levels above this file)
  ZP_REF        the zed-patches ref holding the series (default main)
  ZP_PF         use this patches/<PF>/ directory instead of the newest one holding the fix patch
  ZP_EBUILD     the overlay revision zeo-<PF>-rN.ebuild to read (test_ebuild.py; base_tree default)
  ZP_TREE       the patched Zed tree (default zed-patches/work/zed-049)
  ZP_BASE_TREE  the unpatched tree to compare with (default zed-patches/work/zed-<EGIT_COMMIT>)
"""

import collections
import os
import pathlib
import re
import subprocess
import tomllib

HERE = pathlib.Path(__file__).resolve().parent
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
OLD_VERSION = "48.0.1"
FIX_VERSION = "48.0.6"
RUSTLS_OLD = "0.23.45"
RUSTLS_FIX = "0.23.46"


def _ids(*numbers: int) -> tuple:
    return tuple(f"RUSTSEC-2026-{n:04d}" for n in numbers)


# Measured 2026-10-17 with osv-scanner 2.7.0 on zeo-0.5.0_p20261016-r1's Cargo.lock.
WASMTIME_IDS = _ids(315, 316, 325, 326, 327, *range(353, 360), *range(361, 365))  # 16
WASI_IDS = _ids(314, *range(321, 325), 352)  # 6
RUSTLS_IDS = _ids(*range(346, 350))  # 4
CLOSED = WASMTIME_IDS + WASI_IDS + RUSTLS_IDS  # 26
# The reachable ones a user-facing changelog entry must name (story.md Summary).
CHANGELOG_IDS = _ids(352, 314, 325, 326, 349)
# wasm-tools crates 48.0.6 moves within their 0.254 line (R1.4, measured 2026-10-17).
WASM_TOOLS = {"wasmparser", "wasm-encoder", "wasm-metadata", "wasmprinter", "wit-parser", "wit-component"}
FIX_PATCH_RE = re.compile(r"^patches/([^/]+)/(\d{4})-wasmtime-48-0-6-rustls-0-23-46\.patch$")
PF_RE = re.compile(r"^(zed|zeo)-(\d+(?:\.\d+)*)(?:_(pre|p)(\d+))?(?:-r(\d+))?$")


def hub() -> pathlib.Path:
    env = os.environ.get("ZP_HUB")
    return pathlib.Path(env) if env else HERE.parents[3]


def zp() -> pathlib.Path:
    return hub() / "zed-patches"


def ref() -> str:
    return os.environ.get("ZP_REF", "main")


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(zp()), *args], check=True, capture_output=True, text=True
    ).stdout


def git_show(path: str) -> str:
    return git("show", f"{ref()}:{path}")


def ebuild_path() -> pathlib.Path:
    env = os.environ.get("ZP_EBUILD")
    if not env:
        raise RuntimeError("ZP_EBUILD is not set: name the overlay revision zeo-<PF>-rN.ebuild to read")
    return pathlib.Path(env)


def ebuild_text() -> str:
    return ebuild_path().read_text()


def egit_commit() -> str:
    m = re.search(r'^EGIT_COMMIT="([0-9a-f]{40})"', ebuild_text(), re.M)
    if not m:
        raise RuntimeError(f"no EGIT_COMMIT in {ebuild_path()}")
    return m.group(1)


def tree() -> pathlib.Path:
    env = os.environ.get("ZP_TREE")
    return pathlib.Path(env) if env else zp() / "work" / "zed-049"


def base_tree() -> pathlib.Path:
    env = os.environ.get("ZP_BASE_TREE")
    return pathlib.Path(env) if env else zp() / "work" / f"zed-{egit_commit()}"


def ver(v: str) -> tuple:
    """'0.38.0+1.3.281' -> (0, 38, 0); build metadata and pre-release are ignored."""
    core = re.split(r"[+-]", v, maxsplit=1)[0]
    return tuple(int(x) for x in core.split("."))


def pf_key(pf: str) -> tuple:
    """Order PF directories by package version, never by string.

    zeo succeeded zed on 2026-10-01, so every zeo-* is newer than every zed-*; within one,
    the version compares numerically (0.10.0 > 0.9.0), `_pre` < no suffix < `_p`, and a
    revision -rN above none.
    """
    m = PF_RE.match(pf)
    if not m:
        raise ValueError(f"not a PF directory name: {pf!r}")
    product, version, kind, date, rev = m.groups()
    return (
        product == "zeo",
        ver(version),
        {"pre": -1, None: 0, "p": 1}[kind],
        int(date or 0),
        int(rev or 0),
    )


def lock_packages(text: str) -> list:
    """[(name, version, kind)], kind is registry | git | local (a workspace member)."""
    out = []
    for p in tomllib.loads(text).get("package", []):
        src = p.get("source")
        kind = "local" if src is None else ("git" if src.startswith("git+") else "registry")
        out.append((p["name"], p["version"], kind))
    return out


def lock_dependents(text: str) -> dict:
    """{(name, version): {(dependent name, dependent version), ...}} from the lock's dependency lists.

    A dependency is written "name" when one version is locked, else "name version [(source)]".
    """
    pkgs = tomllib.loads(text).get("package", [])
    versions = collections.defaultdict(list)
    for p in pkgs:
        versions[p["name"]].append(p["version"])
    out = collections.defaultdict(set)
    for p in pkgs:
        for dep in p.get("dependencies", []):
            parts = dep.split(" ")
            name = parts[0]
            version = parts[1] if len(parts) > 1 else (versions[name][0] if len(versions[name]) == 1 else None)
            out[(name, version)].add((p["name"], p["version"]))
    return out


def is_family(name: str) -> bool:
    return (
        name == "wasmtime"
        or name.startswith("wasmtime-")
        or name.startswith("pulley-")
        or name.startswith("cranelift-")
    )


def choose_pf(found: list, pinned: str | None) -> tuple:
    """(pf, [(number, path)]) — ZP_PF if given, else the newest PF directory holding the patch."""
    if pinned:
        return pinned, [(n, p) for pf, n, p in found if pf == pinned]
    if not found:
        return None, []
    newest = max({pf for pf, _, _ in found}, key=pf_key)
    return newest, [(n, p) for pf, n, p in found if pf == newest]


def fix_patches() -> tuple:
    """(pf, [(number, path)]) of NNNN-wasmtime-48-0-6-rustls-0-23-46.patch in the PF's directory on the ref."""
    found = []
    for line in git("ls-tree", "-r", "--name-only", ref(), "--", "patches/").splitlines():
        m = FIX_PATCH_RE.match(line)
        if m:
            found.append((m.group(1), m.group(2), line))
    return choose_pf(found, os.environ.get("ZP_PF"))
