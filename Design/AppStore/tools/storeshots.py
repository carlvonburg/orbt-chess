# storeshots.py <raw_dir> <out_dir> <device> [name ...]
# App Store screenshots as HTML, rendered by headless Chrome: a feature glow, a short headline,
# the real screen in a device frame, and one overlay per shot redrawn from that screen.
import json, os, subprocess, sys, tempfile

raw, out, device = sys.argv[1], sys.argv[2], sys.argv[3]
only = set(sys.argv[4:])
here = os.path.dirname(os.path.abspath(__file__))
spec = json.load(open(os.path.join(here, "shots.json")))[device]
os.makedirs(out, exist_ok=True)

W, H = {"iphone": (1320, 2868), "ipad": (2752, 2064)}[device]
RAW_W, RAW_H = {"iphone": (1320, 2868), "ipad": (2752, 2064)}[device]
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

COLORS = {"orange": "255,149,0", "blue": "0,122,255", "green": "52,199,89",
          "indigo": "120,110,230", "red": "255,59,48"}

# Layout: headline block, then the device scaled to fit with a bottom margin.
L = {"iphone": dict(head=128, sub=50, top=150, gap=70, bottom=120, bezel=26, radius=150, max_w=0.80),
     "ipad": dict(head=120, sub=52, top=110, gap=60, bottom=90, bezel=30, radius=64, max_w=0.80)}[device]

CSS = """
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: %(W)dpx; height: %(H)dpx; overflow: hidden; }
body { font-family: -apple-system, "SF Pro Display", "SF Pro Text", sans-serif; color: white;
  background: #100e24; position: relative; -webkit-font-smoothing: antialiased; }
.glow { position: absolute; inset: 0;
  background: radial-gradient(ellipse 70%% 45%% at 50%% 8%%, rgba(var(--c), .55), transparent 70%%),
              radial-gradient(ellipse 90%% 60%% at 50%% 100%%, rgba(70, 60, 160, .45), transparent 70%%),
              linear-gradient(180deg, #1d1940 0%%, #100e24 100%%); }
h1 { position: absolute; left: 0; right: 0; text-align: center; font-weight: 800;
  letter-spacing: .02em; text-transform: uppercase; line-height: 1.02; }
p.sub { position: absolute; left: 6%%; right: 6%%; text-align: center; font-weight: 500;
  color: rgba(255,255,255,.78); line-height: 1.25; }
.device { position: absolute; background: #08080c; box-shadow: 0 0 0 3px #3b3b48,
  0 60px 120px rgba(0,0,0,.55); }
.device img { position: absolute; display: block; }
.ov { position: absolute; }
.card { background: white; color: #111; border-radius: 34px;
  box-shadow: 0 30px 70px rgba(0,0,0,.45), 0 4px 14px rgba(0,0,0,.25); }
.tile { background-repeat: no-repeat; border-radius: 22px;
  box-shadow: 0 0 0 6px white, 0 30px 70px rgba(0,0,0,.5); }
.pill { display: inline-block; border-radius: 999px; font-weight: 700; color: white; }
"""

def render(shot, idx):
    head, sub = L["head"], L["sub"]
    y = L["top"]
    html = []
    lines = shot["title"].split("\n")
    html.append(f'<h1 style="top:{y}px;font-size:{head}px">{"<br>".join(lines)}</h1>')
    y += round(head * 1.02 * len(lines)) + 28
    subtitle = shot["subtitle"].replace("\n", " ") if device == "ipad" else shot["subtitle"]
    sublines = subtitle.split("\n")
    html.append(f'<p class="sub" style="top:{y}px;font-size:{sub}px">{"<br>".join(sublines)}</p>')
    y += round(sub * 1.25 * max(1 if device == "ipad" else 2, len(sublines))) + L["gap"]

    bezel = L["bezel"]
    avail_h = H - y - L["bottom"] - 2 * bezel
    sw = min(W * L["max_w"] - 2 * bezel, avail_h * RAW_W / RAW_H)
    s = sw / RAW_W
    sh = RAW_H * s
    fx = (W - sw - 2 * bezel) / 2
    fy = y
    r = L["radius"] * s / 0.72
    html.append(f'<div class="device" style="left:{fx}px;top:{fy}px;width:{sw + 2 * bezel}px;'
                f'height:{sh + 2 * bezel}px;border-radius:{r + bezel}px">'
                f'<img src="file://{os.path.join(raw, shot["file"])}" style="left:{bezel}px;top:{bezel}px;'
                f'width:{sw}px;height:{sh}px;border-radius:{r}px"></div>')
    sx, sy = fx + bezel, fy + bezel  # screen origin

    def at(x, y):  # raw screen pixel -> canvas
        return sx + x * s, sy + y * s

    env = dict(at=at, s=s, sx=sx, sy=sy, sw=sw, sh=sh, W=W, H=H, raw=os.path.join(raw, shot["file"]),
               RAW_W=RAW_W, RAW_H=RAW_H)
    for o in shot.get("overlays", []):
        html.append(OVERLAYS[o["kind"]](o, env))

    page = (f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS % {"W": W, "H": H}}</style>'
            f'</head><body style="--c:{COLORS[shot["color"]]}"><div class="glow"></div>{"".join(html)}</body></html>')
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, dir=here) as f:
        f.write(page)
        path = f.name
    png = os.path.join(out, f"{idx:02d}-{os.path.splitext(shot['file'])[0]}.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={W},{H}",
                    "--allow-file-access-from-files", f"--screenshot={png}", f"file://{path}"],
                   check=True, capture_output=True)
    os.unlink(path)
    print(png)


# Overlays. Each takes its spec and the layout; positions in raw screen pixels unless noted.

def tile(o, e):
    """A piece of the screen (a square, a symbol), lifted out and enlarged."""
    x0, y0, x1, y1 = o["box"]
    z = o.get("zoom", 1.8)
    w, h = (x1 - x0) * e["s"] * z, (y1 - y0) * e["s"] * z
    cx, cy = e["at"]((x0 + x1) / 2, (y0 + y1) / 2)
    cx += o.get("dx", 0)
    cy += o.get("dy", 0)
    bs = e["RAW_W"] * e["s"] * z
    bx, by = -x0 * e["s"] * z, -y0 * e["s"] * z
    badge = ""
    if o.get("check"):
        d = w * 0.42
        bx_c, by_c = o.get("check_at", [0.84, 0.16])
        badge = (f'<div style="position:absolute;left:{w * bx_c - d / 2}px;top:{h * by_c - d / 2}px;width:{d}px;height:{d}px;'
                 f'border-radius:50%;background:#34c759;box-shadow:0 0 0 6px white,0 10px 24px rgba(0,0,0,.35);'
                 f'display:flex;align-items:center;justify-content:center">'
                 f'<svg viewBox="0 0 24 24" width="{d * .6}" height="{d * .6}"><path d="M5 12.5l4.2 4.2L19 7" '
                 f'fill="none" stroke="white" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></svg></div>')
    return (f'<div class="ov tile" style="left:{cx - w / 2}px;top:{cy - h / 2}px;width:{w}px;height:{h}px;'
            f'background-image:url(file://{e["raw"]});background-size:{bs}px auto;'
            f'background-position:{bx}px {by}px">{badge}</div>')


def html_block(o, e):
    """A redrawn element: raw HTML at a canvas position (fractions of the canvas, or of the screen)."""
    if "screen" in o:
        fx, fy = o["screen"]
        x, y = e["sx"] + fx * e["sw"], e["sy"] + fy * e["sh"]
    else:
        x, y = o["canvas"][0] * e["W"], o["canvas"][1] * e["H"]
    anchor = o.get("anchor", "center")
    tx = {"left": "0", "center": "-50%", "right": "-100%"}[anchor]
    return (f'<div class="ov" style="left:{x}px;top:{y}px;transform:translate({tx},-50%);'
            f'{o.get("style", "")}">{o["html"].replace("{raw}", "file://" + e["raw"])}</div>')


OVERLAYS = {"tile": tile, "html": html_block}

for i, shot in enumerate(spec, 1):
    if not only or shot["file"] in only or str(i) in only:
        render(shot, i)
