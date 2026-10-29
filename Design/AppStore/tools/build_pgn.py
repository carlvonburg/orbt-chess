import chess, chess.pgn, sys, os
out=sys.argv[1]
prune={"Italian Game":["e4 d5 exd5 Nf6","e4 e5 Nf3 Nf6"],
       "Najdorf":["e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Bc4","e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Bd3"],
       "Queen's Gambit Declined":["d4 d5 c4 e6 Nc3 Nf6 Bf4","d4 d5 c4 e6 cxd5 exd5 Nf3"]}
for name,pr in prune.items():
    g=chess.pgn.Game()
    for k in ["Site","Date","Round"]: del g.headers[k]
    g.headers["Event"]=name; g.headers["White"]="?"; g.headers["Black"]="?"
    for line in open(f"{name}.400.lines"):
        line=line.strip()
        if any(line==p or line.startswith(p+" ") for p in pr): continue
        node=g
        for san in line.split():
            mv=node.board().parse_san(san)
            node=node.variation(mv) if node.has_variation(mv) else node.add_variation(mv)
    with open(os.path.join(out,name+".pgn"),"w") as f: print(g, file=f)
