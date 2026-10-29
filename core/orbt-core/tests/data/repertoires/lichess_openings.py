#!/usr/bin/env python3
"""Writes lichess_openings.pgn: every line of lichess's opening names (github.com/lichess-org/
chess-openings, CC0-1.0) as one game, each name a comment on its line's last move.

Usage: lichess_openings.py a.tsv b.tsv c.tsv d.tsv e.tsv > lichess_openings.pgn
"""

import re
import sys


def main(paths):
    root = {}  # san -> [children, names]
    for path in paths:
        with open(path, encoding="utf-8") as f:
            next(f)
            for row in f:
                eco, name, pgn = row.rstrip("\n").split("\t")
                node = None
                children = root
                for san in re.sub(r"\d+\.+", " ", pgn).split():
                    node = children.setdefault(san, [{}, []])
                    children = node[0]
                node[1].append(f"{eco} {name}")

    out = []

    def move(san, node, ply, numbered):
        if ply % 2 == 0:
            out.append(f"{ply // 2 + 1}. {san}")
        elif numbered:
            out.append(f"{ply // 2 + 1}... {san}")
        else:
            out.append(san)
        if node[1]:
            out.append("{" + "; ".join(node[1]) + "}")
        return bool(node[1])

    def line(children, ply, numbered):
        if not children:
            return
        items = list(children.items())
        san, node = items[0]
        commented = move(san, node, ply, numbered)
        for alt_san, alt in items[1:]:
            out.append("(")
            line(alt[0], ply + 1, move(alt_san, alt, ply, True))
            out.append(")")
        line(node[0], ply + 1, commented or len(items) > 1)

    line(root, 0, False)
    text = " ".join(out).replace("( ", "(").replace(" )", ")")
    print('[Event "Lichess opening names"]')
    print('[Site "https://github.com/lichess-org/chess-openings"]')
    print('[Annotator "lichess-org/chess-openings, CC0-1.0"]')
    print('[Result "*"]')
    print()
    # Wrap at 80 columns, as PGN export does.
    width = 0
    words = []
    for word in (text + " *").split(" "):
        if width + len(word) + (1 if words and width else 0) > 79:
            print(" ".join(words))
            words, width = [], 0
        width += len(word) + (1 if words else 0)
        words.append(word)
    print(" ".join(words))


if __name__ == "__main__":
    main(sys.argv[1:])
