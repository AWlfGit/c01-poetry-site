"""Engineering Bible Rule 1 probe for the generated site (acceptance-gate item 7).

Loads every HTML page in _site at a matrix of viewports (phone portrait/landscape, tablet both
ways, desktop) and two root font scales (100% and 200%, standing in for OS font scaling since
every dimension in style.css is rem-based) and asserts:

  * documentElement.scrollWidth <= clientWidth   (no horizontal overflow of the document)
  * no element's bounding box right edge exceeds innerWidth + 1px  (nothing clipped off-screen)

Also writes a few screenshots to <build>/shots/ for the eyes-on check. Uses the installed Edge
via Playwright's msedge channel; no download, no network.

Exit 0 = all pages/viewports pass. Exit 1 = at least one failure (listed on stdout as JSON).
"""
import json
import os
import sys

from playwright.sync_api import sync_playwright

VIEWPORTS = [(320, 568), (360, 740), (740, 360), (768, 1024), (1024, 768), (1366, 768)]
SCALES = ["100%", "200%"]
SHOT_SET = {("index.html", 360, 740, "100%"), ("index.html", 740, 360, "200%"), ("index.html", 1366, 768, "100%")}

CHECK_JS = """
() => {
  const de = document.documentElement;
  let maxRight = 0, worst = null;
  for (const el of document.querySelectorAll('body *')) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    if (r.right > maxRight) { maxRight = r.right; worst = el.tagName + (el.className ? '.' + el.className : ''); }
  }
  // Containment: a caption that spills out of its own grid item gets overlapped by the next row.
  // The eye caught this on 2026-09-19 where the overflow check could not; assert it geometrically.
  let spilled = 0, spilledIn = null;
  for (const cap of document.querySelectorAll('figcaption')) {
    const li = cap.closest('li') || cap.closest('article') || cap.closest('figure');
    if (!li) continue;
    const c = cap.getBoundingClientRect(), b = li.getBoundingClientRect();
    if (c.bottom > b.bottom + 1 || c.right > b.right + 1 || c.left < b.left - 1) { spilled++; spilledIn = spilledIn || li.className; }
  }
  return { scrollWidth: de.scrollWidth, clientWidth: de.clientWidth, innerWidth: window.innerWidth,
           maxRight: Math.round(maxRight), worst, spilledCaptions: spilled, spilledIn };
}
"""


def main(site, build):
    pages = ["index.html"] + sorted("p/" + f for f in os.listdir(os.path.join(site, "p")) if f.endswith(".html"))
    # 0.3.0: the comparison index and one page per round, when the build emitted them.
    if os.path.isfile(os.path.join(site, "comparisons.html")):
        pages.append("comparisons.html")
    if os.path.isdir(os.path.join(site, "c")):
        pages += sorted("c/" + f for f in os.listdir(os.path.join(site, "c")) if f.endswith(".html"))
    shots = os.path.join(build, "shots")
    os.makedirs(shots, exist_ok=True)
    failures, checks = [], 0
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge")
        for (w, h) in VIEWPORTS:
            ctx = browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=1)
            page = ctx.new_page()
            for rel in pages:
                url = "file:///" + os.path.abspath(os.path.join(site, rel)).replace("\\", "/")
                for scale in SCALES:
                    page.goto(url, wait_until="load")
                    page.evaluate("s => { document.documentElement.style.fontSize = s; }", scale)
                    page.wait_for_timeout(50)
                    m = page.evaluate(CHECK_JS)
                    checks += 1
                    ok = m["scrollWidth"] <= m["clientWidth"] and m["maxRight"] <= m["innerWidth"] + 1 and m["spilledCaptions"] == 0
                    if not ok:
                        failures.append({"page": rel, "viewport": [w, h], "scale": scale, **m})
                    if (rel, w, h, scale) in SHOT_SET or (rel.startswith("p/") and rel == pages[1] and (w, h, scale) in {(320, 568, "100%"), (740, 360, "200%")}):
                        name = f"{rel.replace('/', '_').replace('.html', '')}_{w}x{h}_{scale.rstrip('%')}.png"
                        page.screenshot(path=os.path.join(shots, name), full_page=False)
            ctx.close()
        browser.close()
    print(json.dumps({"pages": len(pages), "viewports": len(VIEWPORTS), "scales": SCALES, "checks": checks,
                      "failures": failures}, indent=1))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
