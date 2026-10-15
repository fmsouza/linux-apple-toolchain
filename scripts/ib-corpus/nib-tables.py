#!/usr/bin/env python3
"""Print the raw tables of a NIBArchive file (research helper; run with `python3 -I`).

`xless nib dump` shows objects and their values; this also shows the key table and the
class-name table in file order (with indices), which the encoding notes need for the
key-interning and class-table rules. Decodes only files ibtool produced from our own inputs.

Usage: python3 -I scripts/ib-corpus/nib-tables.py [--keys] [--classes] [--objects] file.nib
(no section flag: all three)
"""
import struct
import sys


def varint(b, p):
    r, s = 0, 0
    while True:
        c = b[p]
        p += 1
        r |= (c & 0x7F) << s
        s += 7
        if c & 0x80:
            return r, p


def parse(b):
    if b[:10] != b"NIBArchive":
        raise SystemExit("not a NIBArchive")
    h = struct.unpack_from("<10I", b, 10)
    no, oo, nk, ko, nv, vo, nc, co = h[2:]
    objs, p = [], oo
    for _ in range(no):
        c, p = varint(b, p)
        s, p = varint(b, p)
        n, p = varint(b, p)
        objs.append((c, s, n))
    keys, p = [], ko
    for _ in range(nk):
        n, p = varint(b, p)
        keys.append(b[p:p + n].decode())
        p += n
    vals, p = [], vo
    for _ in range(nv):
        k, p = varint(b, p)
        t = b[p]
        p += 1
        if t == 0: v = ("int8", b[p]); p += 1
        elif t == 1: v = ("int16", struct.unpack_from("<h", b, p)[0]); p += 2
        elif t == 2: v = ("int32", struct.unpack_from("<i", b, p)[0]); p += 4
        elif t == 3: v = ("int64", struct.unpack_from("<q", b, p)[0]); p += 8
        elif t == 4: v = ("false",)  # tag 4 = NO, tag 5 = YES
        elif t == 5: v = ("true",)
        elif t == 6: v = ("float", struct.unpack_from("<f", b, p)[0]); p += 4
        elif t == 7: v = ("double", struct.unpack_from("<d", b, p)[0]); p += 8
        elif t == 8:
            n, p = varint(b, p)
            v = ("data", b[p:p + n].hex()); p += n
        elif t == 9: v = ("nil",)
        elif t == 10: v = ("@", struct.unpack_from("<I", b, p)[0]); p += 4
        else: raise SystemExit(f"bad value type {t}")
        vals.append((k, v))
    classes, p = [], co
    for _ in range(nc):
        n, p = varint(b, p)
        ne, p = varint(b, p)
        ex = list(struct.unpack_from(f"<{ne}i", b, p)); p += 4 * ne
        classes.append((b[p:p + n - 1].decode(), ex)); p += n
    return objs, keys, vals, classes


def main():
    args = sys.argv[1:]
    flags = {a for a in args if a.startswith("--")}
    files = [a for a in args if not a.startswith("--")]
    if len(files) != 1:
        raise SystemExit(__doc__)
    show = flags or {"--keys", "--classes", "--objects"}
    objs, keys, vals, classes = parse(open(files[0], "rb").read())
    if "--keys" in show:
        print("keys:")
        for i, k in enumerate(keys):
            print(f"  k{i} {k}")
    if "--classes" in show:
        print("classes:")
        for i, (n, ex) in enumerate(classes):
            print(f"  c{i} {n}" + (f" extras={ex}" if ex else ""))
    if "--objects" in show:
        print("objects:")
        for i, (c, s, n) in enumerate(objs):
            print(f"  #{i} c{c} {classes[c][0]} values[{s}..<{s + n}] keys=" + ",".join(f"k{vals[j][0]}" for j in range(s, s + n)))


if __name__ == "__main__":
    main()
