#!/usr/bin/env python3
"""Writes the app's Acknowledgements.json: every crate linked into the app with its license text.

Usage: acknowledgements.py [--check]
Run by build-apple.sh. Lists the crates `orbt-ffi` links on the Apple targets (normal
dependencies, no proc macros or build scripts) with the license file each one ships. Shared
texts: the repo's LICENSE (AGPL-3.0), Stockfish's GPL-3.0 and scripts/licenses/ (MPL-2.0,
CC BY-NC 4.0); a crate that ships no license file names one of them (`shared`). --check exits 1 when the file
is out of date instead of writing it.
"""
import json, os, re, subprocess, sys

CORE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(CORE)
OUT = os.path.join(REPO, "apple/ORBT/UI/Settings/Acknowledgements.json")
TARGETS = ["aarch64-apple-ios", "aarch64-apple-darwin"]
# For "A OR B", the license whose text we show, first match wins.
PREFERRED = ["MIT", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Zlib", "Apache-2.0", "MPL-2.0", "Unlicense"]
SHARED = {"AGPL-3.0": "LICENSE", "GPL-3.0": "core/orbt-engine/vendor/stockfish/Copying.txt",
          "MPL-2.0": "core/scripts/licenses/MPL-2.0.txt",
          # Lumbra's Gigabase, the source of the Classical coverage tables (not a crate).
          "CC-BY-NC-4.0": "core/scripts/licenses/CC-BY-NC-4.0.txt"}


def cargo(*args):
    return subprocess.run(["cargo", *args], cwd=CORE, check=True, capture_output=True, text=True).stdout


def linked_packages():
    ids = set()
    for target in TARGETS:
        tree = cargo("tree", "-p", "orbt-ffi", "-e", "normal,no-proc-macro", "--target", target,
                     "--prefix", "none", "--format", "{p}", "--locked")
        for line in tree.splitlines():
            name, version = line.split()[:2]
            ids.add((name, version.lstrip("v")))
    return ids


def license_files(folder):
    names = [n for n in os.listdir(folder)
             if re.match(r"(?i)^(licen[sc]e|copying|unlicense|(mit|apache-2\.0|mpl-2\.0)\.(txt|md)$)", n)]
    return {n: os.path.join(folder, n) for n in sorted(names)}


def license_text(package):
    files = license_files(os.path.dirname(package["manifest_path"]))
    expression = package.get("license") or ""
    for spdx in PREFERRED:
        if spdx in expression:
            key = {"Apache-2.0": "APACHE", "MPL-2.0": "MPL", "BSD-3-Clause": "BSD", "BSD-2-Clause": "BSD"}.get(spdx, spdx)
            match = [p for n, p in files.items() if key.upper() in n.upper()]
            if match:
                return open(match[0], encoding="utf-8").read().strip()
    if len(files) == 1:
        return open(next(iter(files.values())), encoding="utf-8").read().strip()
    if files:
        return "\n\n".join(open(p, encoding="utf-8").read().strip() for p in files.values())
    return None


def main():
    metadata = json.loads(cargo("metadata", "--format-version", "1", "--locked"))
    workspace = set(metadata["workspace_members"])
    linked = linked_packages()
    crates, missing = [], []
    for package in metadata["packages"]:
        if package["id"] in workspace or (package["name"], package["version"]) not in linked:
            continue
        expression = package.get("license") or ""
        crate = {"name": package["name"], "version": package["version"], "license": expression,
                 "repository": package.get("repository") or ""}
        text = license_text(package)
        shared = next((key for key in SHARED if key in expression), None)
        if text is not None:
            crate["text"] = text
        elif shared:
            crate["shared"] = shared
        else:
            missing.append(package["name"])
        crates.append(crate)
    if missing:
        sys.exit(f"no license text for: {', '.join(sorted(missing))}")
    crates.sort(key=lambda c: (c["name"], c["version"]))
    read = lambda path: open(os.path.join(REPO, path), encoding="utf-8").read().strip()
    result = {"licenses": {key: read(path) for key, path in SHARED.items()}, "crates": crates}
    data = json.dumps(result, indent=1, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        sys.exit(0 if current == data else f"{OUT} is out of date: run core/scripts/acknowledgements.py")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(data)
    print(f"wrote {len(crates)} crates to {OUT}")


if __name__ == "__main__":
    main()
