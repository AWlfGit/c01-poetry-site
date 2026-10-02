"""Gate 15 browser probe for the closed-round live tally (0.4.0).

Loads a CLOSED round page in Edge (Playwright msedge channel) and serves the tally CSV through
Playwright request routing, so no network is touched. The page's own CSP stays in force: routing
fulfils a request only after the browser has allowed it, so a CSP-blocked fetch never reaches a route.

Scenarios (each must end in the stated per-pair status):
  ok        docs.google.com 200 CSV
            (Playwright cannot route the hop after a fulfilled 3xx -- the browser sends it to the real
            network -- so the real 307 -> doc-NN-sheets.googleusercontent.com shape is proven live by
            tests/probe_live_tally.py, not here.)
  missing   CSV lacks one pair                     -> that pair "No votes recorded."
  http500   docs.google.com answers 500            -> "Results unavailable."
  neterr    request aborted                        -> "Results unavailable."
  garbage   200 with HTML body                     -> "No votes recorded." (no counts written)
  cspblock  307 to a host outside connect-src      -> "Results unavailable." (CSP positive control)

Layout: for every scenario and two viewports, each .tally box and each section.pair keep the height
they had with JavaScript disabled (the pre-script state) -- no layout shift.

Usage: check_tally.py <page.html> <pairA_id> <pairB_id> <tally_csv_url>
Prints JSON; exit 0 only if every scenario passes.
"""
import json
import re
import os
import sys

from playwright.sync_api import sync_playwright

VIEWPORTS = [((320, 568), "200%"), ((1366, 768), "100%")]
EVIL = "https://evil.example.com/tally.csv"
CORS = {"Access-Control-Allow-Origin": "*"}
ORIGIN = "https://awlfgit.github.io"
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css", ".webp": "image/webp", ".png": "image/png"}

MEASURE = """
s => { document.documentElement.style.fontSize = s;
  return { tally: [...document.querySelectorAll('.tally')].map(e => Math.round(e.getBoundingClientRect().height * 10) / 10),
           pair:  [...document.querySelectorAll('section.pair')].map(e => Math.round(e.getBoundingClientRect().height * 10) / 10),
           sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }; }
"""
STATE = """
() => [...document.querySelectorAll('.tally')].map(e => ({ pair: e.dataset.pair,
  a: e.querySelector('.tally-a').textContent, b: e.querySelector('.tally-b').textContent,
  status: e.querySelector('.tally-status').textContent }))
"""


def main(page_path, pa, pb, csv_url):
    # Serve the page from a stand-in https origin (the real Pages host), as file:// has origin "null" and
    # Chromium refuses its cross-origin fetches before any route sees them.
    page_abs = os.path.abspath(page_path)
    site_root = os.path.dirname(os.path.dirname(page_abs))
    url = ORIGIN + "/" + os.path.relpath(page_abs, site_root).replace("\\", "/")
    csv_ok = f"pair_id,a_votes,b_votes\n{pa},12,9\n{pb},3,17\n"
    csv_missing = f"pair_id,a_votes,b_votes\n{pa},4,5\n"

    def serve(route, u):
        rel = u[len(ORIGIN) + 1:].split("?")[0].split("#")[0]
        fp = os.path.normpath(os.path.join(site_root, rel))
        if not fp.startswith(site_root) or not os.path.isfile(fp):
            return route.fulfill(status=404, body="")
        with open(fp, "rb") as f:
            return route.fulfill(status=200, headers={"Content-Type": TYPES.get(os.path.splitext(fp)[1], "application/octet-stream")}, body=f.read())

    def handler(kind):
        def h(route):
            u = route.request.url
            if u.startswith(ORIGIN + "/"):
                return serve(route, u)
            if kind == "neterr":
                return route.abort()
            if u.startswith(csv_url.split("?")[0]):
                if kind == "http500":
                    return route.fulfill(status=500, headers=CORS, body="err")
                if kind == "cspblock":
                    return route.fulfill(status=307, headers={**CORS, "Location": EVIL}, body="")
                body = {"ok": csv_ok, "missing": csv_missing, "garbage": "<html>sign in</html>"}[kind]
                return route.fulfill(status=200, headers={**CORS, "Content-Type": "text/csv"}, body=body)
            if u == EVIL:
                return route.fulfill(status=200, headers={**CORS, "Content-Type": "text/csv"}, body=csv_ok)
            return route.abort()
        return h

    expect = {
        "ok": {pa: ("12", "9", "Counted from the vote form."), pb: ("3", "17", "Counted from the vote form.")},
        "missing": {pa: ("4", "5", "Counted from the vote form."), pb: ("–", "–", "No votes recorded.")},
        "http500": {pa: ("–", "–", "Results unavailable."), pb: ("–", "–", "Results unavailable.")},
        "neterr": {pa: ("–", "–", "Results unavailable."), pb: ("–", "–", "Results unavailable.")},
        "garbage": {pa: ("–", "–", "No votes recorded."), pb: ("–", "–", "No votes recorded.")},
        "cspblock": {pa: ("–", "–", "Results unavailable."), pb: ("–", "–", "Results unavailable.")},
    }
    results, failures = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge")
        for (vw, vh), scale in VIEWPORTS:
            base_ctx = browser.new_context(viewport={"width": vw, "height": vh}, java_script_enabled=False)
            bp = base_ctx.new_page()
            bp.route(re.compile(r"^https://"), lambda r: serve(r, r.request.url) if r.request.url.startswith(ORIGIN + "/") else r.abort())
            bp.goto(url, wait_until="load")
            base = bp.evaluate(MEASURE, scale)
            base_ctx.close()
            for kind, exp in expect.items():
                ctx = browser.new_context(viewport={"width": vw, "height": vh})
                pg = ctx.new_page()
                csp_msgs = []
                pg.on("console", lambda m: csp_msgs.append(m.text) if "Content Security Policy" in m.text else None)
                requested = []
                pg.on("request", lambda r: requested.append(r.url) if not r.url.startswith(ORIGIN) else None)
                pg.route(re.compile(r"^https://"), handler(kind))
                pg.goto(url, wait_until="load")
                try:
                    pg.wait_for_function("() => [...document.querySelectorAll('.tally-status')].every(e => !e.textContent.startsWith('Loading'))", timeout=15000)
                except Exception:
                    pass
                got = {s["pair"]: (s["a"], s["b"], s["status"]) for s in pg.evaluate(STATE)}
                after = pg.evaluate(MEASURE, scale)
                ok_state = got == exp
                ok_layout = after["tally"] == base["tally"] and after["pair"] == base["pair"] and after["sw"] <= after["cw"]
                ok_csp = (kind != "cspblock") or any("connect-src" in m for m in csp_msgs)
                r = {"viewport": [vw, vh], "scale": scale, "scenario": kind, "state_ok": ok_state, "layout_ok": ok_layout,
                     "csp_ok": ok_csp, "got": got, "tally_h": after["tally"], "base_tally_h": base["tally"],
                     "csp_violations": len(csp_msgs)}
                results.append(r)
                if not (ok_state and ok_layout and ok_csp):
                    failures.append(r)
                ctx.close()
        browser.close()
    print(json.dumps({"checks": len(results), "failures": failures,
                      "summary": [f"{r['viewport'][0]}x{r['viewport'][1]}@{r['scale']} {r['scenario']}: state={r['state_ok']} layout={r['layout_ok']} csp={r['csp_ok']} violations={r['csp_violations']}" for r in results]},
                     indent=1, ensure_ascii=True))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:5]))
