#!/usr/bin/env python3
"""Differential check of the storyboard compiler against ibtool on random storyboards (research tool, Mac only).

Usage: python3 -I scripts/ib-corpus/differential.py --seed N [--count 300] [--colors] [--out DIR]

1. Generates --count random launch-screen storyboards from --seed (deterministic: the same seed gives the same
   storyboards), with the corpus generator's templates (gen.py):
   - trees up to three levels deep: one to three subviews per level, sibling containers with subviews of their own,
     image views, labels and plain views at random frames (wide, negative and zero origins included);
   - constraints in every container's list between the container, its direct subviews and (root view) the safe area,
     with random attributes of one axis, relations, priorities, multipliers, constants, symbolic spacing,
     identifiers and placeholders, plus own size and aspect constraints;
   - mirrored pairs (`X.a = owner.b` next to `owner.a = X.b`, with equal or different attributes);
   - in about one storyboard in eight, a constraint pairing leading/trailing with left/right (in the first container
     that gets constraints), which the compiler must refuse;
   - 15% without the safe area (legacy layout guides);
   - with --colors (cross-feature mode, final review): random root, plain-view, image-view and label backgrounds,
     image-view tints and label text colors (system colors including tintColor, the named color Brand, sRGB and
     gray 2.2 with components from n/255, small decimals, exponent spellings and random 17-digit values), and random
     label fonts, alignments, line counts and line-break modes. The colors come from a second random stream, so a
     seed gives the same trees and constraints with and without --colors.
2. Compiles each one with ibtool 27A266a (universal-16 flag set, compile + link as scripts/ib-golden.sh does) into
   DIR/<name>.storyboardc; storyboards ibtool rejects or warns about are dropped and counted.
3. Runs `swift run IBDifferential DIR` (Sources/IBDifferential), which compiles every storyboard with
   XlessIB and compares the bytes.

Prints identical / refused / mismatched counts and the refusal reasons. Exits 1 if any case mismatches, or if a
storyboard with a mixed leading/left pairing was not refused. Not part of `swift test`: it needs Xcode 27A266a.
"""
import argparse
import random
import re
import shutil
import string
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import gen  # noqa: E402  (templates and helpers of the corpus generator)

REQUIRED_BUILD = "27A266a"
AXES = [["left", "right", "centerX"], ["leading", "trailing", "centerX"], ["top", "bottom", "centerY"], ["width", "height"]]
MULTS = [None] * 8 + ["0.5", "2", "16:9", "1:1", "3:4", "0.33333333333333331", "0.75", "1/3", "0.8", "1.5"]
PRIOS = [None] * 8 + ["750", "250", "999", "1", "500", "751"]
CONSTS = [None] * 5 + [8, 20, -20, 0.5, 100, 12.333333333333334, -40, 24]


def check_toolchain():
    if sys.platform != "darwin":
        sys.exit("differential: needs macOS with Xcode (ibtool)")
    xcv = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout
    build = re.search(r"Build version (\S+)", xcv)
    if not build or build.group(1) != REQUIRED_BUILD:
        sys.exit(f"differential: Xcode build is {build.group(1) if build else '?'}, the goldens and rules need {REQUIRED_BUILD}")


class Generator:
    def __init__(self, seed, colors=False):
        self.rng = random.Random(seed)
        self.colors = random.Random(seed ^ 0xC0105) if colors else None
        self.n = 0
        self.mixed = False
        self.want_mixed = False

    def rid(self):
        self.n += 1
        a = string.ascii_letters + string.digits
        return "".join(self.rng.choice(a) for _ in range(3)) + f"-{self.n:02d}-" + "".join(self.rng.choice(a) for _ in range(3))

    def frame(self):
        r = self.rng
        return (round(r.choice([0, 10, 20, r.uniform(-30, 380)]), 1), round(r.choice([0, 10, 100, r.uniform(-30, 800)]), 1),
                round(r.choice([10, 50, 100, 353, 393, r.uniform(1, 600)]), 1), round(r.choice([10, 21, 100, r.uniform(1, 300)]), 1))

    def values(self):
        r = self.rng
        c = r.choice(CONSTS)
        return dict(relation=r.choice([None] * 4 + ["lessThanOrEqual", "greaterThanOrEqual"]), multiplier=r.choice(MULTS),
                    constant=c, priority=r.choice(PRIOS), symbolic="YES" if c is not None and r.random() < 0.08 else None,
                    identifier=r.choice([None] * 12 + ["logo", "Lögo top"]), placeholder=r.choice([None] * 20 + ["YES"]))

    def constraint(self, first, fa, second, sa, **kw):
        return gen.constraint(self.rid(), fa, first=first, second=second, second_attr=sa, **kw)

    def owned(self, owner, kids, safe):
        """Constraints in `owner`'s list: between its subviews, the owner and (root) the safe area."""
        r = self.rng
        items = kids + ([safe] if safe else [])
        cons = []
        for _ in range(r.randint(0 if owner != gen.IDS["view"] else 1, 5)):
            if not kids:
                break
            a = r.choice(kids)
            b = r.choice([owner] + [x for x in items if x != a])
            axis = r.choice(AXES)
            fa, sa = r.choice(axis), r.choice(axis)
            if r.random() < 0.5:
                a, b = b, a
            first = None if a == owner and r.random() < 0.3 else a
            cons.append(self.constraint(first, fa, b, sa, **self.values()))
            if r.random() < 0.05 and owner in (a, b):   # mirrored pair, equal or different attributes
                other = b if a == owner else a
                fb = fa if r.random() < 0.5 else sa
                cons.append(self.constraint(other, fa, owner, fb))
                cons.append(self.constraint(owner, fa, other, fb))
        if kids and self.want_mixed and not self.mixed:   # leading/trailing with left/right: must be refused
            self.mixed = True
            fa, sa = r.choice([("leading", "left"), ("right", "trailing"), ("trailing", "right"), ("left", "leading")])
            cons.append(self.constraint(r.choice(kids), fa, owner, sa))
        return cons

    def own_size(self, vid):
        r = self.rng
        cons = []
        for _ in range(r.choice([0, 0, 1, 2])):
            fa = r.choice(["width", "height"])
            if r.random() < 0.7:
                cons.append(gen.constraint(self.rid(), fa, constant=r.choice([20, 50, 100, 120]), priority=r.choice(PRIOS),
                                           relation=r.choice([None, None, "lessThanOrEqual"])))
            else:
                cons.append(gen.constraint(self.rid(), fa, second=vid, second_attr="height" if fa == "width" else "width",
                                           multiplier=r.choice(["1:1", "16:9", "2"])))
        return cons

    def view(self, depth):
        """A random subview (a container up to depth 3); returns (xml, id)."""
        r = self.rng
        vid = self.rid()
        own = self.own_size(vid)
        if depth < 3 and r.random() < 0.45:
            kids = [self.view(depth + 1) for _ in range(r.randint(1, 3))]
            own += self.owned(vid, [k for _, k in kids], None)
            return gen.container(vid, self.frame(), own, [x for x, _ in kids]), vid
        kind = r.choice(["image", "label", "view"])
        if kind == "image":
            tint = self.color() if self.colors and self.colors.random() < 0.5 else None
            return self.background(gen.image_view({**gen.IDS, "img": vid}, own_constraints=own, fixed=False, frame=self.frame(), tint=tint)), vid
        if kind == "label":
            return self.background(gen.label({**gen.IDS, "lbl": vid}, own_constraints=own, fixed=False, frame=self.frame(), **self.label_kw())), vid
        return gen.plain_view(vid, self.frame(), fixed=False, own_constraints=own,
                              background=self.color() if self.colors and self.colors.random() < 0.6 else None), vid

    # --colors: a second random stream, so trees and constraints do not depend on it
    SYSTEM = gen.SYSTEM_COLOR_TABLE + ["tintColor", "tintColor"]

    def number(self):
        c = self.colors
        return c.choice([c.randint(0, 255) / 255, c.randint(1, 25) / 255, c.choice(gen.SMALL), c.random(), c.choice([0, 1, 0.5])])

    def color(self):
        c = self.colors
        form = c.choice(["system", "system", "named", "srgb", "srgb", "srgb", "gray", "gray"])
        if form == "system":
            return gen.sys_color(c.choice(self.SYSTEM))
        if form == "named":
            return gen.named_color("Brand")
        alpha = c.choice([1, 1, self.number()])
        if form == "srgb":
            return gen.rgb_spec((self.number(), self.number(), self.number(), alpha), "sRGB")
        return gen.white_spec((self.number(), alpha), "genericGamma22GrayColorSpace")

    def background(self, view_text):
        if not self.colors or self.colors.random() < 0.6:
            return view_text
        i = view_text.rstrip().rfind("</")
        return view_text[:i] + f'    <color key="backgroundColor" {self.color()}/>\n' + view_text[i:]

    def label_kw(self):
        c = self.colors
        if not c:
            return {}
        font = c.choice(['type="system" pointSize="17"', 'type="boldSystem" pointSize="20"', 'type="italicSystem" pointSize="13"',
                         'type="system" weight="semibold" pointSize="28"', 'type="system" weight="light" pointSize="12.5"',
                         'style="UICTFontTextStyleHeadline"', 'style="UICTFontTextStyleBody"'])
        return dict(text=c.choice(["Label", "Welcome", "Café", "Loading…", "Two\nlines"]), font=font,
                    align=c.choice(["natural", "center", "left", "right", None]), lines=c.choice([None, None, 0, 2]),
                    line_break=c.choice(["tailTruncation", "tailTruncation", "wordWrap", "middleTruncation"]),
                    text_color=self.color() if c.random() < 0.5 else None)

    def storyboard(self):
        self.mixed = False
        r = self.rng
        self.want_mixed = r.random() < 0.125
        safe = r.random() < 0.85
        kids = [self.view(1) for _ in range(r.randint(1, 3))]
        root = self.owned(gen.IDS["view"], [k for _, k in kids], gen.IDS["safe"] if safe else None)
        # (system colors need no <resources> entry: ibtool ignores its value, `color-system-altered-resource`)
        make, extra = gen.modern, dict(resources=[("image", "Logo")])
        if self.colors:
            make, extra = gen.document, dict(background=self.color(), resources=[("image", "Logo"), ("namedColor", "Brand")])
        text = make(subviews=[x for x, _ in kids], root_constraints=root, safe_area=safe,
                    extra_capabilities=[("Constraints with non-1.0 multipliers", "5.1")], **extra)
        return text, self.mixed


def ibtool(name, src, out, work):
    """Compiles and links like scripts/ib-golden.sh; False if ibtool fails or prints anything."""
    flags = gen.FLAGSETS["universal-16"]
    diag = ["--errors", "--warnings", "--notices", "--output-format", "human-readable-text"]
    compiled = work / f"{name}.storyboardc"
    r = subprocess.run(["xcrun", "ibtool", *diag, "--module", "IBProbe", "--auto-activate-custom-fonts", *flags,
                        "--compile", str(compiled), str(src)], capture_output=True, text=True)
    if r.returncode != 0 or (r.stdout + r.stderr).strip():
        return False
    bundle = work / "bundle"
    bundle.mkdir()
    r = subprocess.run(["xcrun", "ibtool", *diag, "--module", "IBProbe", *flags, "--link", str(bundle), str(compiled)],
                       capture_output=True, text=True)
    if r.returncode != 0 or (r.stdout + r.stderr).strip():
        return False
    shutil.copytree(bundle / f"{name}.storyboardc", out / f"{name}.storyboardc")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--count", type=int, default=300)
    ap.add_argument("--colors", action="store_true", help="also vary colors, tints and label properties (cross-feature mode)")
    ap.add_argument("--out", type=Path, help="output directory (default: a new temporary directory)")
    args = ap.parse_args()
    check_toolchain()
    out = args.out or Path(tempfile.mkdtemp(prefix=f"ib-differential-{args.seed}-"))
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        sys.exit(f"differential: {out} is not empty")
    g = Generator(args.seed, colors=args.colors)
    mixed, rejected = set(), 0
    for i in range(args.count):
        name = f"d{args.seed}-{i:04d}"
        text, has_mixed = g.storyboard()
        src = out / f"{name}.storyboard"
        src.write_text(text.replace(gen.NEWLINE, "\n"), encoding="utf-8")
        with tempfile.TemporaryDirectory() as work:
            if not ibtool(name, src, out, Path(work)):
                rejected += 1
                src.rename(out / f"{name}.storyboard.ibtool-rejected")
                continue
        if has_mixed:
            mixed.add(name)
    r = subprocess.run(["swift", "run", "-q", "IBDifferential", str(out)], cwd=ROOT, capture_output=True, text=True)
    if r.returncode not in (0, 1):
        sys.exit(f"differential: IBDifferential failed:\n{r.stderr}")
    status, reasons, problems = Counter(), Counter(), []
    for line in r.stdout.splitlines():
        name, kind, *rest = line.split(" ", 2)
        status[kind] += 1
        if kind == "REFUSED":
            reasons[re.sub(r'"[^"]*"', '"…"', re.sub(r" at line \d+", "", rest[0]))] += 1
        if kind == "MISMATCH":
            problems.append(line)
        if kind == "FAILED":
            problems.append(line)
        if name in mixed and kind != "REFUSED":   # (it may be refused for another reason found first)
            problems.append(f"{name}: mixed leading/left pairing not refused ({kind})")
    print(f"differential seed {args.seed}: {args.count} generated, {rejected} rejected by ibtool, "
          f"{status['IDENTICAL']} identical, {status['REFUSED']} refused, {status['MISMATCH']} mismatched, "
          f"{status['FAILED']} failed ({out})")
    for reason, n in reasons.most_common():
        print(f"  refused {n}: {reason}")
    for p in problems:
        print(f"  PROBLEM {p}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
