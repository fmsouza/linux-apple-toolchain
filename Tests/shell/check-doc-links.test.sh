#!/usr/bin/env bash
# Checks scripts/check-doc-links.py on a fixture tree: relative links must name an existing file or directory, and a
# `#anchor` must name a heading of the target Markdown file (GitHub's anchor rules). External links are not checked.
set -euo pipefail
S="$(cd "$(dirname "$0")/../.." && pwd)/scripts/check-doc-links.py"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
check() { python3 -I "$S" "$@"; }

mkdir -p "$t/docs/research" "$t/scripts"
touch "$t/scripts/tool.sh" "$t/docs/research/notes.md"
cat > "$t/README.md" <<'M'
# xless

See [the guide](docs/guide.md), [its setup](docs/guide.md#set-up-xless), [a section here](#what-you-need),
[research](docs/research/), ![logo](docs/research/notes.md "a title") and [the script](scripts/tool.sh).
External links are not checked: [Apple](https://developer.apple.com/download/all/), <https://example.com>, [mail](mailto:a@b.c).

## What you need

```sh
cat [not a link](missing-in-a-code-block.md)
```

Inline code is skipped too: `[x](missing-in-code.md)`.

[ref]: docs/guide.md#pinning-the-xcode-sdk
M
cat > "$t/docs/guide.md" <<'M'
# Guide

## Set up xless

## Pinning the Xcode (SDK)

## Caching and `XLESS_RN_CLEAN`

## One command: TestFlight

## Notes
## Notes

Back to [the top](../README.md#xless), [caching](#caching-and-xless_rn_clean), [one](#one-command-testflight),
[the second Notes](#notes-1), [research](research/notes.md) and [a <placeholder>](#set-up-xless).
M

out=$(check "$t/README.md" "$t/docs/guide.md") || fail "a valid tree fails: $out"
[[ "$out" == *"ok"* ]] || fail "no summary on success: $out"

# a missing file, a missing anchor in another file and in the same file: each reported with file:line, exit 1
cat > "$t/docs/bad.md" <<'M'
# Bad

[gone](nowhere.md)
[no such heading](guide.md#not-a-heading) and [nor here](#missing-here)
[outside the code](../scripts/missing.sh)
M
code=0; out=$(check "$t/docs/bad.md" 2>&1) || code=$?
[[ $code -eq 1 ]] || fail "broken links exit $code, want 1: $out"
[[ "$out" == *"bad.md:3"*"nowhere.md"* ]] || fail "missing file not reported with its line: $out"
[[ "$out" == *"bad.md:4"*"guide.md#not-a-heading"* ]] || fail "missing anchor in another file not reported: $out"
[[ "$out" == *"bad.md:4"*"#missing-here"* ]] || fail "missing anchor in the same file not reported: $out"
[[ "$out" == *"bad.md:5"*"../scripts/missing.sh"* ]] || fail "missing script not reported: $out"
[[ "$out" != *"missing-in-a-code-block"* ]] || fail "a link in a code block was checked: $out"

# a duplicate heading's first anchor has no suffix; a third one does not exist
printf '# A\n\n[x](guide.md#notes) [y](guide.md#notes-2)\n' > "$t/docs/dup.md"
code=0; out=$(check "$t/docs/dup.md" 2>&1) || code=$?
[[ $code -eq 1 && "$out" == *"#notes-2"* && "$out" != *"guide.md#notes "* ]] || fail "duplicate headings: exit $code: $out"

# usage errors: no file, a file that does not exist
code=0; check >/dev/null 2>&1 || code=$?; [[ $code -eq 2 ]] || fail "no arguments exit $code, want 2"
code=0; check "$t/nope.md" >/dev/null 2>&1 || code=$?; [[ $code -eq 2 ]] || fail "a missing input exits $code, want 2"

# the repository's own documentation
root="$(cd "$(dirname "$0")/../.." && pwd)"
out=$(cd "$root" && check README.md CONTRIBUTING.md docs/*.md docs/research/*.md 2>&1) || fail "broken links in the repository's docs:
$out"
echo "check-doc-links.test.sh: OK"
