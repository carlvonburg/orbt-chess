#!/usr/bin/env python3
"""Writes the app's Acknowledgements.json: every crate linked into the app with its license text.

Usage: acknowledgements.py [--android] [--check]
Run by build-apple.sh (the Apple app) and, with --android, by build-android.sh (the Android and
desktop app). Lists the crates `orbt-ffi` links on the platform's targets (normal dependencies, no
proc macros or build scripts) with the license file each one ships. Shared texts: the repo's
LICENSE (AGPL-3.0), Stockfish's GPL-3.0 and scripts/licenses/ (MPL-2.0, CC BY-NC 4.0,
Apache-2.0); a crate that ships no license file names one of them (`shared`). --android also
lists the Kotlin and Java libraries the app ships (`libraries`, versions read from the Gradle
build files), each naming its shared text. --check exits 1 when the file is out of date instead
of writing it.
"""
import json, os, re, subprocess, sys

CORE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(CORE)
ANDROID = "--android" in sys.argv
if ANDROID:
    OUT = os.path.join(REPO, "android/app/src/commonMain/composeResources/files/Acknowledgements.json")
    # The phone's ABIs and the desktop app's systems (packaged for Windows and Linux; run on macOS).
    TARGETS = ["aarch64-linux-android", "x86_64-linux-android", "x86_64-pc-windows-msvc",
               "x86_64-unknown-linux-gnu", "aarch64-apple-darwin"]
else:
    OUT = os.path.join(REPO, "apple/ORBT/UI/Settings/Acknowledgements.json")
    TARGETS = ["aarch64-apple-ios", "aarch64-apple-darwin"]
# For "A OR B", the license whose text we show, first match wins.
PREFERRED = ["MIT", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Zlib", "Apache-2.0", "MPL-2.0", "Unlicense"]
SHARED = {"AGPL-3.0": "LICENSE", "GPL-3.0": "core/orbt-engine/vendor/stockfish/Copying.txt",
          "MPL-2.0": "core/scripts/licenses/MPL-2.0.txt",
          # Lumbra's Gigabase, the source of the Classical coverage tables (not a crate).
          "CC-BY-NC-4.0": "core/scripts/licenses/CC-BY-NC-4.0.txt"}
if ANDROID:
    SHARED["Apache-2.0"] = "core/scripts/licenses/Apache-2.0.txt"

# The Kotlin and Java libraries the Android and desktop app ships: name, the Maven coordinate
# (group:artifact) whose version the Gradle files give, license, the text shown, repository.
GRADLE_FILES = ["android/build.gradle.kts", "android/app/build.gradle.kts", "android/androidApp/build.gradle.kts",
                "android/core/build.gradle.kts"]
LIBRARIES = [
    ("Kotlin standard library", "kotlin-multiplatform", "Apache-2.0", "Apache-2.0", "https://github.com/JetBrains/kotlin"),
    ("Compose Multiplatform", "org.jetbrains.compose", "Apache-2.0", "Apache-2.0", "https://github.com/JetBrains/compose-multiplatform"),
    ("Compose Material 3", "org.jetbrains.compose.material3:material3", "Apache-2.0", "Apache-2.0", "https://github.com/JetBrains/compose-multiplatform"),
    ("Compose Material 3 Adaptive", "org.jetbrains.compose.material3.adaptive:adaptive", "Apache-2.0", "Apache-2.0", "https://github.com/JetBrains/compose-multiplatform"),
    ("AndroidX Activity", "androidx.activity:activity-compose", "Apache-2.0", "Apache-2.0", "https://developer.android.com/jetpack/androidx/releases/activity"),
    ("AndroidX Browser", "androidx.browser:browser", "Apache-2.0", "Apache-2.0", "https://developer.android.com/jetpack/androidx/releases/browser"),
    ("AndroidX Lifecycle", "org.jetbrains.androidx.lifecycle:lifecycle-viewmodel-compose", "Apache-2.0", "Apache-2.0", "https://developer.android.com/jetpack/androidx/releases/lifecycle"),
    ("AndroidX SQLite", "androidx.sqlite:sqlite-bundled", "Apache-2.0", "Apache-2.0", "https://developer.android.com/jetpack/androidx/releases/sqlite"),
    ("kotlinx.coroutines", "org.jetbrains.kotlinx:kotlinx-coroutines-core", "Apache-2.0", "Apache-2.0", "https://github.com/Kotlin/kotlinx.coroutines"),
    ("OkHttp", "com.squareup.okhttp3:okhttp", "Apache-2.0", "Apache-2.0", "https://github.com/square/okhttp"),
    # OkHttp's I/O library, which it brings (OkHttp 4.12's).
    ("Okio", None, "Apache-2.0", "Apache-2.0", "https://github.com/square/okio"),
    ("JNA", "net.java.dev.jna:jna", "LGPL-2.1-or-later OR Apache-2.0", "Apache-2.0", "https://github.com/java-native-access/jna"),
    ("material-kolor", "com.materialkolor:material-kolor", "MIT", None, "https://github.com/jordond/MaterialKolor"),
    # The board's pieces, from lichess (GPL-2.0-or-later, so GPL-3.0's text applies).
    ("cburnett pieces", None, "GPL-2.0-or-later", "GPL-3.0", "https://github.com/lichess-org/lila"),
]
# Versions no Gradle file states.
FIXED_VERSIONS = {"Okio": "3.6.0", "cburnett pieces": ""}
MATERIAL_KOLOR_LICENSE = """MIT License

Copyright (c) 2026 Jordon de Hoog

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def libraries():
    gradle = "\n".join(open(os.path.join(REPO, f), encoding="utf-8").read() for f in GRADLE_FILES)
    result = []
    for name, coordinate, spdx, shared, repository in LIBRARIES:
        if name in FIXED_VERSIONS:
            version = FIXED_VERSIONS[name]
        elif coordinate == "kotlin-multiplatform":
            version = re.search(r'kotlin\("multiplatform"\) version "([^"]+)"', gradle).group(1)
        elif ":" not in coordinate:
            version = re.search(r'id\("%s"\) version "([^"]+)"' % re.escape(coordinate), gradle).group(1)
        else:
            match = re.search(r'"%s:([^"@]+)' % re.escape(coordinate), gradle)
            if not match:
                sys.exit(f"no version of {coordinate} in {', '.join(GRADLE_FILES)}")
            version = match.group(1)
        library = {"name": name, "version": version, "license": spdx, "repository": repository}
        if shared:
            library["shared"] = shared
        else:
            library["text"] = MATERIAL_KOLOR_LICENSE
        result.append(library)
    return result


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
    if ANDROID:
        result["libraries"] = libraries()
    data = json.dumps(result, indent=1, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        command = "core/scripts/acknowledgements.py" + (" --android" if ANDROID else "")
        sys.exit(0 if current == data else f"{OUT} is out of date: run {command}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(data)
    print(f"wrote {len(crates)} crates to {OUT}")


if __name__ == "__main__":
    main()
