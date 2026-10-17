#!/usr/bin/env python3
"""Checks the eight Localizable.strings tables agree (README → Language).

Every table must have the same keys, and each key the same format
placeholders (by type: `%d`, `%1$d` and `%2$d` all count as `d`, since
translations reorder positional ones). Exits non-zero on any mismatch.

    python3 tools/check_strings.py
"""
import plistlib
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "MenuLens" / "Resources"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:l{0,2})([@dfsu])")


def load(path):
    # plutil understands .strings (with comments and escapes) and prints XML.
    xml = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(path)], check=True, capture_output=True).stdout
    return plistlib.loads(xml)


def placeholders(text):
    return Counter(PLACEHOLDER.findall(text.replace("%%", "")))


tables = {p.parent.name.removesuffix(".lproj"): load(p) for p in sorted(ROOT.glob("*.lproj/Localizable.strings"))}
base = tables["en"]
problems = []
for lang, table in tables.items():
    for key in sorted(base.keys() - table.keys()):
        problems.append(f"{lang}: missing {key}")
    for key in sorted(table.keys() - base.keys()):
        problems.append(f"{lang}: extra {key}")
    for key in sorted(base.keys() & table.keys()):
        if placeholders(base[key]) != placeholders(table[key]):
            problems.append(f"{lang}: {key} placeholders {dict(placeholders(table[key]))} != en {dict(placeholders(base[key]))}")

print(f"{len(tables)} tables, {len(base)} keys each")
for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
