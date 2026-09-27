# Single-file artifact: bundle src/main.js (sprites included), inline it into
# game2d.html. Two modes, one bundle source (T-125):
#   python3 tools/build.py          Playground: no network primitive at all
#   python3 tools/build.py --live   Live: only fetch and EventSource, written
#                                    to board/public/voyage2d/live.html
import re, subprocess, sys, os

LIVE = "--live" in sys.argv[1:]

sprites = open("bake/sprites.json").read()
open("src/bake-data.js", "w").write("export default " + sprites + ";\n")
subprocess.run(["bun", "build", "src/main.js", "--format", "esm", "--minify", "--outfile", "build/v2d.bundle.js"], check=True)
js = open("build/v2d.bundle.js").read().replace("</script", "<\\/script")
html = open("game2d.html").read()
head = html.split("<head>", 1)[1].split("</head>", 1)[0]
body = html.split("<body>", 1)[1].split("</body>", 1)[0]
head = re.sub(r"<meta name=.viewport.[^>]*>\s*", "", head)

if LIVE:
    # T-125, bundle and hygiene: the board already loads no font of its own
    # (index.html and ship.css use the system stack only), so the Live build
    # drops the Google Fonts links rather than adding a third-party origin -
    # every font-family in the game already falls back to system-ui/sans-serif.
    head = re.sub(r"<link rel=.preconnect.[^>]*>\s*", "", head)
    head = re.sub(r"<link rel=.stylesheet. href=.https://fonts[^>]*>\s*", "", head)
    assert "fonts.googleapis.com" not in head and "fonts.gstatic.com" not in head, "a third-party font origin is left in the Live build"

marker = "<script type=" + chr(34) + "module" + chr(34) + " src=" + chr(34) + "./src/main.js" + chr(34) + "></script>"
body = body.replace(marker, "<script type=" + chr(34) + "module" + chr(34) + ">\n" + js + "\n</script>")
assert "./src/" not in body, "a local reference is left"

if LIVE:
    # docs/interface.md section 0: the Live build is the only one that may
    # ever reach the board, and only through fetch and EventSource - nothing
    # else that leaves the page.
    for bad in ["XMLHttpRequest", "WebSocket", "sendBeacon", "importScripts"]:
        assert bad not in js, "unexpected network primitive in the Live bundle: " + bad
    for need in ["fetch(", "EventSource"]:
        assert need in js, "the Live bundle does not reach the board: missing " + need
else:
    for bad in ["fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "importScripts"]:
        assert bad not in js, "network call in bundle: " + bad

out = head.strip() + "\n" + body.strip() + "\n"
if LIVE:
    dest_dir = os.path.join("..", "..", "board", "public", "voyage2d")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "live.html")
    open(dest, "w").write(out)
    print(len(out.encode()), "bytes (live) ->", dest)
else:
    open("artifact-2d.html", "w").write(out)
    hosts = sorted(set(re.findall(r"https?://([a-zA-Z0-9.-]+)", out)))
    print(len(out.encode()), "bytes; hosts:", hosts)
