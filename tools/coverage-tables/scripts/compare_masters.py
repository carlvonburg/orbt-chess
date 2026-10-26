"""Compares OTB tables (summed) with the Lichess masters explorer on a few positions.
Usage: compare_masters.py <dump binary> <table>... (token from ~/.config/orbt/lichess_token)"""
import json, os, subprocess, sys, time, urllib.parse, urllib.request

LINES = ["", "e2e4", "d2d4", "c2c4", "g1f3", "e2e4 c7c5", "e2e4 e7e5", "e2e4 e7e5 g1f3", "e2e4 e7e5 g1f3 b8c6",
         "e2e4 e7e5 g1f3 b8c6 f1b5", "e2e4 c7c5 g1f3", "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3",
         "e2e4 e7e6 d2d4", "e2e4 c7c6 d2d4", "d2d4 g8f6 c2c4", "d2d4 g8f6 c2c4 e7e6", "d2d4 d7d5 c2c4",
         "d2d4 g8f6 c2c4 g7g6", "c2c4 e7e5", "g1f3 d7d5"]
token = open(os.path.expanduser("~/.config/orbt/lichess_token")).read().strip()
dump, tables = sys.argv[1], sys.argv[2:]
ours = {}
for l in subprocess.run([dump, *tables, "--", *LINES], capture_output=True, text=True, check=True).stdout.splitlines():
    d = json.loads(l); ours[d["line"]] = d["moves"]

def masters(line):
    q = urllib.parse.urlencode({"play": ",".join(line.split()), "topGames": 0, "moves": 30})
    req = urllib.request.Request(f"https://explorer.lichess.org/masters?{q}", headers={"Authorization": f"Bearer {token}"})
    for _ in range(3):
        try: return json.load(urllib.request.urlopen(req))
        except urllib.error.HTTPError as e:
            if e.code != 429: raise
            time.sleep(60)

def norm(u):  # Lichess may give castling as e1h1
    return {"e1h1": "e1g1", "e1a1": "e1c1", "e8h8": "e8g8", "e8a8": "e8c8"}.get(u, u)

worst = 0
for line in LINES:
    m = masters(line); time.sleep(3.5)
    lm = {norm(x["uci"]): x["white"] + x["draws"] + x["black"] for x in m["moves"]}
    om = ours.get(line, {})
    lt, ot = sum(lm.values()), sum(om.values())
    print(f"\n{line or 'start'}: lichess masters {lt:,} games, OTB 2200+ {ot:,} games ({ot / lt:.2f}x)")
    for u in sorted(lm, key=lm.get, reverse=True)[:5]:
        ls, os_ = 100 * lm[u] / lt, 100 * om.get(u, 0) / ot if ot else 0
        worst = max(worst, abs(ls - os_))
        print(f"   {u:<6} lichess {ls:5.1f}%   otb {os_:5.1f}%   diff {os_ - ls:+5.1f}")
print(f"\nlargest share difference among top-5 moves: {worst:.1f} points")
