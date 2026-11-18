"""Fail on a numeric literal glued to an identifier inside a sql!/query! macro body.

    python3 -I scripts/check-sql-tokens.py <tree>

sqlez_macros rebuilds a query from its tokens, adding a space only after an identifier, and
checks the result with SQLite at compile time -- outside Linux only (`#[cfg(not(any(target_os =
"linux", target_os = "freebsd")))]`). So `archived = 1 AND` reaches SQLite as "1AND", an
unrecognized token: the series compiled on Linux for months and broke the first Windows build
(0071 and 0117, 2026-11-18). A `?NNN` parameter is safe, since SQLite ends it at the first
non-digit; string literals inside the macro pass through whole. Upstream Zed builds on Windows,
so a hit in its own code would mean this check is wrong.

Exit: 0 clean · 1 a glued token found · 2 usage.
"""

import pathlib
import re
import sys

GLUED = re.compile(r"(?<![\w?.])(\d+)\s+([A-Za-z_]\w*)")
MACRO = re.compile(r"\b(sql!|query!)\s*[\(\{\[]")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')


def macro_body(text: str, start: int) -> str:
    """The text between the macro's opening delimiter (at start - 1) and its matching close."""
    depth, i = 0, start - 1
    while i < len(text):
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return text[start:i]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    found = 0
    for path in sorted(root.rglob("*.rs")):
        if "target" in path.relative_to(root).parts:
            continue
        text = path.read_text(errors="replace")
        for m in MACRO.finditer(text):
            body = STRING.sub(
                lambda s: '"' + " " * (len(s.group(0)) - 2) + '"',
                macro_body(text, m.end()),
            )
            for hit in GLUED.finditer(body):
                line = text.count("\n", 0, m.end() + hit.start()) + 1
                print(
                    f"{path.relative_to(root)}:{line}: {hit.group(1)} then {hit.group(2)}: parenthesise the literal, ({hit.group(1)})"
                )
                found += 1
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
