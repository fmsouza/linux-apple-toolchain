#!/usr/bin/env python3
"""Generates the storyboard corpus in Tests/IBCorpus (run with `python3 -I scripts/ib-corpus/gen.py`).

Each case is written from the templates in scripts/ib-corpus/templates (Xcode's element layout,
attribute order and 4-space indentation), changing one dimension at a time from a modern Xcode
launch screen (device retina6_12, safe area, systemBackgroundColor). It also writes
Tests/IBCorpus/flagsets.json (flag-set overrides per case) and Tests/IBCorpus/Assets.xcassets
(Logo/Banner images and the Brand color; never passed to ibtool, see docs/research/ib-invocation.md).

Hand-maintained cases (real-tauri-app, xcode-template, real-expo-splash-template) are not generated; their storyboards are left as
they are, and their flag sets are kept below. Then run scripts/ib-golden.sh to compile the goldens.
A storyboard or golden directory that belongs to no registered case makes gen.py stop with an error;
`--prune` deletes such files instead.
Standard library only.
"""
import json
import random
import re
import shutil
import struct
import sys
import zlib
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parent.parent.parent
TEMPLATES = Path(__file__).resolve().parent / "templates"
CORPUS = ROOT / "Tests" / "IBCorpus"

FLAGSETS = {
    "universal-16": ["--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", "16.0"],
    "iphone-16": ["--target-device", "iphone", "--minimum-deployment-target", "16.0"],
    "universal-15": ["--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", "15.0"],
    "universal-17": ["--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", "17.0"],
}
ALL = ["universal-16", "iphone-16", "universal-15", "universal-17"]
U16_17 = ["universal-16", "universal-17"]
HAND_MAINTAINED = {"real-tauri-app": U16_17, "xcode-template": ALL, "real-expo-splash-template": ALL}

# Default object IDs (Xcode's LaunchScreen template IDs for the scene, view controller, view and first responder).
IDS = {
    "scene": "EHf-IW-A2E", "vc": "01J-lp-oVM", "view": "Ze5-6b-2t3", "fr": "iYj-Kq-Ea1", "safe": "6Tk-OE-BBY",
    "img": "aKz-3d-Q8m", "lbl": "Lb1-xT-9pQ", "top": "Llm-lL-Icb", "bottom": "xb3-aO-Qok",
}

# Device id -> (width, height) in portrait, as ibtool 27.0 sizes the root view (docs/research/nib-encoding.md, "Root view size").
DEVICES = {
    "retina4_0": (320, 568), "retina4_7": (375, 667), "retina5_5": (414, 736), "retina5_9": (375, 812),
    "retina6_0": (390, 844), "retina6_1": (414, 896), "retina6_5": (414, 896), "retina6_7": (430, 932),
    "retina6_12": (393, 852), "retina6_3": (402, 874), "retina6_9": (440, 956),
    "ipad9_7": (768, 1024), "ipad10_2": (810, 1080), "ipad10_9rounded": (820, 1180),
    "ipad11_0rounded": (834, 1210), "ipad12_9rounded": (1024, 1366),
}

SYSTEM_COLORS = {
    "systemBackgroundColor": 'white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"',
    "systemGroupedBackgroundColor": 'red="0.94901960784313721" green="0.94901960784313721" blue="0.96862745098039216" alpha="1" colorSpace="custom" customColorSpace="sRGB"',
    "labelColor": 'white="0.0" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"',
    "systemBlueColor": 'red="0.0" green="0.47843137254901963" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"',
    "tintColor": 'red="0.0" green="0.47843137254901963" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"',
}
BRAND = 'red="0.20000000000000001" green="0.40000000000000002" blue="0.59999999999999998" alpha="1" colorSpace="custom" customColorSpace="sRGB"'
IMAGES = {  # resource line attributes (after name)
    "Logo": 'width="1" height="1"',
    "Banner": 'width="128" height="64"',
    "star.fill": 'catalog="system" width="128" height="124"',
}


def tmpl(name):
    return Template((TEMPLATES / name).read_text())


def indent(text, n):
    pad = " " * n
    return "".join(pad + line if line.strip() else line for line in text.splitlines(True))


def fmt(v):
    """Xcode's number spelling: zero is 0.0, integers have no fraction, others use 17 significant digits."""
    if isinstance(v, str):
        return v
    if v == 0:
        return "0.0"
    if float(v).is_integer():
        return str(int(v))
    return "%.17g" % float(v)


def attrs(pairs):
    return "".join(f' {k}="{v}"' for k, v in pairs if v is not None)


# --- colors -------------------------------------------------------------------------------------------

def sys_color(name):
    return f'systemColor="{name}"'


def named_color(name):
    return f'name="{name}"'


def color_el(key, spec):
    return f'<color key="{key}" {spec}/>\n'


# --- constraints --------------------------------------------------------------------------------------

def constraint(cid, first_attr, first=None, second=None, second_attr=None, relation=None, multiplier=None,
               constant=None, priority=None, symbolic=None, identifier=None, placeholder=None):
    return "<constraint" + attrs([
        ("firstItem", first), ("firstAttribute", first_attr), ("relation", relation), ("secondItem", second),
        ("secondAttribute", second_attr), ("multiplier", multiplier),
        ("constant", None if constant is None else fmt(constant)), ("priority", priority), ("symbolic", symbolic),
        ("placeholder", placeholder), ("identifier", identifier), ("id", cid)]) + "/>\n"


def constraints_block(lines):
    if not lines:
        return ""
    return "<constraints>\n" + indent("".join(lines), 4) + "</constraints>\n"


def cid(n, ids):
    return ids.get(f"c{n}", f"C{n:02d}-cn-K{n:02d}")


# --- subviews -----------------------------------------------------------------------------------------

def autoresizing(flags):
    if flags is None:
        return ""
    return "<autoresizingMask key=\"autoresizingMask\"" + attrs([(f, "YES") for f in flags]) + "/>\n"


FIXED_MASK = ["flexibleMaxX", "flexibleMaxY"]


def image_view(ids, image="Logo", mode="scaleAspectFit", frame=(146.5, 376, 100, 100), own_constraints=None,
               fixed=None, tint=None, image_attr=True):
    fixed = (own_constraints is None) if fixed is None else fixed
    x, y, w, h = frame
    img = ""
    if image is not None and image_attr:
        img = f' image="{image}"' + (' catalog="system"' if image == "star.fill" else "")
    return tmpl("imageView.xml").substitute(
        content_mode=mode, fixed_frame=' fixedFrame="YES"' if fixed else "", image=img, id=ids["img"],
        x=fmt(x), y=fmt(y), width=fmt(w), height=fmt(h),
        autoresizing=indent(autoresizing(FIXED_MASK), 4) if fixed else "",
        constraints=indent(constraints_block(own_constraints or []), 4),
        tint=indent(color_el("tintColor", tint), 4) if tint else "")


def plain_view(id_, frame=(0, 0, 10, 10), background=None, own_constraints=None, fixed=None, mode="scaleToFill", leading="",
               hugging=""):
    """`leading` / `hugging`: attributes Xcode writes before / after contentMode (e.g. ' opaque="NO"')."""
    fixed = (own_constraints is None) if fixed is None else fixed
    x, y, w, h = frame
    return tmpl("view-sub.xml").substitute(
        leading=leading, mode=mode, hugging=hugging,
        fixed_frame=' fixedFrame="YES"' if fixed else "", id=id_, x=fmt(x), y=fmt(y), width=fmt(w), height=fmt(h),
        autoresizing=indent(autoresizing(FIXED_MASK), 4) if fixed else "",
        constraints=indent(constraints_block(own_constraints or []), 4),
        background=indent(color_el("backgroundColor", background), 4) if background else "")


def table_id(prefix, i):
    """Xcode-shaped 3-2-3 object ID for the i-th generated object of a table case."""
    return f"{prefix}{i:02d}-tb-{i:03d}"


NEWLINE = "\x00"  # literal newline inside element text; kept out of indent() and restored on write


def label(ids, text="Label", font='type="system" pointSize="17"', align="natural", line_break="tailTruncation",
          lines=None, text_color=None, frame=(175.5, 415.5, 42, 21), own_constraints=None, fixed=None,
          text_as_element=False):
    fixed = (own_constraints is None) if fixed is None else fixed
    x, y, w, h = frame
    esc = text.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace("\n", NEWLINE)
    return tmpl("label.xml").substitute(
        fixed_frame=' fixedFrame="YES"' if fixed else "",
        text="" if text_as_element else f' text="{esc}"',
        text_alignment=f' textAlignment="{align}"' if align else "",
        line_break=line_break, number_of_lines=f' numberOfLines="{lines}"' if lines is not None else "",
        id=ids["lbl"], x=fmt(x), y=fmt(y), width=fmt(w), height=fmt(h),
        autoresizing=indent(autoresizing(FIXED_MASK), 4) if fixed else "",
        constraints=indent(constraints_block(own_constraints or []), 4),
        text_element=indent(f'<string key="text">{esc}</string>\n', 4) if text_as_element else "",
        font=font,
        text_color=indent(color_el("textColor", text_color) if text_color else '<nil key="textColor"/>\n', 4))


# --- document -----------------------------------------------------------------------------------------

def document(ids=None, device=("retina6_12", "portrait"), frame=None, safe_area=True, background=None,
             autoresizing_flags=("widthSizable", "heightSizable"), subviews=(), root_constraints=(),
             traits=True, legacy_guides=False, resources=None, extra_capabilities=(), safe_areas_attr=None,
             appearance="light", device_children=(), vc_attrs="", root_attrs=("", "", ""), root_extra=""):
    """`vc_attrs`: attributes before the view controller's id (` storyboardIdentifier="X"`); `root_attrs`: the root
    view's attributes before contentMode, between contentMode and id, and after id (Xcode's order); `root_extra`:
    root-view child elements before the background color (e.g. `<accessibility>`)."""
    ids = {**IDS, **(ids or {})}
    safe_areas_attr = safe_area if safe_areas_attr is None else safe_areas_attr
    if frame is None:
        frame = DEVICES[device[0]] if device and device[0] in DEVICES else (393, 852)
        if device and device[1] == "landscape":
            frame = (frame[1], frame[0])
    if device:
        app = f' appearance="{appearance}"' if appearance else ""
        if device_children:
            kids = "".join(f"        {c}\n" for c in device_children)
            dev_line = f'    <device id="{device[0]}" orientation="{device[1]}"{app}>\n{kids}    </device>\n'
        else:
            dev_line = f'    <device id="{device[0]}" orientation="{device[1]}"{app}/>\n'
    else:
        dev_line = ""
    resources = resources or []
    caps = set(extra_capabilities)
    if safe_areas_attr:
        caps.add(("Safe area layout guides", "9.0"))
    if any(r[0] == "systemColor" for r in resources):
        caps.add(("System colors in document resources", "11.0"))
    if any(r[0] == "namedColor" for r in resources):
        caps.add(("Named colors", "9.0"))
    caps.add(("documents saved in the Xcode 8 format", "8.0"))
    cap_lines = "".join(f'        <capability name="{n}" minToolsVersion="{v}"/>\n' for n, v in sorted(caps))
    view = tmpl("view.xml").substitute(
        id=ids["view"], width=fmt(frame[0]), height=fmt(frame[1]), lead=root_attrs[0], mid=root_attrs[1], trail=root_attrs[2],
        extra=indent(root_extra, 24),
        autoresizing=indent(autoresizing(autoresizing_flags), 24) if autoresizing_flags is not None else "",
        subviews=indent("<subviews>\n" + indent("".join(subviews), 4) + "</subviews>\n", 24) if subviews else "",
        safe_area=indent(f'<viewLayoutGuide key="safeArea" id="{ids["safe"]}"/>\n', 24) if safe_area else "",
        background=indent(color_el("backgroundColor", background), 24) if background else "",
        constraints=indent(constraints_block(list(root_constraints)), 24))
    guides = ""
    if legacy_guides:
        guides = indent("<layoutGuides>\n"
                        f'    <viewControllerLayoutGuide type="top" id="{ids["top"]}"/>\n'
                        f'    <viewControllerLayoutGuide type="bottom" id="{ids["bottom"]}"/>\n'
                        "</layoutGuides>\n", 20)
    res = ""
    if resources:
        body = ""
        for kind, name in sorted(resources, key=lambda r: ({"image": 0, "namedColor": 1, "systemColor": 2}[r[0]], r[1] if isinstance(r[1], str) else r[1][0])):
            if kind == "image":
                body += f'<image name="{name}" {IMAGES[name]}/>\n'
            elif kind == "namedColor":
                body += f'<namedColor name="{name}">\n    <color {BRAND}/>\n</namedColor>\n'
            else:
                spec = SYSTEM_COLORS[name] if isinstance(name, str) else name[1]
                n = name if isinstance(name, str) else name[0]
                body += f'<systemColor name="{n}">\n    <color {spec}/>\n</systemColor>\n'
        res = indent("<resources>\n" + indent(body, 4) + "</resources>\n", 4)
    return tmpl("document.xml").substitute(
        use_traits=' useTraitCollections="YES"' if traits else "",
        use_safe_areas=' useSafeAreas="YES"' if safe_areas_attr else "",
        vc_id=ids["vc"], vc_attrs=vc_attrs, device=dev_line, capabilities=cap_lines, scene_id=ids["scene"],
        layout_guides=guides, view=view, first_responder_id=ids["fr"], resources=res)


SYSBG = sys_color("systemBackgroundColor")


def modern(**kw):
    """Xcode's default launch screen shape: device, safe area, systemBackgroundColor."""
    kw.setdefault("background", SYSBG)
    res = list(kw.pop("resources", []))
    bg = kw["background"]
    m = re.match(r'systemColor="(\w+)"', bg or "")
    if m and ("systemColor", m.group(1)) not in res:
        res.append(("systemColor", m.group(1)))
    return document(resources=res, **kw)


# --- case definitions ---------------------------------------------------------------------------------

CASES = {}
FLAGS = {}


def case(name, text, flagsets=None):
    assert name not in CASES, name
    CASES[name] = text
    if flagsets:
        FLAGS[name] = flagsets


def image_case(ids=IDS, **kw):
    image = kw.get("image", "Logo")
    res = [("image", image)] if image in IMAGES and kw.pop("resource", True) else []
    kw.pop("resource", None)
    tint = kw.get("tint")
    if tint and tint.startswith("systemColor"):
        res.append(("systemColor", re.match(r'systemColor="(\w+)"', tint).group(1)))
    return modern(subviews=[image_view(ids, **kw)], resources=res)


def label_case(ids=IDS, extra_res=(), **kw):
    return modern(subviews=[label(ids, **kw)], resources=list(extra_res))


def build():
    I = IDS
    V, S, IMG, LBL = I["view"], I["safe"], I["img"], I["lbl"]

    # core
    case("core-minimal", document(safe_area=False), ALL)
    case("core-safearea", document(safe_area=True))
    case("core-autoresizing-none", document(safe_area=False, autoresizing_flags=None))
    case("core-autoresizing-all", document(safe_area=False, autoresizing_flags=(
        "flexibleMinX", "widthSizable", "flexibleMaxX", "flexibleMinY", "heightSizable", "flexibleMaxY")))
    for f in ("flexibleMinX", "widthSizable", "flexibleMaxX", "flexibleMinY", "heightSizable", "flexibleMaxY"):
        case(f"core-autoresizing-{f}", document(safe_area=False, autoresizing_flags=(f,)))
    case("core-frame-375x667", document(safe_area=False, device=None, frame=(375, 667)), U16_17)
    case("core-frame-1024x1366", document(safe_area=False, device=None, frame=(1024, 1366)), U16_17)
    case("core-no-traitcollections", document(safe_area=False, device=None, frame=(375, 667), traits=False), U16_17)
    case("core-legacy-layoutguides", document(safe_area=False, legacy_guides=True))

    # device (root view size comes from the device, not the frame; see notes)
    for d in DEVICES:
        case(f"device-{d}", document(safe_area=False, device=(d, "portrait")), U16_17)
    case("device-retina6_12-landscape", document(safe_area=False, device=("retina6_12", "landscape")), U16_17)
    case("device-ipad12_9rounded-landscape", document(safe_area=False, device=("ipad12_9rounded", "landscape")), U16_17)
    case("device-ipad12_9rounded-iphone-only", document(safe_area=False, device=("ipad12_9rounded", "portrait")),
         ["universal-16", "iphone-16"])
    case("device-retina3_5", document(safe_area=False, device=("retina3_5", "portrait"), frame=(320, 480)), U16_17)
    case("device-unknown", document(safe_area=False, device=("unknownDevice", "portrait"), frame=(375, 667)), U16_17)
    # device appearance and Xcode 9-11 style adaptation child (no effect on the nib is expected; colors included)
    PV = [plain_view(table_id("A", 1), (0, 0, 10, 10), sys_color("labelColor"))]
    APR = [("systemColor", "labelColor")]
    case("device-appearance-dark", modern(appearance="dark", subviews=PV, resources=APR))
    case("device-no-appearance", modern(appearance=None, subviews=PV, resources=APR))
    case("device-adaptation-fullscreen", modern(appearance=None, device_children=['<adaptation id="fullscreen"/>'],
                                                subviews=PV, resources=APR))

    # plain <view> subview attributes (launch-screen color bands)
    def band(**kw):
        return modern(subviews=[plain_view(table_id("B", 1), (0, 100, 393, 50), sys_color("systemBlueColor"), **kw)],
                      resources=[("systemColor", "systemBlueColor")])
    case("view-plain-default", band())
    case("view-opaque-no", band(leading=' opaque="NO"'))
    case("view-userinteraction-no", band(leading=' userInteractionEnabled="NO"'))
    case("view-clips", band(leading=' clipsSubviews="YES"'))
    case("view-contentmode-center", band(mode="center"))
    case("view-contentmode-redraw", band(mode="redraw"))
    case("view-hugging-custom", band(hugging=' horizontalHuggingPriority="300" verticalHuggingPriority="200"'))
    case("view-hugging-250", band(hugging=' horizontalHuggingPriority="250" verticalHuggingPriority="250"'))
    case("view-hugging-251", band(hugging=' horizontalHuggingPriority="251" verticalHuggingPriority="251"'))

    # color (root background)
    for n in ("systemBackgroundColor", "systemGroupedBackgroundColor", "labelColor", "systemBlueColor"):
        case(f"color-system-{n}", modern(background=sys_color(n)))
    case("color-system-no-resource", document(background=SYSBG))
    case("color-system-altered-resource", document(background=SYSBG, resources=[
        ("systemColor", ("systemBackgroundColor", 'red="1" green="0.0" blue="0.0" alpha="0.5" colorSpace="custom" customColorSpace="sRGB"'))]))
    case("color-named-exists", document(background=named_color("Brand"), resources=[("namedColor", "Brand")]))
    case("color-named-missing", document(background=named_color("Missing")))
    case("color-srgb-opaque", document(background='red="1" green="0.5" blue="0.0" alpha="1" colorSpace="custom" customColorSpace="sRGB"'))
    case("color-srgb-alpha", document(background='red="0.25" green="0.5" blue="0.75" alpha="0.5" colorSpace="custom" customColorSpace="sRGB"'))
    case("color-srgb-precision", document(background='red="0.123456789012345678" green="0.33333333333333331" blue="0.10000000000000001" alpha="0.98999999999999999" colorSpace="custom" customColorSpace="sRGB"'))
    case("color-p3", document(background='red="1" green="0.5" blue="0.0" alpha="1" colorSpace="custom" customColorSpace="displayP3"'))
    case("color-white-gray", document(background='white="0.5" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"'))
    case("color-clear", document(background='white="0.0" alpha="0.0" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"'))
    case("color-calibrated-rgb", document(background='red="1" green="0.5" blue="0.0" alpha="1" colorSpace="calibratedRGB"'))
    case("color-calibrated-white", document(background='white="0.5" alpha="1" colorSpace="calibratedWhite"'))

    # image
    for m in ("scaleToFill", "scaleAspectFit", "scaleAspectFill", "center"):
        case(f"image-catalog-{m}", image_case(mode=m))
    # Xcode spells top-left "TopLeft" (capital T); ibtool maps an unknown spelling silently to the default (see image-mode-unknown).
    for m in ("redraw", "top", "bottom", "left", "right", "TopLeft", "topRight", "bottomLeft", "bottomRight"):
        case(f"image-mode-{m}", image_case(mode=m))
    case("image-system-symbol", image_case(image="star.fill"))
    case("image-missing", image_case(image="Missing"))
    case("image-no-resource", image_case(image="Logo", resource=False))
    case("image-resource-size", image_case(image="Banner", frame=(132.5, 394, 128, 64)))
    case("image-tint", image_case(tint=sys_color("systemBlueColor")))
    case("image-tint-srgb", image_case(tint='red="1" green="0.0" blue="0.0" alpha="1" colorSpace="custom" customColorSpace="sRGB"'))
    case("image-none", image_case(image=None))
    case("image-with-constraints", modern(
        subviews=[image_view(I, own_constraints=[constraint(cid(1, I), "width", constant=100), constraint(cid(2, I), "height", constant=100)])],
        root_constraints=[constraint(cid(3, I), "centerX", first=IMG, second=V, second_attr="centerX"),
                          constraint(cid(4, I), "centerY", first=IMG, second=V, second_attr="centerY")],
        resources=[("image", "Logo")]))
    case("image-reference", modern(subviews=[image_view(I, image="Logo", image_attr=False).replace(
        "</imageView>", '    <imageReference key="image" image="Logo"/>\n</imageView>')], resources=[("image", "Logo")],
        extra_capabilities=[("Image references", "12.0")]))

    # label
    case("label-plain", label_case(), ALL)
    for size in (12, 17, 34):
        for weight, font in (("regular", 'type="system" pointSize="{s}"'), ("semibold", 'type="system" weight="semibold" pointSize="{s}"'),
                             ("bold", 'type="boldSystem" pointSize="{s}"')):
            case(f"label-system-{size}-{weight}", label_case(font=font.format(s=size)))
    for w in ("ultraLight", "thin", "light", "medium", "heavy", "black", "bold"):
        case(f"label-weight-{w}", label_case(font=f'type="system" weight="{w}" pointSize="17"'))
    case("label-italic", label_case(font='type="italicSystem" pointSize="17"'))
    case("label-size-fraction", label_case(font='type="system" pointSize="17.5"'))
    case("label-custom-font", label_case(font='name="Helvetica-Bold" family="Helvetica" pointSize="17"'))
    case("label-custom-font-avenir", label_case(font='name="AvenirNext-Regular" family="Avenir Next" pointSize="20"'))
    case("label-textstyle", label_case(font='style="UICTFontTextStyleHeadline"'))
    for st in ("Body", "Callout", "Caption1", "Caption2", "Footnote", "Subhead", "Title0", "Title1", "Title2", "Title3"):
        case(f"label-textstyle-{st.lower()}", label_case(font=f'style="UICTFontTextStyle{st}"'))
    case("label-color-named", label_case(text_color=named_color("Brand"), extra_res=[("namedColor", "Brand")]))
    case("label-color-system", label_case(text_color=sys_color("labelColor"), extra_res=[("systemColor", "labelColor")]))
    case("label-color-srgb", label_case(text_color='red="1" green="0.0" blue="0.0" alpha="1" colorSpace="custom" customColorSpace="sRGB"'))
    for a in ("left", "center", "right", "natural", "justified"):
        case(f"label-align-{a}", label_case(align=a))
    case("label-align-omitted", label_case(align=None))
    for n in (0, 1, 3):
        case(f"label-lines-{n}", label_case(lines=n))
    for lb in ("wordWrap", "characterWrap", "clip", "headTruncation", "middleTruncation"):
        case(f"label-linebreak-{lb}", label_case(line_break=lb))
    case("label-unicode", label_case(text="Olá — 日本語 🚀 \"q\" & <x>", frame=(120, 415.5, 153, 21)))
    case("label-empty-text", label_case(text=""))
    case("label-multiline-text", label_case(text="Line one\nLine two", lines=0, text_as_element=True, frame=(160, 405, 73, 41)))

    # constraints (one image view; constraints vary)
    def cons(root=(), own=None, frame=(146.5, 376, 100, 100)):
        return modern(subviews=[image_view(I, own_constraints=own or [], fixed=False, frame=frame)],
                      root_constraints=list(root), resources=[("image", "Logo")],
                      extra_capabilities=[("Constraints with non-1.0 multipliers", "5.1")]
                      if any("multiplier" in c for c in list(root) + list(own or [])) else [])
    case("cons-center-xy", cons(root=[constraint(cid(1, I), "centerX", first=IMG, second=V, second_attr="centerX"),
                                      constraint(cid(2, I), "centerY", first=IMG, second=V, second_attr="centerY")]))
    case("cons-edges-superview", cons(frame=(0, 0, 393, 852), root=[
        constraint(cid(1, I), "leading", first=IMG, second=V, second_attr="leading"),
        constraint(cid(2, I), "trailing", first=V, second=IMG, second_attr="trailing"),
        constraint(cid(3, I), "top", first=IMG, second=V, second_attr="top"),
        constraint(cid(4, I), "bottom", first=V, second=IMG, second_attr="bottom")]))
    case("cons-edges-safearea", cons(frame=(20, 79, 353, 719), root=[
        constraint(cid(1, I), "leading", first=IMG, second=S, second_attr="leading", constant=20),
        constraint(cid(2, I), "trailing", first=S, second=IMG, second_attr="trailing", constant=20),
        constraint(cid(3, I), "top", first=IMG, second=S, second_attr="top", constant=20),
        constraint(cid(4, I), "bottom", first=S, second=IMG, second_attr="bottom", constant=20)]), ALL)
    case("cons-implicit-firstitem", cons(root=[
        constraint(cid(1, I), "bottom", second=IMG, second_attr="bottom", constant=20),
        constraint(cid(2, I), "centerX", first=IMG, second=V, second_attr="centerX")]))
    case("cons-left-right", cons(frame=(16, 376, 361, 100), root=[
        constraint(cid(1, I), "left", first=IMG, second=V, second_attr="left", constant=16),
        constraint(cid(2, I), "right", first=V, second=IMG, second_attr="right", constant=16)]))
    case("cons-width-height", cons(own=[constraint(cid(1, I), "width", constant=100), constraint(cid(2, I), "height", constant=50)],
                                   frame=(146.5, 401, 100, 50)))
    case("cons-aspect", cons(own=[constraint(cid(1, I), "width", second=IMG, second_attr="height", multiplier="16:9")]))
    case("cons-multiplier", cons(frame=(98.5, 376, 196.5, 100), root=[
        constraint(cid(1, I), "width", first=IMG, second=V, second_attr="width", multiplier="0.5")]))
    case("cons-multiplier-fraction", cons(root=[
        constraint(cid(1, I), "centerY", first=IMG, second=V, second_attr="bottom", multiplier="1/3", constant=1)]))
    for p in (750, 999, 250, 1):
        case(f"cons-priority-{p}", cons(own=[constraint(cid(1, I), "width", constant=100, priority=str(p))]))
    case("cons-relation-le", cons(own=[constraint(cid(1, I), "width", relation="lessThanOrEqual", constant=200)]))
    case("cons-relation-ge", cons(own=[constraint(cid(1, I), "width", relation="greaterThanOrEqual", constant=50)]))
    case("cons-constant-negative", cons(root=[constraint(cid(1, I), "centerY", first=IMG, second=V, second_attr="centerY", constant=-40)],
                                        frame=(146.5, 336, 100, 100)))
    case("cons-constant-fraction", cons(root=[constraint(cid(1, I), "centerY", first=IMG, second=V, second_attr="centerY", constant=12.333333333333334)],
                                        frame=(146.5, 388.33333333333331, 100, 100)))
    case("cons-symbolic", cons(root=[constraint(cid(1, I), "leading", first=IMG, second=S, second_attr="leading", constant=20, symbolic="YES")]))
    case("cons-frame-mismatch", cons(frame=(10, 20, 30, 40),
        own=[constraint(cid(1, I), "width", constant=100), constraint(cid(2, I), "height", constant=100)],
        root=[constraint(cid(3, I), "centerX", first=IMG, second=V, second_attr="centerX"),
              constraint(cid(4, I), "centerY", first=IMG, second=V, second_attr="centerY")]))
    case("cons-two-views-spacing", modern(
        subviews=[image_view(I, own_constraints=[], fixed=False),
                  label(I, own_constraints=[], fixed=False, frame=(175.5, 484, 42, 21))],
        root_constraints=[
            constraint(cid(1, I), "centerX", first=IMG, second=V, second_attr="centerX"),
            constraint(cid(2, I), "centerY", first=IMG, second=V, second_attr="centerY"),
            constraint(cid(3, I), "top", first=LBL, second=IMG, second_attr="bottom", constant=8),
            constraint(cid(4, I), "centerX", first=LBL, second=IMG, second_attr="centerX")],
        resources=[("image", "Logo")]))

    # real-world shapes
    def logo_plus_label(ids, order_swap=False, cons_swap=False):
        V2, IMG2, LBL2, S2 = ids["view"], ids["img"], ids["lbl"], ids["safe"]
        img = image_view(ids, own_constraints=[constraint(cid(1, ids), "width", constant=100),
                                              constraint(cid(2, ids), "height", constant=100)], fixed=False)
        lbl = label(ids, text="Loading", font='type="system" weight="semibold" pointSize="20"', align="center",
                    own_constraints=[], fixed=False, frame=(20, 500, 353, 24), text_color=sys_color("secondaryLabelColor"))
        root = [constraint(cid(3, ids), "centerX", first=IMG2, second=V2, second_attr="centerX"),
                constraint(cid(4, ids), "centerY", first=IMG2, second=V2, second_attr="centerY"),
                constraint(cid(5, ids), "top", first=LBL2, second=IMG2, second_attr="bottom", constant=24),
                constraint(cid(6, ids), "leading", first=LBL2, second=S2, second_attr="leading", constant=20),
                constraint(cid(7, ids), "trailing", first=S2, second=LBL2, second_attr="trailing", constant=20)]
        if cons_swap:
            root = [root[4], root[2], root[0], root[3], root[1]]
        subs = [lbl, img] if order_swap else [img, lbl]
        return modern(subviews=subs, root_constraints=root, ids=ids, resources=[
            ("image", "Logo"), ("systemColor", ("secondaryLabelColor", 'red="0.23529411764705882" green="0.23529411764705882" blue="0.2627450980392157" alpha="0.59999999999999998" colorSpace="custom" customColorSpace="sRGB"'))])

    case("real-centered-logo", modern(
        subviews=[image_view(I, own_constraints=[constraint(cid(1, I), "width", constant=100), constraint(cid(2, I), "height", constant=100)], fixed=False)],
        root_constraints=[constraint(cid(3, I), "centerX", first=IMG, second=V, second_attr="centerX"),
                          constraint(cid(4, I), "centerY", first=IMG, second=V, second_attr="centerY")],
        resources=[("image", "Logo")]), ALL)
    case("real-logo-plus-label", logo_plus_label(I), ALL)

    # order and ids (all relative to real-logo-plus-label)
    case("order-subviews-swapped", logo_plus_label(I, order_swap=True))
    case("order-constraints-swapped", logo_plus_label(I, cons_swap=True))
    case("order-attrs-shuffled", shuffle_attributes(logo_plus_label(I)))
    other = {"scene": "q7P-2m-ZxA", "vc": "Rb4-Tn-8eW", "view": "kL9-0s-Hd3", "fr": "Wc2-Yu-5vN", "safe": "pE6-Qa-1jM",
             "img": "Zt8-Bv-4kR", "lbl": "fN3-Gx-7hS", **{f"c{n}": f"m{n}X-{n}q-T{n}w" for n in range(1, 8)}}
    case("id-different-ids", logo_plus_label({**IDS, **other}))
    long_ids = {k: f"{k.upper()}-a-much-longer-identifier-than-xcode-writes-{i:04d}" for i, k in enumerate(
        ["scene", "vc", "view", "fr", "safe", "img", "lbl"] + [f"c{n}" for n in range(1, 8)])}
    case("id-long-ids", logo_plus_label({**IDS, **long_ids}))

    build_targeted()
    build_final_review()
    build_expo()


SYSTEM_COLOR_TABLE = [
    "systemBackgroundColor", "secondarySystemBackgroundColor", "tertiarySystemBackgroundColor",
    "systemGroupedBackgroundColor", "secondarySystemGroupedBackgroundColor", "tertiarySystemGroupedBackgroundColor",
    "labelColor", "secondaryLabelColor", "tertiaryLabelColor", "quaternaryLabelColor", "placeholderTextColor",
    "linkColor", "separatorColor", "opaqueSeparatorColor", "systemFillColor", "secondarySystemFillColor",
    "tertiarySystemFillColor", "quaternarySystemFillColor", "systemRedColor", "systemOrangeColor", "systemYellowColor",
    "systemGreenColor", "systemMintColor", "systemTealColor", "systemCyanColor", "systemBlueColor", "systemIndigoColor",
    "systemPurpleColor", "systemPinkColor", "systemBrownColor", "systemGrayColor", "systemGray2Color",
    "systemGray3Color", "systemGray4Color", "systemGray5Color", "systemGray6Color", "darkTextColor", "lightTextColor",
    "tintColor", "groupTableViewBackgroundColor",
]
# SF Symbol names common on launch screens (image-symbol-grid); the compiler accepts exactly these.
SYMBOLS = [
    "star.fill", "heart.fill", "house.fill", "person.fill", "person.circle.fill", "gear", "bolt.fill", "sun.max.fill",
    "moon.fill", "cloud.fill", "flame.fill", "music.note", "camera.fill", "photo", "map.fill", "cart.fill", "bag.fill",
    "book.fill", "bell.fill", "lock.fill", "checkmark.circle.fill", "xmark", "magnifyingglass", "paperplane.fill",
    "envelope.fill", "phone.fill", "message.fill", "square.and.arrow.up", "plus", "play.fill", "gamecontroller.fill",
    "airplane", "car.fill", "globe", "leaf.fill", "sparkles", "apple.logo", "swift",
]
GRID_RGB = [(1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1), (0.5, 0.5, 0.5, 1), (1, 1, 1, 1), (0, 0, 0, 1),
            (0.25, 0.75, 0.10000000000000001, 1), (0.90000000000000002, 0.20000000000000001, 0.59999999999999998, 0.5)]
GRID_WHITE = [(0, 1), (0.25, 1), (0.5, 1), (0.75, 1), (1, 1), (0.33333333333333331, 0.5)]


def rgb_spec(c, space):
    r, g, b, a = c
    tail = 'colorSpace="calibratedRGB"' if space == "calibratedRGB" else f'colorSpace="custom" customColorSpace="{space}"'
    return f'red="{fmt(r)}" green="{fmt(g)}" blue="{fmt(b)}" alpha="{fmt(a)}" {tail}'


def white_spec(c, space):
    w, a = c
    tail = 'colorSpace="calibratedWhite"' if space == "calibratedWhite" else f'colorSpace="custom" customColorSpace="{space}"'
    return f'white="{fmt(w)}" alpha="{fmt(a)}" {tail}'


def color_table(specs):
    """One plain subview per color (backgrounds), stacked at x=0, y=10*i."""
    return document(safe_area=False, subviews=[plain_view(table_id("T", i), (0, 10 * i, 10, 10), s) for i, s in enumerate(specs)])


def build_targeted():
    """Cases added while pinning the encoding rules (docs/research/nib-encoding.md cites each one)."""
    I = IDS
    V, S, IMG, LBL = I["view"], I["safe"], I["img"], I["lbl"]

    # core: safe-area attribute vs element, empty autoresizing element
    case("core-autoresizing-empty", document(safe_area=False, autoresizing_flags=()))
    case("core-safearea-attr-only", document(safe_area=False, safe_areas_attr=True))
    case("core-safearea-guide-only", document(safe_area=True, safe_areas_attr=False))

    # color: ibtool's system-color table, white/black/clear mapping, number formatting, color-space conversion grids
    case("color-system-table", color_table([sys_color(n) for n in SYSTEM_COLOR_TABLE]))
    G22 = "genericGamma22GrayColorSpace"
    case("color-white-black", document(background=white_spec((0, 1), G22)))
    case("color-white-white", document(background=white_spec((1, 1), G22)))
    case("color-white-inexact", document(background=white_spec((0.33333333333333331, 0.69999999999999996), G22)))
    case("color-srgb-white", document(background=rgb_spec((1, 1, 1, 1), "sRGB")))
    case("color-srgb-black", document(background=rgb_spec((0, 0, 0, 1), "sRGB")))
    case("color-srgb-clear", document(background=rgb_spec((0, 0, 0, 0), "sRGB")))
    case("color-srgb-tiny", document(background=rgb_spec((0.0001, 0.00001, 0.123456, 0.0005), "sRGB")))
    case("color-p3-grid", color_table([rgb_spec(c, "displayP3") for c in GRID_RGB]))
    case("color-calibrated-rgb-grid", color_table([rgb_spec(c, "calibratedRGB") for c in GRID_RGB]))
    case("color-calibrated-white-grid", color_table([white_spec(c, "calibratedWhite") for c in GRID_WHITE]))
    case("color-white-grid", color_table([white_spec(c, G22) for c in GRID_WHITE]))
    case("color-srgb-grid", color_table([rgb_spec(c, "sRGB") for c in GRID_RGB]))

    # image: view attributes Xcode writes, toggled one at a time
    case("image-mode-unknown", image_case(mode="bogusMode"))
    case("image-hugging-default", image_case().replace(' horizontalHuggingPriority="251" verticalHuggingPriority="251"', ""))
    case("image-hugging-custom", image_case().replace(' horizontalHuggingPriority="251" verticalHuggingPriority="251"',
                                                      ' horizontalHuggingPriority="300" verticalHuggingPriority="200"'))
    case("image-no-clips", image_case().replace(' clipsSubviews="YES"', ""))
    case("image-userinteraction-default", image_case().replace(' userInteractionEnabled="NO"', ""))
    case("image-frame-fraction", image_case(frame=(146.66666666666666, 376.33333333333331, 99.666666666666671, 100.5)))

    # Ruling R9 (Task 7): every content mode, hugging priority and attribute spelling the compiler accepts is proven
    # per element kind (plain view, image view) by these grids, one subview per value, stacked at x=0, y=10*i.
    MODES = ["scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw", "center", "top", "bottom", "left", "right",
             "TopLeft", "topRight", "bottomLeft", "bottomRight"]
    # None: the attribute is absent (Xcode writes a single axis when only that one differs from 250)
    HUG = [(250, 200), (200, 250), (1, 1), (1000, 1000), (1, 1000), (1000, 1), (250, 251), (251, 250), (750, 999),
           (251, None), (None, 251), (200, None), (None, 1000), (250, 250)]
    IMG_HUG = ' horizontalHuggingPriority="251" verticalHuggingPriority="251"'
    IMG_BOOLS = ' clipsSubviews="YES" userInteractionEnabled="NO"'
    TRANS = ' translatesAutoresizingMaskIntoConstraints="NO"'

    def hug(h, v):
        return attrs([("horizontalHuggingPriority", h), ("verticalHuggingPriority", v)])

    def grid(subviews, res=()):
        return document(safe_area=False, subviews=subviews, resources=list(res))

    def pv(prefix, i, **kw):
        return plain_view(table_id(prefix, i), (0, 10 * i, 10, 10), **kw)

    def iv(prefix, i, **kw):
        return image_view({**I, "img": table_id(prefix, i)}, frame=(0, 10 * i, 10, 10), **kw)

    def explicit(make):
        """Spellings Xcode does not write: explicit defaults, translatesAutoresizingMaskIntoConstraints YES/absent,
        fixedFrame NO. `make(i, fixed, bools)` builds subview i; `bools` replaces the view's leading booleans."""
        return [
            make(0, True, ' opaque="YES" clipsSubviews="NO" userInteractionEnabled="YES"'),
            make(1, False, None).replace(TRANS, ' translatesAutoresizingMaskIntoConstraints="YES"'),
            make(2, False, None).replace(TRANS, ""),
            make(3, False, None).replace(TRANS, ' fixedFrame="NO"' + TRANS),
            make(4, True, None).replace(TRANS, ' translatesAutoresizingMaskIntoConstraints="YES"'),
            make(5, False, None),   # translatesAutoresizingMaskIntoConstraints="NO" without fixedFrame, in no constraint
        ]

    case("view-contentmode-grid", grid([pv("M", i, mode=m) for i, m in enumerate(MODES)]))
    case("view-hugging-grid", grid([pv("H", i, hugging=hug(h, v)) for i, (h, v) in enumerate(HUG)]))
    case("view-attrs-explicit", grid(explicit(lambda i, fixed, bools: pv("X", i, fixed=fixed, leading=bools or ""))))
    case("image-hugging-grid", grid([iv("H", i).replace(IMG_HUG, hug(h, v)) for i, (h, v) in enumerate(HUG)], [("image", "Logo")]))
    case("image-attrs-explicit", grid(explicit(lambda i, fixed, bools: iv("X", i, fixed=fixed).replace(IMG_BOOLS, bools or IMG_BOOLS)),
                                      [("image", "Logo")]))
    # translatesAutoresizingMaskIntoConstraints="NO" on a view in no constraint, next to a constrained one (Task 9)
    case("view-translates-unconstrained", modern(resources=[("image", "Logo")], subviews=[
        image_view(I, fixed=False, own_constraints=[constraint(cid(1, I), "width", constant=100)]),
        pv("N", 1, fixed=False), iv("N", 2, fixed=False)]))
    # color forms as image-view tint and background; one view with an equal background and tint
    SRGB = rgb_spec((1, 0.5, 0, 1), "sRGB")
    tinted = [iv("C", 0, tint=white_spec((0.5, 1), G22)), iv("C", 1, tint=named_color("Brand")),
              iv("C", 2).replace("</imageView>", f'    <color key="backgroundColor" {SRGB}/>\n</imageView>'),
              iv("C", 3, tint=SRGB).replace('    <color key="tintColor"', f'    <color key="backgroundColor" {SRGB}/>\n    <color key="tintColor"')]
    case("image-color-forms", grid(tinted, [("image", "Logo"), ("namedColor", "Brand")]))
    case("image-opaque-no", image_case().replace("<imageView clipsSubviews", '<imageView opaque="NO" clipsSubviews'))
    case("image-background", modern(subviews=[image_view(I, tint=sys_color("systemBlueColor")).replace(
        '    <color key="tintColor"', '    <color key="backgroundColor" systemColor="labelColor"/>\n    <color key="tintColor"')],
        resources=[("image", "Logo"), ("systemColor", "systemBlueColor"), ("systemColor", "labelColor")]))
    case("image-system-symbol-no-resource", image_case(image="star.fill", resource=False))
    case("image-reference-symbol", modern(subviews=[image_view(I, image="star.fill", image_attr=False).replace(
        "</imageView>", '    <imageReference key="image" image="star.fill" catalog="system"/>\n</imageView>')],
        resources=[("image", "star.fill")], extra_capabilities=[("Image references", "12.0")]))
    # placeholder sharing: equal asset names share one placeholder; an asset and a symbol with the same name do not
    case("image-uniquing", grid([iv("U", 0), iv("U", 1), iv("U", 2, image="Missing"), iv("U", 3, image="star.fill"),
                                 iv("U", 4, image="star.fill").replace(' catalog="system"', "")], [("image", "Logo")]))
    # SF Symbols: ibtool encodes catalog="system" as a symbol only for names it knows (an unknown name gets the asset
    # form, see nib-encoding.md); these names are the verified set, at every flag set
    syms = [iv("Y", i).replace(' image="Logo"', f' image="{n}" catalog="system"') for i, n in enumerate(SYMBOLS)]
    case("image-symbol-grid", grid(syms), ALL)

    # label
    case("label-custom-font-missing", label_case(font='name="NoSuchFont-Bold" family="No Such Font" pointSize="17"'))
    case("label-opaque-default", label_case().replace('<label opaque="NO" ', "<label "))
    case("label-userinteraction-default", label_case().replace(' userInteractionEnabled="NO"', ""))
    case("label-hugging-default", label_case().replace(' horizontalHuggingPriority="251" verticalHuggingPriority="251"', ""))
    case("label-contentmode-center", label_case().replace('contentMode="left"', 'contentMode="center"'))
    case("label-lines-0-wordwrap", label_case(lines=0, line_break="wordWrap"))

    # Ruling R9 (Task 8): every label/font attribute and value the compiler accepts is proven by these grids, one
    # label per value, stacked at x=0, y=30*i (frames are verbatim, so the geometry is irrelevant).
    def lb(prefix, i, **kw):
        return label({**I, "lbl": table_id(prefix, i)}, frame=(0, 30 * i, 42, 21), **kw)

    LBL_HUG = ' horizontalHuggingPriority="251" verticalHuggingPriority="251"'
    LBL_BOOLS = ' opaque="NO" userInteractionEnabled="NO"'
    AUTO = ' baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO"'
    case("label-contentmode-grid", grid([lb("M", i).replace('contentMode="left"', f'contentMode="{m}"') for i, m in enumerate(MODES)]))
    # hugging (labels write 251/251 by default) and compression resistance (default 750)
    COMP = [(751, None), (None, 751), (750, 750), (1000, 1), (1, 1000), (749, 749), (250, 999)]

    def comp(h, v):
        return attrs([("horizontalCompressionResistancePriority", h), ("verticalCompressionResistancePriority", v)])
    case("label-hugging-grid", grid([lb("H", i).replace(LBL_HUG, hug(h, v)) for i, (h, v) in enumerate(HUG)]
                                    + [lb("R", i).replace(LBL_HUG, LBL_HUG + comp(h, v)) for i, (h, v) in enumerate(COMP)]))
    case("label-attrs-explicit", grid(explicit(lambda i, fixed, bools: lb("X", i, fixed=fixed).replace(
        '<label' + LBL_BOOLS, '<label' + (bools if bools is not None else LBL_BOOLS)))))
    # behaviour attributes Xcode writes when they are changed in the inspector, and omitted text / text color
    case("label-behavior-grid", grid([
        lb("B", 0).replace(' baselineAdjustment="alignBaselines"', ' baselineAdjustment="alignCenters"'),
        lb("B", 1).replace(' baselineAdjustment="alignBaselines"', ' baselineAdjustment="none"'),
        lb("B", 2).replace(' lineBreakMode=', ' enabled="NO" lineBreakMode='),
        lb("B", 3).replace(' lineBreakMode=', ' enabled="YES" lineBreakMode='),
        lb("B", 4).replace('<label opaque="NO"', '<label opaque="NO" clipsSubviews="YES"'),
        lb("B", 5).replace(' text="Label"', ""),
        lb("B", 6).replace('    <nil key="textColor"/>\n', ""),
        lb("B", 7, lines=2), lb("B", 8, lines=127), lb("B", 9, lines=128), lb("B", 10, lines=1000),
        lb("B", 11, font='style="UICTFontTextStyleBody"').replace(AUTO, AUTO + ' adjustsFontForContentSizeCategory="YES"'),
        lb("B", 12, font='style="UICTFontTextStyleHeadline"').replace(AUTO, AUTO + ' adjustsFontForContentSizeCategory="YES"'),
    ]))
    # autoshrink: "Minimum Font Scale" writes minimumScaleFactor, "Minimum Font Size" minimumFontSize, both without
    # adjustsFontSizeToFit (the React Native launch-screen template uses minimumFontSize); ibtool warns when the
    # minimum font size exceeds the font size, so the grid stops at equality
    FACTORS = [0.5, 0.25, 0.75, 0.10000000000000001, 0.33000000000000002, 0.90000000000000002, 0.01, 0.66666666666666663]
    SIZES = [17, 12, 34, 17.5, 13]
    shrink = [lb("S", i, font=f'type="system" pointSize="{fmt(p)}"').replace(AUTO, f' baselineAdjustment="alignBaselines" minimumScaleFactor="{fmt(f)}"')
              for i, (p, f) in enumerate((p, f) for p in SIZES for f in FACTORS)]
    MINS = [9, 18, 6, 12.5, 10, 20]
    shrink += [lb("F", i, font=f'type="{t}" pointSize="{fmt(p)}"').replace(AUTO, f' baselineAdjustment="alignBaselines" minimumFontSize="{fmt(m)}"')
               for i, (t, p, m) in enumerate((t, p, m) for t, p in (("system", 17), ("boldSystem", 36), ("system", 13), ("system", 17.5), ("system", 34))
                                             for m in MINS + [p] if m <= p)]
    case("label-autoshrink-grid", grid(shrink))
    # the optional label keys together, which pins their relative order (each grid above sets one of them)
    def combo(i, font, extra, lines, line_break, leading=""):
        return lb("Q", i, font=font, lines=lines, line_break=line_break).replace(AUTO, extra).replace(
            ' lineBreakMode=', ' enabled="NO" lineBreakMode=').replace('<label opaque="NO"', '<label opaque="NO"' + leading)
    SRGB_T = rgb_spec((1, 0.5, 0, 1), "sRGB")
    case("label-keys-combined", grid([
        combo(0, 'type="system" pointSize="17"', ' baselineAdjustment="alignCenters" minimumScaleFactor="0.5"', 0, "wordWrap",
              ' clipsSubviews="YES"').replace(LBL_HUG, LBL_HUG + comp(751, 749)).replace(
            '    <nil key="textColor"/>', f'    <color key="backgroundColor" {SRGB_T}/>\n    <color key="textColor" {sys_color("systemBlueColor")}/>'),
        combo(1, 'style="UICTFontTextStyleBody"', ' baselineAdjustment="none" adjustsFontSizeToFit="NO" adjustsFontForContentSizeCategory="YES"', 2, "clip"),
        combo(2, 'type="system" pointSize="17"', ' baselineAdjustment="alignCenters" minimumFontSize="9"', 3, "headTruncation"),
        combo(3, 'name="NoSuchFont-Bold" family="No Such Font" pointSize="20"', ' baselineAdjustment="none" minimumScaleFactor="0.25"', 0, "characterWrap"),
        combo(4, 'style="UICTFontTextStyleHeadline"', ' baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO" adjustsFontForContentSizeCategory="YES"', 0, "wordWrap"),
    ], [("systemColor", "systemBlueColor")]))
    # system fonts: every weight, bold and italic at sizes from 0.5 to 100; equal sizes share their NSNumber
    WEIGHTS = ["ultraLight", "thin", "light", "medium", "semibold", "bold", "heavy", "black"]
    fonts = []
    for p in (0.5, 1, 9, 13, 20, 28, 48, 100):
        fonts += [f'type="system" pointSize="{fmt(p)}"'] + [f'type="system" weight="{w}" pointSize="{fmt(p)}"' for w in WEIGHTS]
        fonts += [f'type="boldSystem" pointSize="{fmt(p)}"', f'type="italicSystem" pointSize="{fmt(p)}"']
    fonts.append('type="system" weight="regular" pointSize="17"')
    case("label-font-grid", grid([lb("G", i, font=f) for i, f in enumerate(fonts)]))
    STYLES = ["Title0", "Title1", "Title2", "Title3", "Headline", "Subhead", "Body", "Callout", "Footnote", "Caption1", "Caption2"]
    case("label-textstyle-grid", grid([lb("T", i, font=f'style="UICTFontTextStyle{s}"') for i, s in enumerate(STYLES + ["Body"])]
                                      + [lb("T", 12, font='type="system" weight="semibold" pointSize="14"')]))
    # custom fonts that are installed neither on macOS nor in the iOS simulator runtime (ibtool's "not installed"
    # form; see nib-encoding.md); equal fonts share one UIFont, a size equal to a system font's shares the NSNumber
    customs = [("NoSuchFont-Bold", "No Such Font", 17), ("NoSuchFont-Bold", "No Such Font", 24), ("XlessBrand-Regular", None, 17),
               ("XlessBrand-BoldItalic", "Xless Brand", 12.5), ("Xless Brand Display", "Xless Brand", 30), ("xlessbrand-black", "Xless Brand", 100),
               ("NoSuchFont-Bold", "No Such Font", 17)]
    cf = [lb("C", i, font=attrs([("name", n), ("family", fam), ("pointSize", fmt(p))]).strip()) for i, (n, fam, p) in enumerate(customs)]
    cf += [lb("C", 7, font='type="system" pointSize="24"'), lb("C", 8, text="XlessBrand-Regular")]
    case("label-custom-font-grid", grid(cf))
    # text: right-to-left and mixed scripts, NFC vs NFD (equal under Unicode equivalence, different code points),
    # emoji sequences, astral code points, a leading BOM character, whitespace, character references, a long text
    # (length varint > 127) and `<string key="text">` with literal and referenced CR LF
    TAB, LF, SNOW, CRLF, CR = "\x01TAB\x01", "\x01LF\x01", "\x01SNOW\x01", "\x01CRLF\x01", "\x01CR\x01"
    texts = ["مرحبا بالعالم", "שלום עולם", "Hello עולם 123", "Café", "Café", "👩‍💻 🇧🇷 👍🏽", "  padded  ", f"tab{TAB}here",
             "﻿BOM", "𠀀𝄞", "Ελληνικά Кириллица ไทย हिन्दी", "  ", f"a{LF}b", f"{SNOW} snow", "Long " + "x" * 200 + " end",
             "Same", "Same"]
    tf = [lb("U", i, text=t) for i, t in enumerate(texts)]
    tf += [lb("U", 17, text=f"One{CR}\nTwo", lines=0, text_as_element=True)]
    # what ibtool changes: every leading U+FEFF is dropped (not later ones); U+2028, U+2029 and U+0085 are kept.
    # "\x02XXXX\x02" is written as the character reference &#xXXXX; (Python's splitlines would break the indentation
    # at the raw characters)
    refs = ["\ufeff\ufeffx", "\ufeff", "mid\ufeffdle", "\x02FEFF\x02 a \x02FEFF\x02", "a\x022028\x02b", "a\x022029\x02b", "a\x0285\x02b"]
    tf += [lb("U", 18 + i, text=t) for i, t in enumerate(refs)]
    # a literal TAB and LF inside the attribute value: XML attribute-value normalization makes them spaces
    tf.append(lb("U", 25, text="lit\ttab\nlf"))

    def refs_to_xml(text):
        return re.sub("\x02([0-9A-F]+)\x02", lambda m: f"&#x{m.group(1)};", text.replace(TAB, "&#9;").replace(LF, "&#10;")
                      .replace(SNOW, "&#x2603;").replace(CRLF, "&#13;&#10;").replace(CR, "\r"))
    case("label-text-forms", refs_to_xml(grid(tf)))
    # a carriage return from a character reference: ibtool turns it into LF next to other characters ("a&#xD;b",
    # `<string>` "One&#13;&#10;Two") but keeps "&#xD;" and "&#xD;&#xD;" alone, so the compiler refuses CR in text
    crs = ["\x02D\x02", "a\x02D\x02b\x02A\x02c", "\x02D\x02\x02D\x02"]
    case("label-text-carriage-return", refs_to_xml(grid([lb("R", i, text=t) for i, t in enumerate(crs)]
                                                       + [lb("R", 3, text=f"One{CRLF}Two", lines=0, text_as_element=True)])))
    # text color forms; label backgrounds (a named color without resource compiles as a background, but ibtool fails
    # on one as a text or tint color); equal text and background colors; explicit labelColor next to nil
    SL = ("secondaryLabelColor", 'red="0.23529411764705882" green="0.23529411764705882" blue="0.2627450980392157" alpha="0.59999999999999998" colorSpace="custom" customColorSpace="sRGB"')
    SR8 = rgb_spec((0.20000000000000001, 0.40000000000000002, 0.59999999999999998, 0.5), "sRGB")
    colored = [lb("K", 0, text_color=white_spec((0.5, 1), G22)), lb("K", 1, text_color=SR8), lb("K", 2, text_color=sys_color("secondaryLabelColor")),
               lb("K", 3, text_color=sys_color("labelColor")), lb("K", 4), lb("K", 5).replace('    <nil key="textColor"/>', '    <color key="backgroundColor" name="NoSuchColor"/>\n    <nil key="textColor"/>'),
               lb("K", 6, text_color=white_spec((1, 1), G22)), lb("K", 7, text_color=named_color("Brand")),
               lb("K", 8, text_color=SR8).replace('    <color key="textColor"', f'    <color key="backgroundColor" {SR8}/>\n    <color key="textColor"'),
               lb("K", 9).replace('    <nil key="textColor"/>', f'    <color key="backgroundColor" {sys_color("systemBlueColor")}/>\n    <nil key="textColor"/>')]
    case("label-color-forms", grid(colored, [("systemColor", SL), ("systemColor", "labelColor"), ("systemColor", "systemBlueColor"),
                                             ("namedColor", "Brand")]))
    # the React Native template's launch-screen labels (autoshrink by minimum font size, clipping, no text color),
    # with fixed frames instead of its constraints
    rn = [label({**I, "lbl": "GJd-Yh-RWb"}, text="Example", font='type="boldSystem" pointSize="36"', align="center", line_break="middleTruncation",
                frame=(0, 202, 393, 43)),
          label({**I, "lbl": "MN2-I3-ftu"}, text="Powered by React Native", align="center", frame=(0, 626, 393, 21))]
    rn = [s.replace('<label opaque="NO"', '<label opaque="NO" clipsSubviews="YES"').replace(AUTO, ' baselineAdjustment="alignBaselines" minimumFontSize="' + m + '"')
          .replace('    <nil key="textColor"/>\n', "") for s, m in zip(rn, ("18", "9"))]
    case("label-react-native-template", modern(subviews=rn))
    # the Task 8 grids at every flag set (labels showed no per-flag difference; this proves it for every form)
    for n in ("label-contentmode-grid", "label-hugging-grid", "label-attrs-explicit", "label-behavior-grid", "label-autoshrink-grid",
              "label-keys-combined", "label-font-grid", "label-textstyle-grid", "label-custom-font-grid", "label-text-forms",
              "label-text-carriage-return", "label-color-forms", "label-react-native-template"):
        FLAGS[n] = ALL
    case("core-legacy-constraints", document(safe_area=False, legacy_guides=True, background=SYSBG,
        resources=[("image", "Logo"), ("systemColor", "systemBackgroundColor")],
        subviews=[image_view(I, own_constraints=[], fixed=False)],
        root_constraints=[constraint(cid(1, I), "centerX", first=IMG, second=V, second_attr="centerX"),
                          constraint(cid(2, I), "centerY", first=IMG, second=V, second_attr="centerY")]))

    # constraints: integer widths and multiplier precision
    def own_cons(cs):
        return modern(subviews=[image_view(I, own_constraints=cs, fixed=False)], resources=[("image", "Logo")])
    for p in (127, 128):
        case(f"cons-priority-{p}", own_cons([constraint(cid(1, I), "width", constant=100, priority=str(p))]))
    case("cons-multiplier-precise", modern(
        subviews=[image_view(I, own_constraints=[], fixed=False, frame=(146.5, 376, 39.300000000000004, 100))],
        root_constraints=[constraint(cid(1, I), "width", first=IMG, second=V, second_attr="width", multiplier="0.1")],
        resources=[("image", "Logo")], extra_capabilities=[("Constraints with non-1.0 multipliers", "5.1")]))

    # constraint order inside a view's constraint array
    def r(i, fa, first, second, sa, **kw):
        return constraint(kw.pop("id", table_id("K", i)), fa, first=first, second=second, second_attr=sa, **kw)
    H = ["left", "right", "centerX"]; H2 = ["leading", "trailing", "centerX"]; VV = ["top", "bottom", "centerY"]; Z = ["width", "height"]
    types = ([(a, b) for a in H for b in H] + [(a, b) for a in H2 for b in H2 if (a, b) != ("centerX", "centerX")]
             + [(a, b) for a in VV for b in VV] + [(a, b) for a in Z for b in Z])
    shuffled = types[:]
    random.Random(5).shuffle(shuffled)
    img0 = image_view(I, own_constraints=[], fixed=False, frame=(0, 0, 10, 10))
    case("order-cons-table-superview", modern(subviews=[img0], resources=[("image", "Logo")],
         root_constraints=[r(i, a, IMG, V, b) for i, (a, b) in enumerate(shuffled)]))
    case("order-cons-table-superview-flipped", modern(subviews=[img0], resources=[("image", "Logo")],
         root_constraints=[r(i, a, V, IMG, b) for i, (a, b) in enumerate(shuffled)]))
    I2 = "bbb-bb-bbb"
    img2 = image_view({**I, "img": I2}, own_constraints=[], fixed=False, frame=(0, 0, 10, 10))
    case("order-cons-table-sibling", modern(subviews=[img0], resources=[("image", "Logo")],
         root_constraints=[r(i, a, IMG, S, b) for i, (a, b) in enumerate(shuffled)]))
    case("order-cons-table-sibling-view", modern(subviews=[img0, img2], resources=[("image", "Logo")],
         root_constraints=[r(i, a, IMG, I2, b) for i, (a, b) in enumerate(shuffled)]))
    geo = [("aaa-aa-aaa", (0, 0)), ("000-00-000", (0, 0)), ("Bcd-aa-aaa", (0, 0)), ("ggg-aa-aaa", (50, 100)),
           ("hhh-aa-aaa", (100, 50)), ("iii-aa-aaa", (146.5, 376)), ("jjj-aa-aaa", (150, 0)), ("kkk-aa-aaa", (0, 150))]
    subs = [image_view({**I, "img": gid}, own_constraints=[], fixed=False, frame=(x, y, 10, 10)) for gid, (x, y) in geo]
    subs.append(label(I, own_constraints=[], fixed=False, frame=(20, 500, 353, 24)))
    gcons = [r(i, "top", gid, V, "top") for i, (gid, _) in enumerate(reversed(geo))]
    gcons += [r(50, "top", LBL, V, "top"), r(51, "top", V, S, "top")]
    random.Random(7).shuffle(gcons)
    case("order-cons-items-geometry", modern(subviews=subs, resources=[("image", "Logo")], root_constraints=gcons))
    lbl_far = label(I, own_constraints=[], fixed=False, frame=(175.5, 415.5, 42, 21))
    tie = [r(1, "top", IMG, V, "top", priority="750"), r(2, "top", IMG, V, "top"), r(3, "top", IMG, V, "top", priority="250"),
           r(4, "bottom", IMG, V, "bottom", relation="greaterThanOrEqual"), r(5, "bottom", IMG, V, "bottom"),
           r(6, "bottom", IMG, V, "bottom", relation="lessThanOrEqual"),
           r(7, "leading", IMG, LBL, "leading", relation="lessThanOrEqual"), r(8, "leading", IMG, S, "leading"),
           r(11, "width", IMG, V, "width", constant=10, id="abc-aa-aaa"), r(12, "width", IMG, V, "width", constant=20, id="ABD-aa-aaa"),
           r(13, "height", IMG, V, "height", multiplier="0.5", id="zzz-aa-aaa"), r(14, "height", IMG, V, "height", multiplier="0.25", id="yyy-aa-aaa")]
    tie = tie[::-1]
    case("order-cons-tiebreaks", modern(subviews=[img0, lbl_far], resources=[("image", "Logo")], root_constraints=tie,
                                        extra_capabilities=[("Constraints with non-1.0 multipliers", "5.1")]))
    # second items: same first item, attributes, priority and relation; the second item's frame x decides, then the constraint id
    seconds = [("sa1-aa-aaa", (150, 0)), ("sb1-aa-aaa", (10, 300)), ("sc1-aa-aaa", (10, 20)), ("sd1-aa-aaa", (80, 80)), ("se1-aa-aaa", (80, 0))]
    subs2 = [image_view(I, own_constraints=[], fixed=False, frame=(300, 300, 10, 10))]
    subs2 += [image_view({**I, "img": sid}, own_constraints=[], fixed=False, frame=(x, y, 10, 10)) for sid, (x, y) in seconds]
    scons = [r(i, "top", IMG, sid, "top", id=f"{'zyxwv'[i]}{i:02d}-cn-aaa") for i, (sid, _) in enumerate(seconds)]
    case("order-cons-second-item", modern(subviews=subs2, resources=[("image", "Logo")], root_constraints=scons))
    # open questions: second items that are the safe area or a label (see notes)
    case("order-cons-second-item-mixed", modern(subviews=[img0, lbl_far, img2], resources=[("image", "Logo")], root_constraints=[
        r(1, "trailing", IMG, LBL, "trailing"), r(2, "trailing", IMG, I2, "trailing"), r(3, "top", IMG, S, "top"), r(4, "top", IMG, I2, "top")]))
    case("order-cons-second-item-safe", modern(resources=[("image", "Logo")], subviews=[
        image_view(I, own_constraints=[], fixed=False, frame=(300, 300, 10, 10)),
        image_view({**I, "img": I2}, own_constraints=[], fixed=False, frame=(10, 0, 393, 10))],
        root_constraints=[r(1, "top", IMG, S, "top"), r(2, "top", IMG, I2, "top")]))
    # objects list (UINibObjectsKey) order with constraints on several levels, including a nested container view
    P, N = "Pv1-aa-aaa", "Nv1-aa-aaa"
    nested = plain_view(P, (20, 600, 353, 100), fixed=False, own_constraints=[
        constraint(cid(20, I), "height", constant=100),
        constraint(cid(21, I), "centerX", first=N, second=P, second_attr="centerX")]).replace(
        '    <rect key="frame" x="20" y="600" width="353" height="100"/>\n',
        '    <rect key="frame" x="20" y="600" width="353" height="100"/>\n    <subviews>\n'
        + indent(image_view({**I, "img": N}, fixed=False, frame=(151.5, 0, 50, 50),
                            own_constraints=[constraint(cid(22, I), "width", constant=50)]), 8) + "    </subviews>\n")
    case("order-objects-list", modern(resources=[("image", "Logo")], subviews=[
        image_view(I, fixed=False, own_constraints=[constraint(cid(1, I), "width", constant=100), constraint(cid(2, I), "height", constant=100)]),
        label(I, fixed=False, frame=(175.5, 500, 42, 21), own_constraints=[constraint(cid(3, I), "width", constant=42)]),
        nested],
        root_constraints=[constraint(cid(4, I), "centerX", first=IMG, second=V, second_attr="centerX"),
                          constraint(cid(5, I), "top", first=LBL, second=IMG, second_attr="bottom", constant=24),
                          constraint(cid(6, I), "top", first=P, second=LBL, second_attr="bottom", constant=79)]))
    case("order-cons-own", modern(subviews=[image_view(I, fixed=False, own_constraints=[
        constraint(cid(1, I), "height", constant=50), constraint(cid(2, I), "width", second=IMG, second_attr="height", multiplier="1:1"),
        constraint(cid(3, I), "width", constant=200, relation="lessThanOrEqual", priority="750"),
        constraint(cid(4, I), "width", constant=100), constraint(cid(5, I), "height", second=IMG, second_attr="width", multiplier="2:1")])],
        resources=[("image", "Logo")], extra_capabilities=[("Constraints with non-1.0 multipliers", "5.1")]))

    # value uniquing: equal colors, strings and fonts are encoded once
    SR = rgb_spec((1, 0.5, 0, 1), "sRGB")
    case("order-uniquing", document(safe_area=False, background=SR, resources=[("image", "Logo")], subviews=[
        plain_view(table_id("U", 1), (0, 0, 10, 10), SR),
        plain_view(table_id("U", 2), (0, 10, 10, 10), sys_color("systemBlueColor")),
        plain_view(table_id("U", 3), (0, 20, 10, 10), sys_color("systemBlueColor")),
        plain_view(table_id("U", 4), (0, 30, 10, 10), rgb_spec((0, 0.53333333333333333, 1, 1), "sRGB")),
        label({**I, "lbl": table_id("L", 1)}, text="Same", frame=(0, 100, 42, 21)),
        label({**I, "lbl": table_id("L", 2)}, text="Same", frame=(0, 130, 42, 21)),
        label({**I, "lbl": table_id("L", 3)}, text="view", text_color=SR, frame=(0, 160, 42, 21)),
        label({**I, "lbl": table_id("L", 4)}, text="Logo", font='type="system" pointSize="18"', frame=(0, 190, 42, 21)),
        image_view({**I, "img": table_id("M", 1)}, frame=(0, 220, 10, 10)),
        image_view({**I, "img": table_id("M", 2)}, frame=(0, 240, 10, 10))]))

    # key-table capacity boundaries: 86 keys stay in 127 buckets, 87 and 90 move to 191
    W = white_spec((0.5, 1), G22)

    def two(bg, text_color=None, tint=None, extra_root=(), res=()):
        return modern(background=bg, resources=[("image", "Logo"), *res],
                      subviews=[image_view(I, own_constraints=[], fixed=False, tint=tint),
                                label(I, own_constraints=[], fixed=False, frame=(175.5, 484, 42, 21), text_color=text_color)],
                      root_constraints=[r(1, "centerX", IMG, V, "centerX"), r(2, "centerY", IMG, V, "centerY"),
                                        r(3, "top", LBL, IMG, "bottom", constant=8), r(4, "centerX", LBL, IMG, "centerX"), *extra_root])
    NR = [("namedColor", "Brand")]
    case("keys-count-86", two(named_color("Brand"), text_color=sys_color("labelColor"), res=NR + [("systemColor", "labelColor")]))
    case("keys-count-87", two(named_color("Brand"), tint=W, res=NR))
    case("keys-count-90", two(named_color("Brand"), res=NR, extra_root=[
        r(5, "leading", LBL, S, "leading", relation="greaterThanOrEqual", constant=20)]))

    build_constraints()


def container(id_, frame, own, kids, fixed=False):
    """A plain view with subviews `kids` and its own constraints `own`."""
    x, y, w, h = frame
    rect = f'    <rect key="frame" x="{fmt(x)}" y="{fmt(y)}" width="{fmt(w)}" height="{fmt(h)}"/>\n'
    view = plain_view(id_, frame, fixed=fixed, own_constraints=own)
    return view.replace(rect, rect + "    <subviews>\n" + indent("".join(kids), 8) + "    </subviews>\n", 1)


def build_constraints():
    """Task 9: constraint values, dropped and placeholder constraints, owners that are not items, owner-first order."""
    I = IDS
    V, S, IMG, LBL = I["view"], I["safe"], I["img"], I["lbl"]
    MULT = [("Constraints with non-1.0 multipliers", "5.1")]

    def r(i, fa, first, second, sa, **kw):
        return constraint(kw.pop("id", table_id("K", i)), fa, first=first, second=second, second_attr=sa, **kw)

    def iv(prefix, i, frame=None):
        return image_view({**I, "img": table_id(prefix, i)}, own_constraints=[], fixed=False, frame=frame or (0, 10 * i, 10, 10))

    # multiplier spellings: decimals are rounded to 6 significant digits (C %g) and then to float; ratios are exact
    mults = ["2", "1.5", "0.75", "3:4", "4:3", "9:16", "1:2", "2:3", "21:9", "1:1.5", "1/2", "1", "1.0", "0.33333333333333331",
             "0.66666666666666663", "0.90000000000000002", "0.0123456789", "123.456789", "1.23456789", "0.1234565", "0.99999949",
             "0.00012345678", "0.1", "0.8"]
    case("cons-multiplier-grid", modern(resources=[("image", "Logo")], extra_capabilities=MULT,
         subviews=[iv("M", i) for i in range(len(mults))],
         root_constraints=[r(i, "width", table_id("M", i), V, "width", multiplier=m) for i, m in enumerate(mults)]))
    # constants (explicit zero, negative zero, fractions), priorities (explicit 1000, int8/int16 values), relations to
    # sibling and safe-area second items
    consts = [0, "0.0", "-0.0", 0.5, -0.5, 1000, 0.33333333333333331, -12.25, 8, 16, 20]
    prios = ["1000", "2", "100", "200", "251", "500", "700", "749", "751", "900", "998"]
    vals = [r(i, "top", table_id("C", i), V, "top", constant=c) for i, c in enumerate(consts)]
    vals += [r(20 + i, "leading", table_id("C", i), V, "leading", priority=p) for i, p in enumerate(prios)]
    vals += [r(40, "trailing", table_id("C", 0), table_id("C", 1), "trailing", relation="greaterThanOrEqual", constant=8),
             r(41, "bottom", table_id("C", 2), S, "bottom", relation="lessThanOrEqual", constant=-20),
             r(42, "bottom", S, table_id("C", 3), "bottom", relation="greaterThanOrEqual", constant=20, priority="750"),
             r(43, "centerX", table_id("C", 4), table_id("C", 5), "centerX", relation="lessThanOrEqual", multiplier="0.5")]
    case("cons-values-grid", modern(resources=[("image", "Logo")], extra_capabilities=MULT,
         subviews=[iv("C", i) for i in range(len(prios))], root_constraints=vals))
    # standard spacing (symbolic) between siblings and to the superview
    case("cons-symbolic-siblings", modern(resources=[("image", "Logo")],
         subviews=[image_view(I, own_constraints=[], fixed=False), label(I, own_constraints=[], fixed=False, frame=(175.5, 484, 42, 21))],
         root_constraints=[r(1, "centerX", IMG, V, "centerX"), r(2, "centerY", IMG, V, "centerY"),
                           r(3, "top", LBL, IMG, "bottom", constant=8, symbolic="YES"),
                           r(4, "bottom", V, LBL, "bottom", constant=20, symbolic="YES"),
                           r(5, "leading", LBL, S, "leading", constant=8, symbolic="YES")]))
    # identifiers; placeholder constraints (removed at build time), one of them the only constraint of its view
    case("cons-identifier-placeholder", modern(resources=[("image", "Logo")], subviews=[
        image_view(I, fixed=False, own_constraints=[constraint(cid(1, I), "width", constant=100, identifier="logoWidth"),
                                                    constraint(cid(2, I), "height", constant=100, placeholder="YES")]),
        iv("P", 1, (20, 700, 10, 10))],
        root_constraints=[r(3, "centerX", IMG, V, "centerX", identifier="logo centerX"),
                          r(4, "centerY", IMG, V, "centerY", placeholder="YES"),
                          r(5, "top", IMG, S, "top", identifier="Lögo top", priority="750", constant=20),
                          r(6, "leading", table_id("P", 1), V, "leading", placeholder="YES")]))
    # the safe area used only by placeholder constraints: no owned guide, no UIViewLayoutGuides
    case("cons-placeholder-safearea", modern(resources=[("image", "Logo")], subviews=[image_view(I, own_constraints=[], fixed=False)],
         root_constraints=[r(1, "centerX", IMG, V, "centerX"), r(2, "top", IMG, S, "top", constant=20, placeholder="YES"),
                           r(3, "bottom", S, IMG, "bottom", placeholder="YES")]))
    # ibtool drops root.width = item.height and root.height = item.width (root view as first item, written or implicit)
    # for every kind of item and every value; a view or safe area only in such constraints is not constrained
    P1, N1 = "Pv1-aa-aaa", "Nv1-aa-aaa"
    nested = container(P1, (20, 600, 100, 100), [r(1, "width", P1, N1, "height"), r(2, "top", N1, P1, "top"), r(3, "height", P1, N1, "width")],
                       [image_view({**I, "img": N1}, fixed=False, frame=(10, 10, 50, 50), own_constraints=[])])
    case("cons-dropped-root-size", modern(resources=[("image", "Logo")], extra_capabilities=MULT, subviews=[
        iv("D", 1, (0, 0, 10, 10)), label(I, own_constraints=[], fixed=False, frame=(20, 500, 42, 21)), nested],
        root_constraints=[r(10, "width", V, table_id("D", 1), "height", multiplier="0.5"),
                          r(11, "height", V, LBL, "width", constant=10), r(12, "top", LBL, V, "top"),
                          r(13, "width", V, S, "height", relation="lessThanOrEqual"),
                          r(14, "height", V, P1, "width", priority="750"), r(15, "top", P1, V, "top"),
                          constraint(table_id("K", 16), "width", second=LBL, second_attr="height"),
                          r(17, "width", LBL, V, "height")]))
    # views that own constraints between their subviews but are no item of any constraint (open question 11);
    # the owner's own constraints come before those of a subview at (0, 0), whatever the ids
    A, B = "Aaa-aa-aaa", "Bbb-bb-bbb"
    kids = [image_view({**I, "img": A}, fixed=False, frame=(10, 10, 20, 20), own_constraints=[]),
            image_view({**I, "img": B}, fixed=False, frame=(10, 40, 20, 20), own_constraints=[])]
    between = [r(1, "top", B, A, "bottom", constant=8), r(2, "leading", B, A, "leading")]
    kids2 = [image_view({**I, "img": "Ccc-aa-aaa"}, fixed=False, frame=(10, 10, 20, 20), own_constraints=[]),
             image_view({**I, "img": "Ddd-bb-bbb"}, fixed=False, frame=(10, 40, 20, 20), own_constraints=[])]
    case("cons-owner-not-item", modern(resources=[("image", "Logo")], subviews=[
        container("Pv1-aa-aaa", (20, 100, 100, 100), between, kids),
        container("Pv2-aa-aaa", (20, 300, 100, 100), [r(3, "top", "Ddd-bb-bbb", "Ccc-aa-aaa", "bottom", constant=8)], kids2, fixed=True)]))
    owners = []
    for n, pid in enumerate(("000-aa-aaa", "Mmm-aa-aaa", "zzz-aa-aaa")):
        kid = f"Kk{n}-aa-aaa"
        owners.append(container(pid, (20, 100 + 150 * n, 100, 100), [
            r(10 * n + 1, "top", kid, pid, "top"), constraint(table_id("K", 10 * n + 2), "height", constant=100),
            r(10 * n + 3, "leading", kid, pid, "leading"), constraint(table_id("K", 10 * n + 4), "width", constant=100),
            r(10 * n + 5, "width", pid, pid, "height")],
            [image_view({**I, "img": kid}, fixed=False, frame=(0, 0, 20, 20), own_constraints=[])]))
    case("order-cons-owner-first", modern(resources=[("image", "Logo")], subviews=owners,
         root_constraints=[r(50 + n, "top", pid, V, "top") for n, pid in enumerate(("000-aa-aaa", "Mmm-aa-aaa", "zzz-aa-aaa"))]))
    # a realistic launch screen: full-screen background image, centred logo, label pinned to the safe area
    BG = "Bg1-aa-aaa"
    bg = image_view({**I, "img": BG}, image="Banner", mode="scaleAspectFill", own_constraints=[], fixed=False, frame=(0, 0, 393, 852))
    logo = image_view(I, own_constraints=[constraint(cid(1, I), "width", constant=120),
                                          constraint(cid(2, I), "width", second=IMG, second_attr="height", multiplier="1:1")],
                      fixed=False, frame=(136.5, 366, 120, 120))
    lbl = label(I, text="Version 1.0", own_constraints=[], fixed=False, frame=(152, 777, 89, 21),
                text_color=sys_color("secondaryLabelColor"))
    case("real-background-logo-label", modern(resources=[
        ("image", "Logo"), ("image", "Banner"),
        ("systemColor", ("secondaryLabelColor", 'red="0.23529411764705882" green="0.23529411764705882" blue="0.2627450980392157" alpha="0.59999999999999998" colorSpace="custom" customColorSpace="sRGB"'))],
        extra_capabilities=MULT, subviews=[bg, logo, lbl], root_constraints=[
            r(3, "leading", BG, V, "leading"), r(4, "trailing", V, BG, "trailing"), r(5, "top", BG, V, "top"), r(6, "bottom", V, BG, "bottom"),
            r(7, "centerX", IMG, V, "centerX"), r(8, "centerY", IMG, V, "centerY"),
            r(9, "centerX", LBL, S, "centerX"), r(10, "bottom", S, LBL, "bottom", constant=20),
            r(11, "leading", LBL, S, "leading", relation="greaterThanOrEqual", constant=20)]), ALL)

    # objects list: breadth-first over the views' entries, with sibling containers that have grandchildren
    # (root -> A{A1{A11}, A2}, B{B1{B11}}, C), first with fixed frames, then with constraints on every level
    def tree(cons):
        def img(id_, frame, own=None):
            return image_view({**I, "img": id_}, frame=frame, fixed=not cons, own_constraints=own if cons else None)
        def box(id_, frame, own, kids):
            return container(id_, frame, own if cons else [], kids, fixed=not cons)
        a1 = box("A1v-aa-aaa", (10, 10, 100, 100), [r(11, "top", "A11-aa-aaa", "A1v-aa-aaa", "top", constant=8),
                                                     r(12, "centerX", "A11-aa-aaa", "A1v-aa-aaa", "centerX")],
                 [img("A11-aa-aaa", (25, 8, 50, 50), [constraint(table_id("K", 13), "width", constant=50)])])
        a = box("Aav-aa-aaa", (0, 100, 300, 300), [r(14, "leading", "A1v-aa-aaa", "Aav-aa-aaa", "leading", constant=10),
                                                    r(15, "top", "A2v-aa-aaa", "A1v-aa-aaa", "bottom", constant=8)],
                [a1, img("A2v-aa-aaa", (10, 118, 20, 20), [constraint(table_id("K", 16), "height", constant=20)])])
        b1 = box("B1v-aa-aaa", (0, 0, 100, 50), [r(17, "bottom", "B1v-aa-aaa", "B11-aa-aaa", "bottom")],
                 [img("B11-aa-aaa", (0, 30, 20, 20))])
        b = box("Bbv-aa-aaa", (0, 500, 393, 100), [r(18, "trailing", "Bbv-aa-aaa", "B1v-aa-aaa", "trailing")], [b1])
        c = img("Ccv-aa-aaa", (146.5, 700, 100, 100), [constraint(table_id("K", 19), "width", constant=100)])
        root = [r(20, "top", "Aav-aa-aaa", V, "top", constant=100), r(21, "top", "Bbv-aa-aaa", "Aav-aa-aaa", "bottom", constant=100),
                r(22, "centerX", "Ccv-aa-aaa", V, "centerX"), r(23, "bottom", S, "Ccv-aa-aaa", "bottom", constant=18)] if cons else []
        return modern(resources=[("image", "Logo")], subviews=[a, b, c], root_constraints=root)
    case("order-objects-bfs", tree(False))
    case("order-objects-bfs-constraints", tree(True))
    # open: mirrored constraints (one written owner-first) that tie through step 6 are not ordered by id
    A0 = "aaa-aa-aaa"
    case("order-cons-mirrored-tie", modern(resources=[("image", "Logo")],
         subviews=[image_view({**I, "img": A0}, own_constraints=[], fixed=False, frame=(10, 10, 100, 20))],
         root_constraints=[r(1, "top", V, A0, "bottom"), r(2, "top", A0, V, "bottom")]))
    # mirrored constraints with the same attribute on both sides tie and are ordered by id, whichever is written from
    # the owning view (A at the origin so that the safe area and A tie on the first item too)
    case("order-cons-mirrored-same", modern(resources=[("image", "Logo")],
         subviews=[image_view({**I, "img": A0}, own_constraints=[], fixed=False, frame=(0, 0, 100, 20))],
         root_constraints=[r(2, "top", V, A0, "top"), r(1, "top", A0, V, "top"),
                           r(3, "leading", V, A0, "leading"), r(4, "leading", A0, V, "leading"),
                           r(6, "bottom", V, S, "bottom"), r(5, "bottom", S, V, "bottom"),
                           r(7, "centerX", V, S, "centerX"), r(8, "centerX", S, V, "centerX")]))
    # the same in a subview's list: not ordered by id (shape of differential seed 1, case d1-0045)
    case("order-cons-mirrored-nested", modern(resources=[("image", "Logo")], subviews=[
        container("Pv1-aa-aaa", (10, 10, 212.2, 10), [r(1, "width", "Cv1-aa-aaa", "Pv1-aa-aaa", "width", id="twf-789-anu"),
                                                      r(2, "width", "Pv1-aa-aaa", "Cv1-aa-aaa", "width", id="gNn-790-CRz")],
                  [plain_view("Cv1-aa-aaa", (114.3, 100, 393, 10), fixed=False, own_constraints=[])])],
        root_constraints=[r(3, "top", "Pv1-aa-aaa", V, "top", constant=10)]))
    # leading/trailing paired with left/right in one constraint: ibtool rewrites the attributes (refused)
    case("cons-mixed-horizontal", modern(resources=[("image", "Logo")],
         subviews=[image_view({**I, "img": A0}, own_constraints=[], fixed=False, frame=(16, 10, 100, 20))],
         root_constraints=[r(1, "top", A0, V, "top"), r(2, "leading", A0, V, "left", constant=16)]))


# Final review C1: ibtool rounds every color component to 10 significant digits (C "%.10g") and makes the float and
# the -Double value from the rounded number. These values cover components below 0.1 (n/255 for n = 1…25, decimals,
# exponent spellings down to 1e-11), roundings that cross a decade (0.0999999999949 → 0.09999999999,
# 0.099999999995 → 0.1) or a float rounding boundary (the last three), roundings to a float-exact value (no -Double
# key: 0.5000000000001), and a %.3g text tie (0.12350000000001).
SMALL = [k / 255 for k in range(1, 26)] + [
    0.001, 0.0001, 0.0005, 1e-05, 1e-06, 2e-06, 1e-07, 1e-11, 1.2345678901234567e-05, 0.00012345678901234,
    0.012345678901234, 0.0123456789049999, 0.0123456789050001, 0.01234567891, 0.0999999999949, 0.099999999995,
    0.098765432109876, 0.12345678905, 0.12345678904999, 0.12350000000001, 0.5000000000001, 0.50000000001,
    0.5000000000049, 0.99999999995, 0.999999999949, 0.999999, 1.1920928955078125e-07,
    0.012300000060349713, 0.3000000268220902, 0.070000004023313536]
# A gray component this close to 0 or 1 (but not equal) is snapped to black/white by ibtool with a tolerance that is
# not pinned down (open question 14): the compiler refuses it, so the gray grid leaves those values out.
GRAY_BAND = 1e-06
SMALL_GRAY = [v for v in SMALL if GRAY_BAND <= v <= 1 - GRAY_BAND]


def build_final_review():
    """Cases added by the final-review fix round (docs/research/nib-encoding.md cites each one)."""
    I = IDS
    G22 = "genericGamma22GrayColorSpace"
    n = len(SMALL)
    rgb = [rgb_spec((SMALL[i], SMALL[(i + 7) % n], SMALL[(i + 13) % n], SMALL[(i + 29) % n]), "sRGB") for i in range(n)]
    # equal after rounding: one shared color object
    rgb += [rgb_spec((0.0123456789050001, 0.5, 0.5, 1), "sRGB"), rgb_spec((0.01234567891, 0.5, 0.5, 1), "sRGB")]
    case("color-srgb-small-grid", color_table(rgb), ALL)
    m = len(SMALL_GRAY)
    case("color-white-small-grid", color_table([white_spec((SMALL_GRAY[i], SMALL_GRAY[(i + 5) % m]), G22) for i in range(m)]), ALL)
    # the same rule for a named-color resource, a label text color and an image-view tint
    small_rgb = rgb_spec((13 / 255, 0.0123456789050001, 1.2345678901234567e-05, 0.098765432109876), "sRGB")
    named = modern(background=named_color("Brand"), resources=[("namedColor", "Brand"), ("image", "Logo")], subviews=[
        image_view(I, tint=white_spec((1 / 255, 0.0999999999949), G22)),
        label(I, frame=(175.5, 500, 42, 21), text_color=rgb_spec((0.07058823529411765, 0.5, 1 / 255, 1), "sRGB"))])
    case("color-small-forms", named.replace(f"<color {BRAND}/>", f"<color {small_rgb}/>"), ALL)
    # named-color resources are NOT rounded: one named color per grid color, its resource holding the raw values
    names = [f"Small{i:02d}" for i in range(n)]
    text = document(safe_area=False, resources=[("namedColor", nm) for nm in names],
                    subviews=[plain_view(table_id("T", i), (0, 10 * i, 10, 10), named_color(nm)) for i, nm in enumerate(names)])
    for nm, spec in zip(names, rgb):
        text = text.replace(f'<namedColor name="{nm}">\n            <color {BRAND}/>', f'<namedColor name="{nm}">\n            <color {spec}/>', 1)
    assert BRAND not in text
    case("color-named-small-grid", text, ALL)

    # Final review I1: an image view's tint of systemColor="tintColor" (the default tint) is omitted; the same color
    # everywhere else (root, plain view, image view and label backgrounds, label text) is encoded, as are clear
    # backgrounds and other tints (clear, sRGB system blue) and default-looking text colors (darkTextColor).
    CLEAR = white_spec((0, 0), G22)
    TINT = sys_color("tintColor")

    def with_bg(view_text, spec):
        i = view_text.rstrip().rfind("</")
        return view_text[:i] + f'    <color key="backgroundColor" {spec}/>\n' + view_text[i:]
    case("image-tint-default", image_case(tint=TINT), ALL)
    case("color-default-forms", modern(background=TINT, resources=[("image", "Logo"), ("systemColor", ("darkTextColor", SYSTEM_COLORS["labelColor"]))], subviews=[
        with_bg(image_view({**I, "img": table_id("M", 1)}, frame=(0, 100, 10, 10), tint=TINT), CLEAR),
        image_view({**I, "img": table_id("M", 2)}, frame=(0, 120, 10, 10), tint=CLEAR),
        image_view({**I, "img": table_id("M", 3)}, frame=(0, 140, 10, 10), image=None, tint=TINT),
        with_bg(image_view({**I, "img": table_id("M", 4)}, frame=(0, 160, 10, 10)), TINT),
        image_view({**I, "img": table_id("M", 5)}, frame=(0, 180, 10, 10), tint=rgb_spec((0, 0.53333333333333333, 1, 1), "sRGB")),
        with_bg(label({**I, "lbl": table_id("L", 1)}, frame=(0, 200, 42, 21), text_color=TINT), CLEAR),
        with_bg(label({**I, "lbl": table_id("L", 2)}, frame=(0, 230, 42, 21), text_color=sys_color("darkTextColor")), TINT),
        plain_view(table_id("P", 1), (0, 260, 10, 10), TINT),
        plain_view(table_id("P", 2), (0, 280, 10, 10), CLEAR)]), ALL)

    # Final review I3: key tables above 90 keys. Each step adds properties to keys-count-90 (one to three new keys
    # each), up to 107 keys: every key the compiler can write next to the safe area (the 110 keys of the corpus minus
    # the three of the legacy layout guides). A legacy-guide variant has a different key set.
    for n, (keys, text) in enumerate(rich_steps()):
        case(f"keys-count-{keys}", text, ALL if n == len(RICH_KEYS) - 1 else None)
    case("keys-count-legacy", rich(RICH_FEATURES, safe_area=False))

    # Final review I4: the compiler accepts views nested up to 32 levels (the root view is level 1): 30 plain views,
    # each inside the previous one, with a label at level 32.
    inner = label({**I, "lbl": table_id("D", 32)}, frame=(0, 0, 42, 21))
    for level in range(31, 1, -1):
        inner = container(table_id("D", level), (1, 1, 300 - level, 600 - level), None, [inner], fixed=True)
    case("nesting-32-levels", modern(subviews=[inner]), ALL)
    case("color-white-near-black", document(background=white_spec((1.1e-07, 1), G22)))
    case("color-white-near-white", document(background=white_spec((0.99999999, 1), G22)))


# --- Expo splash screens (milestone 3, Task 6b) -------------------------------------------------------

# Accessibility trait attributes of `<accessibilityTraits key="traits">` that ibtool encodes (acc-traits-grid).
TRAITS = ["button", "link", "image", "selected", "playsSound", "keyboardKey", "staticText", "summaryElement", "notEnabled",
          "updatesFrequently", "searchField", "startsMediaSession", "adjustable", "allowsDirectInteraction", "causesPageTurn",
          "header"]


def accessibility(traits):
    """Xcode's `<accessibility>` element; `traits` is the attribute string of `<accessibilityTraits>` (' image="YES"')."""
    return ('<accessibility key="accessibilityConfiguration">\n'
            f'    <accessibilityTraits key="traits"{traits}/>\n'
            '</accessibility>\n')


def acc_image(id_, traits, frame=(0, 0, 10, 10)):
    """A fixed-frame image view with an `<accessibility>` element (Xcode's layout: after the autoresizing mask)."""
    return image_view({**IDS, "img": id_}, frame=frame).replace(
        "</imageView>", indent(accessibility(traits), 4) + "</imageView>")


def acc_label(id_, traits, frame, font='type="system" pointSize="17"'):
    return label({**IDS, "lbl": id_}, frame=frame, font=font).replace(
        '    <nil key="highlightedColor"/>', indent(accessibility(traits), 4) + '    <nil key="highlightedColor"/>')


def acc_view(id_, traits, frame, kids=()):
    v = container(id_, frame, None, list(kids), fixed=True)
    return v[:v.rindex("</view>")] + indent(accessibility(traits), 4) + "</view>\n"


def expo_hex(h):
    """expo-splash-screen's spelling of a #RRGGBB channel: (n / 255).toPrecision(15), trailing zeros kept."""
    return ["%#.15g" % (int(h[i:i + 2], 16) / 255) for i in (1, 3, 5)]


def expo_named_spec(h):
    r, g, b = expo_hex(h)
    return f'alpha="1.000" blue="{b}" green="{g}" red="{r}" customColorSpace="sRGB" colorSpace="custom"'


def expo_constraint_id(*parts):
    """expo-splash-screen's constraint ids: sha1 of the joined (firstItem, firstAttribute, secondItem, secondAttribute)."""
    import hashlib
    return hashlib.sha1("-".join(parts).encode()).hexdigest()


def expo_splash(color, image="SplashScreenLogo", width=200, mode="scaleAspectFit", full_screen=False):
    """The storyboard expo-splash-screen's config plugin writes for a configured splash screen (image, background
    color): Expo's template, re-serialized by xml2js (4-space indent, no comments), with its image view (lowercase
    `true`/`false`), centerX/centerY constraints (top/leading/trailing/bottom for `enableFullScreenImage`), the
    `SplashScreenBackground` named color in Expo's number spelling, and the image resource."""
    img_id, box = "EXPO-SplashScreen", "EXPO-ContainerView"
    w, h = (414, 736) if full_screen else (width, width)
    x, y = (0, 0) if full_screen else ((393 - w) / 2, (852 - h) / 2)
    js = lambda v: str(int(v)) if float(v).is_integer() else repr(float(v))  # JavaScript's Number to string
    attrs = ["top", "leading", "trailing", "bottom"] if full_screen else ["centerX", "centerY"]
    cons = "".join(f'                            <constraint firstItem="{img_id}" firstAttribute="{a}" secondItem="{box}" '
                   f'secondAttribute="{a}" id="{expo_constraint_id(img_id, a, box, a)}"/>\n' for a in attrs)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="24093.7" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="EXPO-VIEWCONTROLLER-1">
    <device id="retina6_12" orientation="portrait" appearance="light"/>
    <dependencies>
        <deployment identifier="iOS"/>
        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="24053.1"/>
        <capability name="Named colors" minToolsVersion="9.0"/>
        <capability name="Safe area layout guides" minToolsVersion="9.0"/>
        <capability name="System colors in document resources" minToolsVersion="11.0"/>
        <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
    </dependencies>
    <scenes>
        <scene sceneID="EXPO-SCENE-1">
            <objects>
                <viewController storyboardIdentifier="SplashScreenViewController" id="EXPO-VIEWCONTROLLER-1" sceneMemberID="viewController">
                    <view key="view" userInteractionEnabled="NO" contentMode="scaleToFill" insetsLayoutMarginsFromSafeArea="NO" id="{box}" userLabel="ContainerView">
                        <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                        <autoresizingMask key="autoresizingMask" flexibleMaxX="YES" flexibleMaxY="YES"/>
                        <subviews>
                            <imageView id="{img_id}" userLabel="{image}" image="{image}" contentMode="{mode}" clipsSubviews="true" userInteractionEnabled="false" translatesAutoresizingMaskIntoConstraints="false">
                                <rect key="frame" x="{js(x)}" y="{js(y)}" width="{js(w)}" height="{js(h)}"/>
                            </imageView>
                        </subviews>
                        <viewLayoutGuide key="safeArea" id="Rmq-lb-GrQ"/>
                        <constraints>
{cons}                        </constraints>
                        <color key="backgroundColor" name="SplashScreenBackground"/>
                    </view>
                </viewController>
                <placeholder placeholderIdentifier="IBFirstResponder" id="EXPO-PLACEHOLDER-1" userLabel="First Responder" sceneMemberID="firstResponder"/>
            </objects>
            <point key="canvasLocation" x="0.0" y="0.0"/>
        </scene>
    </scenes>
    <resources>
        <image name="{image}" width="{js(w)}" height="{js(h)}"/>
        <systemColor name="systemBackgroundColor">
            <color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
        </systemColor>
        <namedColor name="SplashScreenBackground">
            <color {expo_named_spec(color)}/>
        </namedColor>
    </resources>
</document>
"""


def build_expo():
    """Expo's SplashScreen.storyboard (react-native-ios-contract.md, "HelloRN reference"): the constructs outside the
    milestone 2a subset, one at a time, then the two shapes Expo generates (docs/research/nib-encoding.md cites each)."""
    I = IDS
    V, IMG, LBL = I["view"], I["img"], I["lbl"]

    def centered(**kw):
        return modern(subviews=[image_view(I, own_constraints=[constraint(cid(1, I), "width", constant=100),
                                                               constraint(cid(2, I), "height", constant=100)], fixed=False)],
                      root_constraints=[constraint(cid(3, I), "centerX", first=IMG, second=V, second_attr="centerX"),
                                        constraint(cid(4, I), "centerY", first=IMG, second=V, second_attr="centerY")],
                      resources=[("image", "Logo")], **kw)

    # storyboardIdentifier on the view controller: names the view-controller nib and its Info.plist entries
    for suffix, ident in [("", "SplashScreenViewController"), ("-short", "Splash"), ("-punct", "Launch Screen.v2_x-y+z"),
                          ("-shared", "UIViewController")]:
        case(f"vc-storyboard-identifier{suffix}", centered(vc_attrs=f' storyboardIdentifier="{ident}"'), ALL)

    # root view attributes Expo's template sets: userInteractionEnabled, insetsLayoutMarginsFromSafeArea, userLabel
    case("root-userinteraction-no", centered(root_attrs=(' userInteractionEnabled="NO"', "", "")), ALL)
    case("root-userinteraction-yes", centered(root_attrs=(' userInteractionEnabled="YES"', "", "")))
    case("root-insets-no", centered(root_attrs=("", ' insetsLayoutMarginsFromSafeArea="NO"', "")), ALL)
    case("root-insets-yes", centered(root_attrs=("", ' insetsLayoutMarginsFromSafeArea="YES"', "")))
    pinned = modern(subviews=[label(I, text="Loading", own_constraints=[], fixed=False, frame=(20, 500, 353, 21))],
                    root_constraints=[constraint(cid(1, I), "leading", first=LBL, second=I["safe"], second_attr="leading", constant=20),
                                      constraint(cid(2, I), "centerY", first=LBL, second=V, second_attr="centerY")],
                    root_attrs=("", ' insetsLayoutMarginsFromSafeArea="NO"', ""))
    case("root-insets-no-safearea", pinned, ALL)
    case("root-insets-no-legacy", document(safe_area=False, root_attrs=("", ' insetsLayoutMarginsFromSafeArea="NO"', "")))

    # userLabel (Interface Builder's document-outline name) on every view kind
    labelled = modern(root_attrs=("", "", ' userLabel="Container View"'), resources=[("image", "Logo")], subviews=[
        image_view(I).replace(f'id="{IMG}">', f'id="{IMG}" userLabel="Logo Image">'),
        label(I, frame=(175.5, 500, 42, 21)).replace(f'id="{LBL}">', f'id="{LBL}" userLabel="Caption">'),
        plain_view(table_id("P", 1), (0, 0, 10, 10)).replace('">\n', '" userLabel="Spacer">\n', 1)])
    case("view-userlabel-grid", labelled, ALL)

    # lowercase true/false (expo-splash-screen writes them) for the three boolean attributes, on every view kind;
    # each view is constrained, so translatesAutoresizingMaskIntoConstraints counts
    variants = [' clipsSubviews="true"', ' clipsSubviews="false"', ' userInteractionEnabled="false"',
                ' userInteractionEnabled="true"', ' translatesAutoresizingMaskIntoConstraints="false"',
                ' translatesAutoresizingMaskIntoConstraints="true"']
    subs = []
    for k, attr in enumerate(variants):
        own = lambda n: [constraint(table_id("W", n), "width", constant=10)]
        tr = "translatesAutoresizingMaskIntoConstraints" in attr
        iv = image_view({**I, "img": table_id("I", k)}, frame=(10 * k, 0, 10, 10), own_constraints=own(k), fixed=False)
        iv = iv.replace(' clipsSubviews="YES" userInteractionEnabled="NO"', "")
        iv = iv.replace(' translatesAutoresizingMaskIntoConstraints="NO"', attr if tr else ' translatesAutoresizingMaskIntoConstraints="NO"')
        if not tr:
            iv = iv.replace("<imageView", "<imageView" + attr, 1)
        lb = label({**I, "lbl": table_id("L", k)}, frame=(10 * k, 100, 42, 21), own_constraints=own(10 + k), fixed=False)
        lb = lb.replace(' userInteractionEnabled="NO"', "")
        lb = lb.replace(' translatesAutoresizingMaskIntoConstraints="NO"', attr if tr else ' translatesAutoresizingMaskIntoConstraints="NO"')
        if not tr:
            lb = lb.replace("<label", "<label" + attr, 1)
        pv = plain_view(table_id("V", k), (10 * k, 200, 10, 10), own_constraints=own(20 + k), fixed=False)
        pv = pv.replace(' translatesAutoresizingMaskIntoConstraints="NO"', attr if tr else ' translatesAutoresizingMaskIntoConstraints="NO"')
        if not tr:
            pv = pv.replace("<view", "<view" + attr, 1)
        subs += [iv, lb, pv]
    case("bool-lowercase-grid", modern(subviews=subs, resources=[("image", "Logo")]), ALL)

    # accessibility traits: one image view per trait, then no trait, image="NO", Expo's image + notEnabled, every
    # trait (an int32), every trait but header (int16 32767), header + image, and a repeated value (shared NSNumber)
    yes = lambda names: "".join(f' {t}="YES"' for t in names)
    grid = [yes([t]) for t in TRAITS] + ["", ' image="NO"', yes(["image", "notEnabled"]), yes(TRAITS),
                                         yes(TRAITS[:-1]), yes(["image", "header"]), yes(["image"])]
    case("acc-traits-grid", modern(subviews=[acc_image(table_id("A", i), t, (0, 10 * i, 10, 10)) for i, t in enumerate(grid)],
                                   resources=[("image", "Logo")]), ALL)
    # configurations on every view kind and the root, in objects-list (breadth-first) order: root, I3, A, I2, then
    # A's subviews I1 and L (ids deliberately unsorted)
    nested = acc_view("Aaa-vw-001", yes(["header"]), (0, 100, 200, 200), kids=[
        acc_image("zI1-im-001", yes(["link"]), (0, 0, 10, 10)), acc_label("bL1-lb-001", yes(["staticText", "button"]), (0, 50, 42, 21))])
    case("acc-kinds-order", modern(root_extra=accessibility(yes(["summaryElement"])), resources=[("image", "Logo")], subviews=[
        acc_image("mI3-im-003", yes(["selected"]), (0, 0, 10, 10)), nested, acc_image("Ab2-im-002", yes(["playsSound"]), (0, 400, 10, 10))]), ALL)
    # the traits NSNumber is shared by value with the fonts' numbers (17 = button + playsSound = 17 pt; 1 = button =
    # the italic trait)
    case("acc-number-sharing", modern(resources=[("image", "Logo")], subviews=[
        label({**I, "lbl": table_id("L", 1)}, frame=(0, 0, 42, 21)),
        label({**I, "lbl": table_id("L", 2)}, frame=(0, 30, 42, 21), font='type="italicSystem" pointSize="12"'),
        acc_image(table_id("A", 1), yes(["button", "playsSound"]), (0, 60, 10, 10)),
        acc_image(table_id("A", 2), yes(["button"]), (0, 80, 10, 10))]), ALL)

    # named-color resources in expo-splash-screen's spelling (toPrecision(15), alpha "1.000")
    hexes = ["#000000", "#FFFFFF", "#3355CC", "#010203", "#808080", "#FEFDFC", "#1A2B3C"]
    names = [f"Expo{i}" for i in range(len(hexes))]
    text = modern(background=named_color(names[0]), resources=[("namedColor", nm) for nm in names],
                  subviews=[plain_view(table_id("T", i), (0, 10 * i, 10, 10), named_color(nm)) for i, nm in enumerate(names[1:])])
    for nm, hx in zip(names, hexes):
        text = text.replace(f'<namedColor name="{nm}">\n            <color {BRAND}/>', f'<namedColor name="{nm}">\n            <color {expo_named_spec(hx)}/>', 1)
    assert BRAND not in text
    case("color-named-expo-spelling", text, ALL)

    # Expo's template names an image ("SplashScreen") that no <resources><image> lists (only "SplashScreenLogo")
    case("image-missing-other-resource", modern(subviews=[image_view(I, image="SplashScreen")], resources=[("image", "Logo")]), ALL)

    # the storyboard expo-splash-screen writes for a configured splash screen, and its enableFullScreenImage form
    # (neutral colours; real-expo-splash-template is the unconfigured template, hand-maintained)
    case("real-expo-splash-configured", expo_splash("#3355CC"), ALL)
    case("real-expo-splash-fullscreen", expo_splash("#FFFFFF", mode="scaleAspectFill", full_screen=True), ALL)


RICH_FEATURES = ["tint", "alpha", "lines", "enabled", "baseline", "linebreak", "shrink", "comp", "mult", "prio", "symbolic",
                 "textstyle", "italic"]
# xless key counts of rich(RICH_FEATURES[:n]) for n = 1…13 (rich(()) is keys-count-90's key set)
RICH_KEYS = [92, 93, 94, 95, 96, 97, 100, 101, 102, 103, 104, 106, 107]


def rich(features, safe_area=True):
    """keys-count-90's image view + label, plus the given properties (see RICH_FEATURES)."""
    I = IDS
    V, S, IMG, LBL = I["view"], I["safe"], I["img"], I["lbl"]
    f = set(features)
    tint = white_spec((0.33333333333333331, 0.69999999999999996 if "alpha" in f else 1), "genericGamma22GrayColorSpace") if "tint" in f else None
    lbl = label(I, own_constraints=[], fixed=False, frame=(175.5, 484, 42, 21), lines=0 if "lines" in f else None,
                line_break="wordWrap" if "linebreak" in f else "tailTruncation")
    if "enabled" in f:
        lbl = lbl.replace(' lineBreakMode=', ' enabled="NO" lineBreakMode=')
    if "baseline" in f:
        lbl = lbl.replace('baselineAdjustment="alignBaselines"', 'baselineAdjustment="alignCenters"')
    if "shrink" in f:
        lbl = lbl.replace(' adjustsFontSizeToFit="NO"', ' minimumScaleFactor="0.5"')
    if "comp" in f:
        lbl = lbl.replace(' verticalHuggingPriority="251"', ' verticalHuggingPriority="251" horizontalCompressionResistancePriority="751"', 1)
    subs = [image_view(I, own_constraints=[], fixed=False, tint=tint), lbl]
    if "textstyle" in f:
        subs.append(label({**I, "lbl": "Lb2-xT-9pQ"}, frame=(0, 700, 42, 21), font='style="UICTFontTextStyleBody"').replace(
            ' adjustsFontSizeToFit="NO"', ' adjustsFontSizeToFit="NO" adjustsFontForContentSizeCategory="YES"'))
    if "italic" in f:
        subs.append(label({**I, "lbl": "Lb3-xT-9pQ"}, frame=(0, 750, 42, 21), font='type="italicSystem" pointSize="17"'))
    G = S if safe_area else V

    def r(i, fa, first, second, sa, **kw):
        return constraint(table_id("K", i), fa, first=first, second=second, second_attr=sa, **kw)
    cons = [r(1, "centerX", IMG, V, "centerX"), r(2, "centerY", IMG, V, "centerY"), r(3, "top", LBL, IMG, "bottom", constant=8),
            r(4, "centerX", LBL, IMG, "centerX"), r(5, "leading", LBL, G, "leading", relation="greaterThanOrEqual", constant=20)]
    if "mult" in f:
        cons.append(r(6, "width", IMG, V, "width", multiplier="0.25"))
    if "prio" in f:
        cons.append(r(7, "leading", IMG, G, "leading", relation="greaterThanOrEqual", constant=8, priority="750"))
    if "symbolic" in f:
        cons.append(r(8, "trailing", G, LBL, "trailing", relation="greaterThanOrEqual", constant=20, symbolic="YES"))
    return modern(background=named_color("Brand"), resources=[("image", "Logo"), ("namedColor", "Brand")], subviews=subs,
                  root_constraints=cons, safe_area=safe_area, legacy_guides=not safe_area)


def rich_steps():
    return [(k, rich(RICH_FEATURES[:n + 1])) for n, k in enumerate(RICH_KEYS)]


def shuffle_attributes(text):
    """Permutes attributes inside every start tag (except the XML declaration), deterministically."""
    rng = random.Random(1234)

    def repl(m):
        name, body, close = m.group(1), m.group(2), m.group(3)
        pairs = re.findall(r'\s+([\w.:-]+="[^"]*")', body)
        if len(pairs) < 2:
            return m.group(0)
        orig = list(pairs)
        while pairs == orig:
            rng.shuffle(pairs)
        return f"<{name} " + " ".join(pairs) + close
    return re.sub(r'<(\w+)((?:\s+[\w.:-]+="[^"]*")+)\s*(/?>)', repl, text)


# --- catalog ------------------------------------------------------------------------------------------

def png(width, height, rgba=(0x33, 0x66, 0x99, 0xFF)):
    raw = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def write_catalog():
    cat = CORPUS / "Assets.xcassets"
    info = {"info": {"author": "xcode", "version": 1}}
    files = {"Contents.json": info}
    for name, (w, h) in (("Logo", (1, 1)), ("Banner", (128, 64))):
        files[f"{name}.imageset/Contents.json"] = {"images": [{"filename": f"{name}.png", "idiom": "universal"}], **info}
    files["Brand.colorset/Contents.json"] = {"colors": [{"color": {"color-space": "srgb", "components": {
        "alpha": "1.000", "blue": "0.600", "green": "0.400", "red": "0.200"}}, "idiom": "universal"}], **info}
    for rel, obj in files.items():
        p = cat / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")
    (cat / "Logo.imageset" / "Logo.png").write_bytes(png(1, 1))
    (cat / "Banner.imageset" / "Banner.png").write_bytes(png(128, 64))


def main():
    prune = "--prune" in sys.argv[1:]
    unknown = [a for a in sys.argv[1:] if a != "--prune"]
    if unknown:
        sys.exit(f"gen: unknown argument(s) {' '.join(unknown)}; usage: gen.py [--prune]")
    build()
    keep = set(CASES) | set(HAND_MAINTAINED)
    stale = [p for p in sorted(CORPUS.glob("*.storyboard")) if p.stem not in keep]
    stale += [p for p in sorted((CORPUS / "golden").glob("*/")) if p.name not in keep]
    if stale and not prune:
        names = "\n  ".join(str(p.relative_to(CORPUS)) for p in stale)
        sys.exit(f"gen: not registered in gen.py (add the case, or pass --prune to delete):\n  {names}")
    for p in stale:
        shutil.rmtree(p) if p.is_dir() else p.unlink()
        print(f"gen: removed {p.relative_to(CORPUS)}")
    for name, text in CASES.items():
        (CORPUS / f"{name}.storyboard").write_text(text.replace(NEWLINE, "\n"), encoding="utf-8")
    write_catalog()
    cases = {**HAND_MAINTAINED, **FLAGS}
    out = {"flagsets": FLAGSETS, "default": ["universal-16"], "cases": dict(sorted(cases.items()))}
    lines = ["{", '  "flagsets": {']
    fs = list(FLAGSETS.items())
    for i, (k, v) in enumerate(fs):
        lines.append(f'    "{k}": ' + " " * (12 - len(k)) + json.dumps(v) + ("," if i < len(fs) - 1 else ""))
    lines += ["  },", '  "default": ["universal-16"],', '  "cases": {']
    cs = list(out["cases"].items())
    for i, (k, v) in enumerate(cs):
        lines.append(f'    "{k}": {json.dumps(v)}' + ("," if i < len(cs) - 1 else ""))
    lines += ["  }", "}"]
    (CORPUS / "flagsets.json").write_text("\n".join(lines) + "\n")
    assert json.loads((CORPUS / "flagsets.json").read_text()) == out
    print(f"gen: {len(CASES)} generated cases (+{len(HAND_MAINTAINED)} hand-maintained), {len(cases)} flag-set overrides")


if __name__ == "__main__":
    main()
