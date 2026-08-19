#!/usr/bin/env bash
# Regenerates the three diagram PNGs from agent-gateway-architecture.html.
# Requires: python3, Google Chrome. Run from this directory: ./render-diagrams.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$DIR/agent-gateway-architecture.html"
TMP="$(mktemp -d)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Figure order in the HTML (order of <figure> elements) -> output names
NAMES=("agent-gateway-architecture" "agent-gateway-egress-pipeline" "agent-gateway-ingress-pipeline")

python3 - "$HTML" "$TMP" <<'EOF'
import re, sys
html_path, tmp = sys.argv[1], sys.argv[2]
src = open(html_path).read()
style = re.search(r"<style>(.*?)</style>", src, re.S).group(1)
defs = re.search(r'(<svg width="0".*?</svg>)', src, re.S).group(1)
figs = re.findall(r"<figure>.*?(<svg viewBox.*?</svg>)", src, re.S)
sizes = []
for i, fig in enumerate(figs, 1):
    w, h = re.search(r'viewBox="0 0 (\d+) (\d+)"', fig).groups()
    sizes.append(f"{w}x{h}")
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{style}
html,body{{margin:0;padding:0;background:#ffffff}}
figure svg{{display:block;width:{w}px;height:{h}px;min-width:0;margin:0}}
</style></head><body>{defs}<figure style="margin:0">{fig}</figure></body></html>"""
    open(f"{tmp}/fig{i}.html", "w").write(page)
open(f"{tmp}/sizes.txt", "w").write("\n".join(sizes) + "\n")
print(f"extracted {len(figs)} figures")
EOF

i=1
while IFS= read -r size; do
  name="${NAMES[$((i-1))]:-figure-$i}"
  "$CHROME" --headless --disable-gpu --force-device-scale-factor=2 \
    --default-background-color=FFFFFFFF \
    --window-size="${size/x/,}" \
    --screenshot="$DIR/$name.png" \
    "file://$TMP/fig$i.html" 2>/dev/null
  echo "rendered $name.png ($size @2x)"
  i=$((i+1))
done < "$TMP/sizes.txt"

rm -rf "$TMP"
