# Single-file artifact: bundle src/main.js (sprites included), inline it into game2d.html.
import re, subprocess, json
subprocess.run(["python3", "-c", "d=open('bake/sprites.json').read();open('src/bake-data.js','w').write('export default '+d+';\\n')"], check=True)
subprocess.run(["bun", "build", "src/main.js", "--format", "esm", "--minify", "--outfile", "build/v2d.bundle.js"], check=True)
js = open("build/v2d.bundle.js").read().replace("</script", "<\\/script")
html = open("game2d.html").read()
head = html.split("<head>", 1)[1].split("</head>", 1)[0]
body = html.split("<body>", 1)[1].split("</body>", 1)[0]
head = re.sub(r'<meta name="viewport"[^>]*>\s*', "", head)

body = body.replace('<script type="module" src="./src/main.js"></script>', '<script type="module">\n' + js + "\n</script>")
assert "./src/" not in body, "a local reference is left"
for bad in ["fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "importScripts"]:
    assert bad not in js, "network call in bundle: " + bad
out = head.strip() + "\n" + body.strip() + "\n"
open("artifact-2d.html", "w").write(out)
hosts = sorted(set(re.findall(r"https?://([a-zA-Z0-9.-]+)", out)))
print(len(out.encode()), "bytes; hosts:", hosts)
