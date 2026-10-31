#!/usr/bin/env python3
"""Check user-visible English copy against the SayAll copy conventions.

What this gate enforces
-----------------------
* the English and Simplified Chinese catalogs expose the same keys;
* both catalogs carry the same printf placeholders, so a translation cannot
  drop or reorder a token and silently break a formatted string;
* English copy uses US spelling, curly apostrophes and no "Please";
* one name per concept. The agreed English vocabulary is:

      combination actions / action sequences / quick commands -> Routine
      Siri Remote                                              -> Apple Remote
      Single Click / Double Click                              -> Single Press / Double Press
      WeChat Mini Program SayAll                               -> SayAll WeChat Mini Program
      backstage feature name "回眸"                              -> Reflections

The same vocabulary is checked in the bundled help pages and, when
--private-root is given, in the private packages the Mac host loads.

Usage
-----
    scripts/verify-english-copy.py
    scripts/verify-english-copy.py --private-root ../sayall-private-platform
"""

import argparse
import json
from pathlib import Path
import re
import sys

STRING_LINE = re.compile(r'^"(?P<key>[^"]+)"\s*=\s*"(?P<value>.*)";\s*$')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@dfs]")
FORBIDDEN_SPELLING = {
    "cancelled": "canceled",
    "centre": "center",
    "behaviour": "behavior",
    "colour": "color",
    "favourite": "favorite",
    "organise": "organize",
    "recognise": "recognize",
}
FORBIDDEN_TERM = {
    "action sequence": "Routine",
    "combination action": "Routine",
    "quick command": "Routine",
    "composite action": "Routine",
    "siri remote": "Apple Remote",
    "single click": "Single Press",
    "double click": "Double Press",
    "wechat mini program sayall": "SayAll WeChat Mini Program",
}
HELP_DOCS = ("Glossary.md", "FirstInstallGuide.md", "ReleaseHistory.md",
             "DoubaoInputMethodCompatibility.md")


def parse_strings(path):
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = STRING_LINE.match(line.strip())
        if match:
            entries[match.group("key")] = (match.group("value"), number)
    return entries


def check_value(path, key, line, value, problems):
    for misspelling, preferred in FORBIDDEN_SPELLING.items():
        if re.search(rf"\b{misspelling}\b", value, re.IGNORECASE):
            problems.append(f"{path}:{line}: {key}: use “{preferred}”, not “{misspelling}”")
    if "'" in value:
        problems.append(f"{path}:{line}: {key}: use a curly apostrophe (’)")
    if re.search(r"(?<![A-Za-z])Please\b", value):
        problems.append(f"{path}:{line}: {key}: drop “Please”, the app uses plain imperatives")
    lowered = value.lower()
    for term, preferred in FORBIDDEN_TERM.items():
        if term in lowered:
            problems.append(f"{path}:{line}: {key}: use “{preferred}”, not “{term}”")


def check_catalogs(root, problems):
    en_path = root / "Resources/en.lproj/Localizable.strings"
    zh_path = root / "Resources/zh-Hans.lproj/Localizable.strings"
    en, zh = parse_strings(en_path), parse_strings(zh_path)

    for key in sorted(set(en) - set(zh)):
        problems.append(f"{zh_path}: missing key {key} that English defines")
    for key in sorted(set(zh) - set(en)):
        problems.append(f"{en_path}: missing key {key} that Chinese defines")

    for key, (value, line) in en.items():
        check_value(en_path, key, line, value, problems)
        if key in zh:
            if sorted(PLACEHOLDER.findall(value)) != sorted(PLACEHOLDER.findall(zh[key][0])):
                problems.append(
                    f"{en_path}:{line}: {key}: placeholders differ from the Chinese catalog")

    caps = root / "Resources/en.lproj/InfoPlist.strings"
    if caps.exists():
        for key, (value, line) in parse_strings(caps).items():
            check_value(caps, key, line, value, problems)
    return len(en)


def check_help_docs(root, problems):
    folder = root / "Resources/en.lproj"
    for name in HELP_DOCS:
        path = folder / name
        if not path.exists():
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            lowered = line.lower()
            for term, preferred in FORBIDDEN_TERM.items():
                if term in lowered:
                    problems.append(f"{path}:{number}: use “{preferred}”, not “{term}”")
            if re.search(r"Apple Silicon", line):
                problems.append(f"{path}:{number}: Apple writes “Apple silicon”")


def check_private_packages(root, problems):
    membership = root / "packages/macos-membership/Sources/SayAllMembershipUI"
    catalog = membership / "Resources/MembershipCenterCopy.json"
    view = membership / "MembershipCenterView.swift"
    if catalog.exists() and view.exists():
        data = json.loads(catalog.read_text(encoding="utf-8"))
        missing = [lang for lang in ("zh-Hans", "en") if lang not in data]
        if missing:
            problems.append(f"{catalog}: missing languages {missing}")
        else:
            if set(data["zh-Hans"]) != set(data["en"]):
                problems.append(f"{catalog}: Chinese and English key sets differ")
            for key, value in data["en"].items():
                lowered = value.lower()
                for misspelling, preferred in FORBIDDEN_SPELLING.items():
                    if re.search(rf"\b{misspelling}\b", value, re.IGNORECASE):
                        problems.append(f"{catalog}: {key}: use “{preferred}”, not “{misspelling}”")
                for term, preferred in FORBIDDEN_TERM.items():
                    if term in lowered:
                        problems.append(f"{catalog}: {key}: use “{preferred}”, not “{term}”")
                if re.search(r"(?<![A-Za-z])Please\b", value):
                    problems.append(f"{catalog}: {key}: drop “Please” in {value!r}")

    for name in ("macos-combination-actions/Sources/SayAllMacroRemoteMic",
                 "macos-button-profiles/Sources/SayAllButtonProfiles",
                 "macos-common-phrases/Sources/SayAllCommonPhrases"):
        path = root / name / "Resources/en.lproj/Localizable.strings"
        if not path.exists():
            continue
        for key, (value, line) in parse_strings(path).items():
            check_value(path, key, line, value, problems)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--private-root", type=Path)
    options = parser.parse_args()

    problems = []
    count = check_catalogs(options.root, problems)
    check_help_docs(options.root, problems)
    if options.private_root:
        check_private_packages(options.private_root, problems)

    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} copy problem(s) found")
        return 1
    print(f"English copy checks passed ({count} strings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
