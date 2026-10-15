#!/usr/bin/env python3
"""Checks the NIB encoding rules in docs/research/nib-encoding.md against every golden (python3 -I).

Executable form of the rules that are easiest to get wrong: object numbering, the key table
(hash order), the class-name table, the root view size, subview geometry, and the order of
constraints inside each view's constraint array. Exits non-zero if any golden disagrees.
Reads only our own storyboards and the ibtool output compiled from them. Standard library only.

Usage: python3 -I scripts/ib-corpus/check-rules.py [-v] [case...]
"""
import sys

sys.dont_write_bytecode = True  # never leave a .pyc (with local paths) next to nib-tables.py

import importlib.util  # noqa: E402
import struct  # noqa: E402
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent.parent / "Tests" / "IBCorpus"
_spec = importlib.util.spec_from_file_location("nibtables", HERE / "nib-tables.py")
nibtables = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nibtables)

# ---------------------------------------------------------------------------------------------------
# Key table: CFString hash, linear probing, prime table sizes, growth after insert when count > cap.

MASK = (1 << 64) - 1


def cf_string_hash(s):
    """CoreFoundation's published 8-bit string hash (strings up to 96 bytes)."""
    b = s.encode()
    n = len(b)
    assert n <= 96, s
    h = n
    i = 0
    while i + 4 <= n:
        h = (h * 67503105 + b[i] * 16974593 + b[i + 1] * 66049 + b[i + 2] * 257 + b[i + 3]) & MASK
        i += 4
    while i < n:
        h = (h * 257 + b[i]) & MASK
        i += 1
    return (h + (h << (n & 31))) & MASK


TABLE = [(3, 2), (7, 6), (13, 12), (23, 20), (41, 33), (71, 53), (127, 86), (191, None)]


def key_table_order(keys_in_insertion_order):
    def insert(t, k):
        i = cf_string_hash(k) % len(t)
        while t[i] is not None:
            i = (i + 1) % len(t)
        t[i] = k

    level = 0
    t = [None] * TABLE[0][0]
    count = 0
    for k in keys_in_insertion_order:
        insert(t, k)
        count += 1
        cap = TABLE[level][1]
        if cap is not None and count > cap:
            old = [x for x in t if x is not None]
            level += 1
            t = [None] * TABLE[level][0]
            for o in old:
                insert(t, o)
    return [x for x in t if x is not None]


def preorder_keys(objs, keys, vals):
    """Keys in the order the encoder first uses them: depth-first from the root object, a key is
    recorded when its value is encoded, before descending into a not-yet-encoded child object."""
    seen, out, order = set(), [], []
    stack = [(0, 0)]
    seen.add(0)
    order.append(0)
    while stack:
        o, j = stack.pop()
        c, s, n = objs[o]
        if j >= n:
            continue
        stack.append((o, j + 1))
        k, v = vals[s + j]
        name = keys[k]
        if name not in out:
            out.append(name)
        if v[0] == "@" and v[1] not in seen:
            seen.add(v[1])
            order.append(v[1])
            stack.append((v[1], 0))
    return out, order


FALLBACK = {"UIColor": "NSColor", "UIFont": "NSFont", "_UILayoutGuide": "UIView", "_UILayoutSupportConstraint": "NSLayoutConstraint"}
FALLBACK_ORDER = ["NSColor", "NSFont", "UIView", "NSLayoutConstraint"]

# ---------------------------------------------------------------------------------------------------
# Root view size.

DEVICES = {
    "retina4_0": (320, 568), "retina4_7": (375, 667), "retina5_5": (414, 736), "retina5_9": (375, 812),
    "retina6_0": (390, 844), "retina6_1": (414, 896), "retina6_5": (414, 896), "retina6_7": (430, 932),
    "retina6_12": (393, 852), "retina6_3": (402, 874), "retina6_9": (440, 956),
    "ipad9_7": (768, 1024), "ipad10_2": (810, 1080), "ipad10_9rounded": (820, 1180),
    "ipad11_0rounded": (834, 1210), "ipad12_9rounded": (1024, 1366),
    "retina3_5": (393, 852),  # retired id: sized like the default device
}
DEFAULT_DEVICE = (393, 852)


def root_size(doc, frame, min_os):
    dev = doc.find("device")
    if dev is not None and dev.get("id") in DEVICES:
        w, h = DEVICES[dev.get("id")]
        return (h, w) if dev.get("orientation") == "landscape" else (w, h)
    if min_os >= 17:
        return frame
    return (600, 600) if doc.get("useTraitCollections") == "YES" else DEFAULT_DEVICE

# ---------------------------------------------------------------------------------------------------
# Constraint order.

RANK = {a: i for i, a in enumerate(["centerX", "right", "left", "trailing", "leading", "width",
                                     "centerY", "bottom", "top", "height"])}
REL_RANK = {"lessThanOrEqual": 0, "greaterThanOrEqual": 1, None: 2}


def table_owner_key(fa, sa):
    """Attribute order for constraints whose (normalised) second item is nil or the owning view."""
    if "centerX" in (fa, sa):
        cat = 0
    elif "centerY" in (fa, sa):
        cat = 1
    elif fa in ("right", "left"):
        cat = 2
    elif fa in ("trailing", "leading"):
        cat = 3
    elif fa == "width":
        cat = 4
    elif fa in ("bottom", "top"):
        cat = 5
    else:
        cat = 6
    return (cat, RANK[fa], RANK.get(sa, -1))


def table_other_key(fa, sa):
    """Attribute order for constraints between two other items (sibling, safe area)."""
    return (1 if fa == sa and fa in ("width", "height") else 0, RANK[fa], RANK[sa])


def constraint_sort_key(c, owner, origin):
    a, b = c.get("firstItem", owner), c.get("secondItem")
    if a == owner and b is not None and b != owner:
        a, b = b, a
    other = b is not None and b != owner
    fa, sa = c.get("firstAttribute"), c.get("secondAttribute")

    def first_item(x):
        # The owner itself sorts first (`order-cons-owner-first`); other items by their frame origin in the owner's
        # coordinate space, the safe-area guide at (0, 0).
        if x == owner:
            return (-1.0, 0.0, "")
        ox, oy = origin.get(x, (0.0, 0.0))
        return (ox * ox + oy * oy, ox, x)

    def second_item(x):
        return origin.get(x, (0.0, 0.0))[0]
    attrs = table_other_key(fa, sa) if other else table_owner_key(fa, sa)
    prio = float(c.get("priority", "1000"))
    return (first_item(a), other, attrs, prio, REL_RANK[c.get("relation")], second_item(b) if other else 0, c.get("id"))


def dropped(c, owner, is_root):
    """ibtool drops placeholder constraints, and `root.width = item.height` (and height/width) from the root view's
    array (`cons-dropped-root-size`; a subview owner keeps them)."""
    if c.get("placeholder") == "YES":
        return True
    fa, sa = c.get("firstAttribute"), c.get("secondAttribute")
    return (is_root and c.get("firstItem", owner) == owner and c.get("secondItem") not in (None, owner)
            and {fa, sa} == {"width", "height"})


# Cases whose constraint order depends on a rule that is still open (docs/research/nib-encoding.md, Open questions).
# `order-cons-second-item` matches the frame-x rule of step 7, which random scratch runs falsify for wider views.
# `order-cons-mirrored-*`: ties between constraints written in opposite directions are not ordered by id in general
# (question 13; `order-cons-mirrored-same` matches the id rule, `order-cons-mirrored-nested` does not).
# `cons-mixed-horizontal`: ibtool rewrites a leading/left pairing, so the XML signature cannot match (refused input).
KNOWN_OPEN = {"order-cons-second-item", "order-cons-second-item-safe", "order-cons-second-item-mixed",
              "order-cons-mirrored-tie", "order-cons-mirrored-same", "order-cons-mirrored-nested", "cons-mixed-horizontal"}

# ---------------------------------------------------------------------------------------------------


def nib_objects(path):
    objs, keys, vals, classes = nibtables.parse(path.read_bytes())
    return objs, keys, vals, classes


def obj_values(objs, keys, vals, i):
    c, s, n = objs[i]
    return [(keys[k], v) for k, v in vals[s:s + n]]


def array_items(objs, keys, vals, i):
    return [v[1] for k, v in obj_values(objs, keys, vals, i) if k == "UINibEncoderEmptyKey"]


def points(data_hex):
    b = bytes.fromhex(data_hex)
    assert b[0] == 7 and (len(b) - 1) % 8 == 0
    return struct.unpack("<%dd" % ((len(b) - 1) // 8), b[1:])


class Checker:
    def __init__(self, verbose):
        self.verbose = verbose
        self.counts = {}
        self.failures = []

    def check(self, rule, ok, where):
        p, f = self.counts.get(rule, (0, 0))
        self.counts[rule] = (p + ok, f + (not ok))
        if not ok:
            self.failures.append(f"{rule}: {where}")

    def nib(self, case, fs, path, doc):
        objs, keys, vals, classes = nib_objects(path)
        names = [c[0] for c in classes]
        seq, order = preorder_keys(objs, keys, vals)
        where = f"{case}/{fs}/{path.name}"
        self.check("object order = DFS pre-order", order == list(range(len(objs))), where)
        self.check("key table = hash order", key_table_order(seq) == keys, where)
        first = []
        for c, _, _ in objs:
            if names[c] not in first:
                first.append(names[c])
        tail = [f for f in FALLBACK_ORDER if f not in first and any(FALLBACK.get(x) == f for x in first)]
        self.check("class table = first use + fallbacks", names == first + tail, where)
        for n, ex in classes:
            if ex:
                self.check("class extras = fallback index", ex == [names.index(FALLBACK[n])], where)
        if "-view-" not in path.name:
            return
        self.view_nib(case, fs, doc, objs, keys, vals, names, where)

    def objects_list(self, objs, keys, vals, names, root, root_vals, where):
        """UINibObjectsKey = [owner, first responder, root view], the root's entry, then the other views' entries
        breadth-first (`order-objects-bfs`). A view's entry is [its constraints…, its subviews…]; the root's entry
        starts with the placeholder guide (safe-area mode) or has the legacy guides after its constraints."""
        def d(i):
            return dict(obj_values(objs, keys, vals, i))

        def is_legacy_guide(i):
            return names[objs[i][0]] == "_UILayoutGuide"

        def entry(i):
            v = d(i)
            subs = array_items(objs, keys, vals, v["UISubviews"][1]) if "UISubviews" in v else []
            cons = array_items(objs, keys, vals, v["UIViewAutolayoutConstraints"][1]) if "UIViewAutolayoutConstraints" in v else []
            guides = [s for s in subs if is_legacy_guide(s)]
            # The generated legacy constraints (on or to a legacy guide) are not listed.
            cons = [c for c in cons if names[objs[c][0]] == "NSLayoutConstraint"
                    and not any(v_[0] == "@" and is_legacy_guide(v_[1]) for k, v_ in obj_values(objs, keys, vals, c))]
            subs = [s for s in subs if not is_legacy_guide(s)]
            return cons, guides, subs

        top = array_items(objs, keys, vals, root_vals["UINibTopLevelObjectsKey"][1])
        listed = array_items(objs, keys, vals, root_vals["UINibObjectsKey"][1])
        cons, guides, subs = entry(root)
        placeholder = [i for i, (c, _, _) in enumerate(objs) if names[c] == "UILayoutGuide" and d(i)["UILayoutGuideOwningView"][0] != "@"]
        expected = top + (placeholder + cons + subs if placeholder else cons + guides + subs)
        queue = list(subs)
        while queue:
            v = queue.pop(0)
            c, _, s = entry(v)
            expected += c + s
            queue += s
        self.check("objects list = root entry + breadth-first entries", listed == expected, where)

    def view_nib(self, case, fs, doc, objs, keys, vals, names, where):
        root_vals = dict(obj_values(objs, keys, vals, 0))
        top = array_items(objs, keys, vals, root_vals["UINibTopLevelObjectsKey"][1])
        root = top[2]
        xml_view = doc.find("./scenes/scene/objects/viewController/view")
        rect = xml_view.find("rect[@key='frame']")
        frame = (float(rect.get("width")), float(rect.get("height")))
        min_os = int(fs.rsplit("-", 1)[1])
        w, h = root_size(doc, frame, min_os)
        rv = dict(obj_values(objs, keys, vals, root))
        self.check("root bounds/center", points(rv["UIBounds"][1]) == (0, 0, w, h)
                   and points(rv["UICenter"][1]) == (w / 2, h / 2), where)
        # Map nib objects to XML ids.
        ids = {root: xml_view.get("id")}
        origin = {}
        elements = {}

        def walk(xml, nib_index):
            sub_el = xml.find("subviews")
            vals_ = dict(obj_values(objs, keys, vals, nib_index))
            if sub_el is None:
                return
            nib_subs = array_items(objs, keys, vals, vals_["UISubviews"][1])
            for xs, ns in zip(list(sub_el), nib_subs):
                ids[ns] = xs.get("id")
                elements[xs.get("id")] = xs
                r = xs.find("rect[@key='frame']")
                x, y, ww, hh = (float(r.get(k)) for k in ("x", "y", "width", "height"))
                origin[xs.get("id")] = (x, y)
                sv = dict(obj_values(objs, keys, vals, ns))
                self.check("subview bounds/center from XML frame",
                           points(sv["UIBounds"][1]) == (0, 0, ww, hh) and points(sv["UICenter"][1]) == (x + ww / 2, y + hh / 2), where)
                walk(xs, ns)
        walk(xml_view, root)
        self.objects_list(objs, keys, vals, names, root, root_vals, where)
        guide = xml_view.find("viewLayoutGuide[@key='safeArea']")
        for i, (c, s, n) in enumerate(objs):
            if names[c] == "UILayoutGuide":
                d = dict(obj_values(objs, keys, vals, i))
                if d["UILayoutGuideOwningView"][0] == "@" and guide is not None:
                    ids[i] = guide.get("id")
        # Constraint arrays.
        for nib_index, xml_id in list(ids.items()):
            if nib_index != root and xml_id not in elements:
                continue  # layout guides own no constraint array
            xml = xml_view if nib_index == root else elements[xml_id]
            cons_el = xml.find("constraints")
            d = dict(obj_values(objs, keys, vals, nib_index))
            nib_cons = array_items(objs, keys, vals, d["UIViewAutolayoutConstraints"][1]) if "UIViewAutolayoutConstraints" in d else []
            nib_cons = [c for c in nib_cons if names[objs[c][0]] == "NSLayoutConstraint"
                        and not any(names[objs[v[1]][0]] == "_UILayoutGuide" for k, v in obj_values(objs, keys, vals, c) if v[0] == "@")]
            xml_cons = list(cons_el) if cons_el is not None else []
            if not xml_cons and not nib_cons:
                continue
            predicted = sorted((c for c in xml_cons if not dropped(c, xml_id, nib_index == root)),
                               key=lambda c: constraint_sort_key(c, xml_id, origin))

            def mult(s):
                # Ratios are exact; decimals are rounded to 6 significant digits (C %g) first (`cons-multiplier-grid`).
                if s is None:
                    return 1.0
                for sep in (":", "/"):
                    if sep in s:
                        n, d = s.split(sep)
                        return struct.unpack("<f", struct.pack("<f", float(n) / float(d)))[0]
                return struct.unpack("<f", struct.pack("<f", float("%g" % float(s))))[0]

            def sig_xml(c):
                rel = {"lessThanOrEqual": -1, "greaterThanOrEqual": 1}.get(c.get("relation"), 0)
                const = 0.0 if c.get("symbolic") == "YES" else float(c.get("constant", "0"))
                return (c.get("firstItem", xml_id), c.get("firstAttribute"), c.get("secondItem"), c.get("secondAttribute"),
                        rel, int(c.get("priority", "1000")), const, mult(c.get("multiplier")))

            def sig_nib(ci):
                cd = dict(obj_values(objs, keys, vals, ci))
                attr = {1: "left", 2: "right", 3: "top", 4: "bottom", 5: "leading", 6: "trailing", 7: "width",
                        8: "height", 9: "centerX", 10: "centerY"}
                second = ids.get(cd["NSSecondItem"][1]) if "NSSecondItem" in cd else None
                return (ids.get(cd["NSFirstItem"][1]), attr[cd["NSFirstAttribute"][1]], second,
                        attr[cd["NSSecondAttribute"][1]] if "NSSecondAttribute" in cd else None,
                        cd["NSRelation"][1] if "NSRelation" in cd else 0, cd["NSPriority"][1] if "NSPriority" in cd else 1000,
                        cd["NSConstant"][1] if "NSConstant" in cd else 0.0, cd["NSMultiplier"][1] if "NSMultiplier" in cd else 1.0)
            ok = [sig_xml(c) for c in predicted] == [sig_nib(c) for c in nib_cons]
            if not ok and self.verbose:
                print(where, xml_id, [sig_xml(c) for c in predicted], [sig_nib(c) for c in nib_cons], sep="\n  ")
            rule = "constraint array order (known open)" if case in KNOWN_OPEN else "constraint array order"
            self.check(rule, ok, f"{where} view {xml_id}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    chk = Checker("-v" in sys.argv)
    golden = CORPUS / "golden"
    cases = args or sorted(p.stem for p in CORPUS.glob("*.storyboard"))
    for case in cases:
        doc = ET.parse(CORPUS / f"{case}.storyboard").getroot()
        for sb in sorted((golden / case).glob("*.storyboardc")):
            for nib in sorted(sb.glob("*.nib")):
                chk.nib(case, sb.stem, nib, doc)
    for rule, (p, f) in chk.counts.items():
        status = "ok  " if not f else ("OPEN" if "(known open)" in rule else "FAIL")
        print(f"{status} {rule}: {p} passed, {f} {'differ (open question)' if status == 'OPEN' else 'failed'}")
    for f in chk.failures[:40]:
        print(("  OPEN " if "(known open)" in f else "  FAIL ") + f)
    sys.exit(1 if any("(known open)" not in f for f in chk.failures) else 0)


if __name__ == "__main__":
    main()
