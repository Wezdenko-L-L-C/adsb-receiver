#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Every #anchor in the repo's Markdown must name a heading that exists.
#
#   python3 .github/scripts/check-anchors.py        check every tracked *.md
#
# ⚠️ Headings here carry emoji, em-dashes and section numbers, and GitHub drops each of those
#    characters without collapsing the spaces around them, so `### 9h. 🏠 The stationary rig`
#    becomes `#9h--the-stationary-rig`. A guessed anchor is wrong in exactly those places, and a
#    broken anchor fails silently: the link lands on the top of the page.

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LINK = re.compile(r"\]\(([^)\s]*)\)")


def slug(text):
    """GitHub's heading anchor: rendered text, lowercased, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # [text](url) renders as text
    text = re.sub(r"<[^>]+>", "", text)  # inline HTML
    text = re.sub(r"[`*~]", "", text)  # code and emphasis markers; their content stays
    text = re.sub(r"[^\w\- ]", "", text.strip().lower())
    return text.replace(" ", "-")


def scan(path):
    """(anchors, links): the anchors a file defines, and (line, target) for each link in it."""
    anchors, links, seen, fenced = set(), [], {}, False
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = HEADING.match(line)
        if m:
            base = slug(m.group(2))
            count = seen.get(base, 0)
            seen[base] = count + 1
            anchors.add(base if count == 0 else f"{base}-{count}")
        for target in LINK.findall(line):
            if not re.match(r"[a-z][a-z0-9+.-]*:", target):  # skip http:, mailto:, ...
                links.append((n, target))
    return anchors, links


def main():
    files = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z", "*.md"],
        check=True, capture_output=True, text=True,
    ).stdout.split("\0")
    paths = [ROOT / f for f in files if f and (ROOT / f).is_file()]
    scanned = {p.resolve(): scan(p) for p in paths}

    bad = 0
    for path in paths:
        _, links = scanned[path.resolve()]
        for n, target in links:
            file_part, _, anchor = target.partition("#")
            dest = (path.parent / file_part).resolve() if file_part else path.resolve()
            where = f"{path.relative_to(ROOT)}:{n}"
            if file_part and not dest.exists():
                print(f"{where}: link to a missing file: {target}")
                bad += 1
            elif anchor and dest.suffix == ".md":
                if dest not in scanned:
                    scanned[dest] = scan(dest)
                if anchor not in scanned[dest][0]:
                    print(f"{where}: no heading makes the anchor #{anchor} in {dest.name}")
                    bad += 1
    if bad:
        print(f"{bad} broken link(s)", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
