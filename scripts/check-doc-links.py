#!/usr/bin/env python3
"""Checks the relative links of Markdown files: each must name an existing file or directory, and a `#anchor` must name
a heading of the target Markdown file (GitHub's anchor rules: lowercase, punctuation dropped, spaces to hyphens, `-1`,
`-2`… for repeated headings) or an explicit `<a id>`/`<a name>`. Links with a scheme (https:, mailto:) are not checked;
neither is anything inside code blocks or inline code.

    python3 -I scripts/check-doc-links.py README.md CONTRIBUTING.md docs/*.md

Exit 0 when every link resolves, 1 when one does not (each printed as file:line: target: reason), 2 for a usage error.
Standard library only.
"""
import os
import re
import sys
from urllib.parse import unquote

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
ATX = re.compile(r"^ {0,3}#{1,6}(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
LINK_TEXT = r"\[(?:[^\[\]]|\[[^\[\]]*\])*\]"
INLINE_LINK = re.compile(r"!?" + LINK_TEXT + r"\(\s*(<[^>\n]*>|[^\s()]+(?:\([^\s()]*\)[^\s()]*)*)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
REF_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
HTML_ANCHOR = re.compile(r"<a\s[^>]*?(?:id|name)=[\"']([^\"']+)[\"']", re.IGNORECASE)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def slug(text):
    """GitHub's heading anchor: inline markup removed, lowercase, only word characters, hyphens and spaces kept,
    spaces become hyphens."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # a link keeps its text
    text = re.sub(r"<[^>]+>", "", text)  # HTML tags
    text = text.replace("`", "").strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def scan(path):
    """Yields (kind, line number, value) for a Markdown file: ("heading", n, text), ("anchor", n, id) and
    ("link", n, target), outside fenced code blocks and inline code."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    fence = None
    prev = ""
    for n, line in enumerate(lines, 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line.strip()[len(m.group(1)):].strip():
                fence = None
            prev = ""
            continue
        if m:
            fence = m.group(1)
            prev = ""
            continue
        if line.startswith("    ") and not prev.strip():
            continue  # an indented code block
        h = ATX.match(line)
        if h:
            yield ("heading", n, h.group(1) or "")
        elif SETEXT.match(line) and prev.strip() and not ATX.match(prev) and not prev.lstrip().startswith(("-", "*", "|", ">")):
            yield ("heading", n - 1, prev.strip())
        code_free = INLINE_CODE.sub("", line)
        for a in HTML_ANCHOR.finditer(code_free):
            yield ("anchor", n, a.group(1))
        for l in INLINE_LINK.finditer(code_free):
            yield ("link", n, l.group(1))
        r = REF_DEF.match(code_free)
        if r:
            yield ("link", n, r.group(1))
        prev = line


_anchors = {}


def anchors(path):
    """The anchors a Markdown file defines."""
    key = os.path.realpath(path)
    if key not in _anchors:
        seen = {}
        found = set()
        for kind, _, value in scan(path):
            if kind == "heading":
                s = slug(value)
                count = seen.get(s, 0)
                seen[s] = count + 1
                found.add(s if count == 0 else f"{s}-{count}")
            elif kind == "anchor":
                found.add(value)
        _anchors[key] = found
    return _anchors[key]


def check(path):
    problems = []
    count = 0
    base = os.path.dirname(path)
    for kind, n, target in scan(path):
        if kind != "link":
            continue
        if target.startswith("<") and target.endswith(">"):
            target = target[1:-1]
        if not target or SCHEME.match(target):
            continue
        count += 1
        file_part, _, anchor = target.partition("#")
        file_part = unquote(file_part)
        if file_part.startswith("/"):
            problems.append(f"{path}:{n}: {target}: use a path relative to the file")
            continue
        dest = os.path.normpath(os.path.join(base, file_part)) if file_part else path
        if not os.path.exists(dest):
            problems.append(f"{path}:{n}: {target}: {dest} does not exist")
            continue
        if anchor and dest.endswith(".md") and os.path.isfile(dest):
            if unquote(anchor) not in anchors(dest):
                problems.append(f"{path}:{n}: {target}: {dest} has no heading with the anchor #{anchor}")
    return count, problems


def main(argv):
    if not argv:
        print("usage: check-doc-links.py <file.md>...", file=sys.stderr)
        return 2
    missing = [p for p in argv if not os.path.isfile(p)]
    if missing:
        print(f"check-doc-links: no such file: {' '.join(missing)}", file=sys.stderr)
        return 2
    total = 0
    problems = []
    for p in argv:
        c, probs = check(p)
        total += c
        problems += probs
    for line in problems:
        print(line, file=sys.stderr)
    if problems:
        print(f"check-doc-links: {len(problems)} broken of {total} relative links in {len(argv)} files", file=sys.stderr)
        return 1
    print(f"check-doc-links: ok, {total} relative links in {len(argv)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
