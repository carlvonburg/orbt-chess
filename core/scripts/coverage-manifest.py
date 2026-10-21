#!/usr/bin/env python3
"""Writes manifest.json for folders of coverage tables (*.otcb.zst), for the app's downloads.

Usage: coverage-manifest.py <folder> [<folder>...]
Writes <first folder>/manifest.json listing the tables of every folder; upload it and all the
tables to one place (file names are relative to the manifest).
Needs the zstd command. Each entry's database comes from the table's own header, so file names
can change without breaking the app.
"""
import hashlib, json, os, struct, subprocess, sys

ELO_BINS = [0, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500]


def header(path):
    head = subprocess.run(["zstd", "-dc", path], capture_output=True).stdout[:300]
    if head[:4] != b"OTCB" or head[4] != 2:
        sys.exit(f"{path}: not an OTCB version 2 table")
    n = struct.unpack("<I", head[8:12])[0]
    name = head[17:17 + head[16]].decode()
    source, bins = name.split("_")
    low, high = (int(x) for x in bins.split("-"))
    ratings = [b for b in ELO_BINS if low <= b <= high]
    if source == "otb":
        return n, {"otb": {"ratings": ratings}}
    return n, {"lichess": {"ratings": ratings, "speeds": [source]}}


def main():
    folders = sys.argv[1:]
    files = []
    for folder, name in sorted((f, n) for f in folders for n in os.listdir(f)):
        if not name.endswith(".otcb.zst"):
            continue
        path = os.path.join(folder, name)
        data = open(path, "rb").read()
        n, database = header(path)
        files.append({"file": name, "database": database, "targetGames": n,
                      "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    out = os.path.join(folders[0], "manifest.json")
    json.dump({"version": 1, "files": files}, open(out, "w"), indent=1)
    print(f"{out}: {len(files)} tables")


if __name__ == "__main__":
    main()
