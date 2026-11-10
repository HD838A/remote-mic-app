#!/usr/bin/env python3
"""Render the public asset contract for packaging, verification and CDN preflight."""
import json
from pathlib import Path
import re
import sys

CONTRACT = Path(__file__).resolve().parent.parent / "config/release-assets.json"


def main():
    contract = json.loads(CONTRACT.read_text())
    if len(sys.argv) == 3 and sys.argv[1] == "check-capability":
        deployed = json.loads(Path(sys.argv[2]).read_text())
        if deployed != contract:
            sys.exit("CDN asset contract differs from release control plane; deploy the matching contract before staging")
        print("CDN ASSET CONTRACT PASS")
        return
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in ("names", "copies"):
        sys.exit("usage: release-assets.py names|copies <version> <build> [manifest-schema] | check-capability <json>")
    mode, version, build = sys.argv[1:4]
    schema = sys.argv[4] if len(sys.argv) == 5 else str(contract["currentManifestSchema"])
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        sys.exit("invalid asset version/build")
    if schema not in contract["manifests"]:
        sys.exit("unsupported asset manifest schema")
    assets = contract["manifests"][schema]
    names = [asset["name"].format(version=version, build=build) for asset in assets]
    if len(names) != len(set(names)) or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) for name in names):
        sys.exit("invalid or duplicate asset contract names")
    for asset, name in zip(assets, names):
        if mode == "copies":
            print(asset["source"].format(version=version, build=build) + "\t" + name)
        else:
            print(name)


if __name__ == "__main__":
    main()
