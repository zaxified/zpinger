# SPDX-License-Identifier: MIT
# The scroll position on a phone: a viewport whose height changes (the URL
# bar slides in and out) and a redraw must not move a reader scrolled down
# the list. Headless Chrome over CDP, throwaway profile, no keyring.
#   scroll.py URL      prints one JSON line; exit 1 when the page moved
import asyncio, json, os, subprocess, sys, tempfile, time, urllib.request
import websockets

URL = sys.argv[1]
PORT = int(os.environ.get("CDP_PORT", "9333"))

async def main():
    chrome = subprocess.Popen([
        os.environ.get("CHROME", "google-chrome"), "--headless=new", *(["--no-sandbox"] if os.environ.get("ZPINGER_NETNS") else []),
        f"--remote-debugging-port={PORT}", f"--user-data-dir={tempfile.mkdtemp()}",
        "--password-store=basic", "--use-mock-keychain", "--no-first-run", "--no-default-browser-check", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = {}
    try:
        for _ in range(100):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
                break
            except Exception:
                time.sleep(0.1)
        ws_url = next(t for t in tabs if t["type"] == "page")["webSocketDebuggerUrl"]
        async with websockets.connect(ws_url, max_size=None) as ws:
            n = 0
            async def cmd(method, **params):
                nonlocal n
                n += 1
                await ws.send(json.dumps({"id": n, "method": method, "params": params}))
                while True:
                    m = json.loads(await ws.recv())
                    if m.get("id") == n:
                        return m.get("result")
            async def js(expr):
                r = await cmd("Runtime.evaluate", expression=expr, awaitPromise=True, returnByValue=True, replMode=True)
                return r["result"].get("value")
            async def viewport(h, w=400):
                await cmd("Emulation.setDeviceMetricsOverride", width=w, height=h, deviceScaleFactor=2, mobile=True)
            await viewport(700)
            await cmd("Page.navigate", url=URL)
            await asyncio.sleep(3)
            # Mid-page: at the very bottom the browser clamps, rightly.
            y = await js("Math.max(0, Math.min(600, document.documentElement.scrollHeight - innerHeight - 200))")
            await js(f"window.scrollTo(0, {y})")
            await asyncio.sleep(0.3)
            moved = 0
            for h in (760, 700, 760, 700):
                before = await js("scrollY")
                await viewport(h)
                await asyncio.sleep(0.5)
                moved = max(moved, abs(await js("scrollY") - before))
            out["height_change_moved_px"] = moved
            before = await js("scrollY")
            await js("render(); new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
            out["redraw_moved_px"] = abs(await js("scrollY") - before)
            out["scrolled_to"] = before
    finally:
        chrome.kill()
    print(json.dumps(out))
    sys.exit(0 if out.get("height_change_moved_px", 99) <= 2 and out.get("redraw_moved_px", 99) <= 2 and out.get("scrolled_to", 0) > 0 else 1)

asyncio.run(main())
