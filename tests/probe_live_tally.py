"""Live (network) probe: does a closed round page's tally fetch work against REAL Google, in Edge?

Not part of Invoke-Gates (the gates stay offline). Run it once per change to the tally script/CSP and
whenever Google's published-CSV behaviour is in doubt.

Serves the given closed-round page as if from https://awlfgit.github.io (only that host is routed),
swaps its data-csv for the given published-CSV URL (the CSP and script hash do not depend on it),
and lets the fetch go to the real network: docs.google.com 307 -> *.googleusercontent.com 200.
Passes if the script ends in a non-"Results unavailable." state with no CSP or CORS console error,
and the redirect hop was observed.

Usage: probe_live_tally.py <closed round page.html> <https://docs.google.com/spreadsheets/.../pub?output=csv>
"""
import json
import os
import re
import sys

from playwright.sync_api import sync_playwright

ORIGIN = "https://awlfgit.github.io"


def main(page_path, csv_url):
    page_abs = os.path.abspath(page_path)
    site_root = os.path.dirname(os.path.dirname(page_abs))
    rel = os.path.relpath(page_abs, site_root).replace("\\", "/")
    html = open(page_abs, encoding="utf-8").read()
    html = re.sub(r'data-csv="[^"]*"', 'data-csv="' + csv_url.replace("&", "&amp;") + '"', html, count=1)

    def serve(route):
        u = route.request.url[len(ORIGIN) + 1:].split("?")[0]
        if u == rel:
            return route.fulfill(status=200, headers={"Content-Type": "text/html; charset=utf-8"}, body=html)
        fp = os.path.normpath(os.path.join(site_root, u))
        if fp.startswith(site_root) and os.path.isfile(fp):
            return route.fulfill(status=200, body=open(fp, "rb").read())
        return route.fulfill(status=404, body="")

    console, hops = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge")
        pg = browser.new_page()
        pg.on("console", lambda m: console.append(m.text))
        pg.on("response", lambda r: hops.append({"url": r.url.split("?")[0][:80], "status": r.status,
                                                 "acao": r.headers.get("access-control-allow-origin")}) if "google" in r.url else None)
        pg.route(re.compile("^" + re.escape(ORIGIN) + "/"), serve)
        pg.goto(ORIGIN + "/" + rel, wait_until="load")
        pg.wait_for_function("() => [...document.querySelectorAll('.tally-status')].every(e => !e.textContent.startsWith('Loading'))", timeout=20000)
        states = pg.evaluate("() => [...document.querySelectorAll('.tally-status')].map(e => e.textContent)")
        browser.close()
    bad = [c for c in console if "Content Security Policy" in c or "CORS" in c]
    redirected = any("googleusercontent.com" in h["url"] for h in hops)
    ok = bool(states) and all(s != "Results unavailable." for s in states) and not bad and redirected
    print(json.dumps({"ok": ok, "statuses": states, "hops": hops, "csp_or_cors_errors": bad}, indent=1))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
