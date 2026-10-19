#!/usr/bin/env bash
# Writes the third-party licence notices a release ships in share/xless/licenses/: one file per package in
# Package.resolved (the LICENSE, and the NOTICE when there is one, from the SwiftPM checkout), plus the Swift runtime
# and musl that the static binary links in.
#   scripts/third-party-licenses.sh <out-dir>
# XLESS_CHECKOUTS overrides the checkouts directory (default .build/checkouts, filled by `swift build`).
set -euo pipefail
out="${1:?usage: third-party-licenses.sh <out-dir>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
checkouts="${XLESS_CHECKOUTS:-$root/.build/checkouts}"
mkdir -p "$out"

ids=$(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$root/Package.resolved")
[[ -n "$ids" ]] || { echo "third-party-licenses: no packages in Package.resolved" >&2; exit 1; }
for id in $ids; do
  dir=""
  for d in "$checkouts"/*; do
    [[ -d "$d" ]] || continue
    lower=$(basename "$d" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == "$id" ]]; then dir="$d"; break; fi
  done
  [[ -n "$dir" ]] || { echo "third-party-licenses: no checkout of $id in $checkouts (run swift build first)" >&2; exit 1; }
  lic=""
  for n in LICENSE LICENSE.txt LICENSE.md LICENCE COPYING; do [[ -f "$dir/$n" ]] && { lic="$dir/$n"; break; }; done
  [[ -n "$lic" ]] || { echo "third-party-licenses: no licence file in $dir" >&2; exit 1; }
  cp "$lic" "$out/$id.txt"
  for n in NOTICE NOTICE.txt NOTICE.md; do [[ -f "$dir/$n" ]] && { cp "$dir/$n" "$out/$id.NOTICE.txt"; break; }; done
done

cat > "$out/swift-runtime.txt" <<'TXT'
Swift runtime libraries (libswiftCore, Foundation and friends, statically linked into xless)

Copyright (c) Apple Inc. and the Swift project authors.
Licensed under the Apache License, Version 2.0 with Runtime Library Exception.
Licence text and the exception: https://github.com/swiftlang/swift/blob/main/LICENSE.txt
Project: https://www.swift.org

The Runtime Library Exception allows the runtime to be linked into, and distributed as part of, a binary without the
binary being subject to the Apache License's attribution conditions for source distribution.
TXT

cat > "$out/musl.txt" <<'TXT'
musl libc (statically linked into xless by the Swift static Linux SDK)

musl as a whole is licensed under the following standard MIT license:

Copyright (c) 2005-2020 Rich Felker, et al.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Authors and contributors are listed at https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT
TXT
