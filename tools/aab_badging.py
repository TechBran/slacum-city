#!/usr/bin/env python3
"""Badging for an Android App Bundle — the thing `aapt2` will not do.

    python3 tools/aab_badging.py build/slacum-release.aab
    python3 tools/aab_badging.py build/slacum-release.aab --permissions

Doc 13 §2.10 tells you to run `aapt2 dump permissions` on the release AAB. It
does not work, on any build-tools version present on this machine:

    build/slacum-release.aab: error: could not identify format of APK.

…and the reason is structural rather than a missing flag. Every `aapt2 dump`
subcommand wants a *binary* Android manifest inside an APK; an AAB carries
`base/manifest/AndroidManifest.xml` in aapt2's **protobuf** encoding instead.
Google's own answer is `bundletool`, a 60 MB jar that is not in the SDK and that
this project has no other use for.

So this script reads the protobuf directly. It is a generic wire-format walker
plus the four field numbers from aapt2's `Resources.proto` that describe an XML
node — no protobuf library, no schema compilation, no dependency:

    XmlNode      { XmlElement element = 1; string text = 2 }
    XmlElement   { XmlNamespace ns = 1; string namespace_uri = 2; string name = 3;
                   XmlAttribute attribute = 4; XmlNode child = 5 }
    XmlAttribute { string namespace_uri = 1; string name = 2; string value = 3 }

Compiled attribute values (field 6) are ignored on purpose: aapt2 writes the
human-readable form into field 3 as well, which is what `versionCode='400'`
above is, and the compiled copy would only be a second source for the same fact.

Exit code is 0 when the bundle parsed. With `--expect-permissions a,b,c` it is 1
when the permission set differs, which is what makes it usable as a build gate:
doc 13 §2.7 fixes the release manifest at four permissions, and INTERNET
appearing in it would silently change the Play Data Safety declaration from
"collects nothing" to something that needs a form and a privacy review.
"""

from __future__ import annotations

import argparse
import sys
import zipfile

MANIFEST_PATH = "base/manifest/AndroidManifest.xml"

# Resources.proto field numbers, and nothing else about protobuf is assumed.
NODE_ELEMENT = 1
ELEMENT_NAME = 3
ELEMENT_ATTRIBUTE = 4
ELEMENT_CHILD = 5
ATTRIBUTE_NAME = 2
ATTRIBUTE_VALUE = 3

WIRE_VARINT = 0
WIRE_64 = 1
WIRE_LEN = 2
WIRE_32 = 5


def read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def fields(buf: bytes) -> dict[int, list]:
    """Every field in one message, as {field_number: [payload, ...]}."""
    out: dict[int, list] = {}
    pos = 0
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        number, wire = key >> 3, key & 0x07
        if wire == WIRE_VARINT:
            value, pos = read_varint(buf, pos)
        elif wire == WIRE_64:
            value, pos = buf[pos:pos + 8], pos + 8
        elif wire == WIRE_LEN:
            length, pos = read_varint(buf, pos)
            value, pos = buf[pos:pos + length], pos + length
        elif wire == WIRE_32:
            value, pos = buf[pos:pos + 4], pos + 4
        else:
            raise ValueError("unsupported wire type %d" % wire)
        out.setdefault(number, []).append(value)
    return out


def text(raw: bytes) -> str:
    return raw.decode("utf-8", "replace")


class Element:
    """One XML element: its name, its attributes and its children."""

    def __init__(self, raw: bytes) -> None:
        f = fields(raw)
        self.name = text(f.get(ELEMENT_NAME, [b""])[0])
        self.attributes: dict[str, str] = {}
        for attr in f.get(ELEMENT_ATTRIBUTE, []):
            af = fields(attr)
            name = text(af.get(ATTRIBUTE_NAME, [b""])[0])
            value = text(af.get(ATTRIBUTE_VALUE, [b""])[0])
            if name:
                self.attributes[name] = value
        self.children: list[Element] = []
        for child in f.get(ELEMENT_CHILD, []):
            element = fields(child).get(NODE_ELEMENT)
            if element:
                self.children.append(Element(element[0]))

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()


def parse_manifest(aab_path: str) -> Element:
    with zipfile.ZipFile(aab_path) as bundle:
        if MANIFEST_PATH not in bundle.namelist():
            raise SystemExit("%s: no %s — not an app bundle" % (aab_path, MANIFEST_PATH))
        raw = bundle.read(MANIFEST_PATH)
    element = fields(raw).get(NODE_ELEMENT)
    if not element:
        raise SystemExit("%s: manifest has no root element" % aab_path)
    return Element(element[0])


def permissions(root: Element) -> list[str]:
    found = {node.attributes.get("name", "")
             for node in root.walk() if node.name == "uses-permission"}
    return sorted(p for p in found if p)


def badging(aab_path: str, root: Element) -> list[str]:
    attrs = root.attributes
    lines = [
        "package: name='%s' versionCode='%s' versionName='%s' compileSdkVersion='%s'" % (
            attrs.get("package", "?"), attrs.get("versionCode", "?"),
            attrs.get("versionName", "?"), attrs.get("compileSdkVersion", "?")),
    ]
    for node in root.walk():
        if node.name == "uses-sdk":
            lines.append("minSdkVersion:'%s'" % node.attributes.get("minSdkVersion", "?"))
            lines.append("targetSdkVersion:'%s'"
                         % node.attributes.get("targetSdkVersion", "?"))
    for name in permissions(root):
        lines.append("uses-permission: name='%s'" % name)
    with zipfile.ZipFile(aab_path) as bundle:
        libs = sorted(n for n in bundle.namelist() if n.endswith(".so"))
        abis = sorted({n.split("/")[2] for n in libs if n.count("/") > 2})
        lines.append("native-code: %s" % " ".join("'%s'" % abi for abi in abis))
        lines.append("modules: %s" % " ".join(sorted(
            {n.split("/")[0] for n in bundle.namelist() if "/" in n})))
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aab")
    parser.add_argument("--permissions", action="store_true",
                        help="print only the permission list, one per line")
    parser.add_argument("--expect-permissions", default="",
                        help="comma-separated; exit 1 if the set differs")
    args = parser.parse_args()

    root = parse_manifest(args.aab)
    if args.permissions:
        for name in permissions(root):
            print(name)
    else:
        for line in badging(args.aab, root):
            print(line)

    if args.expect_permissions:
        expected = sorted(p for p in args.expect_permissions.split(",") if p)
        found = permissions(root)
        if found != expected:
            print("error: permission set mismatch", file=sys.stderr)
            print("  found:    %s" % " ".join(found), file=sys.stderr)
            print("  expected: %s" % " ".join(expected), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
