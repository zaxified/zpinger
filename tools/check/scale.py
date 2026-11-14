# SPDX-License-Identifier: MIT
# Scale measurement, run INSIDE scripts/netns-run (loopback only):
#   scale.py BIN OUTDIR N CYCLE_S      prints the result as JSON (OUTDIR/result-N.json)
# N targets on 127.x (answer) plus 5 % on 192.0.2.x (no route: lost), --demo
# so every target has a full 24 h of history. Measures the server (sizes,
# CPU, RSS, cycle timing, loopback RTT as a scheduling-delay probe) and the
# page in headless Chrome (load, render, live update, heap, DOM size).
import asyncio, base64, gzip, json, os, subprocess, sys, tempfile, time, urllib.request
import websockets

BIN, OUT, N, CYCLE = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
PORT, CDP = int(os.environ.get("SCALE_PORT", "18300")), int(os.environ.get("CDP_PORT", "9350"))
URL = f"http://127.0.0.1:{PORT}"
os.makedirs(OUT, exist_ok=True)
scen = ["steady", "evening_congestion", "route_change", "flapping", "outage", "bufferbloat", "long_haul"]
targets = []
for i in range(N):
    lost = i % 20 == 19
    host = f"192.0.2.{i % 250 + 1}" if lost else f"127.{1 + i // 250}.{i % 250}.1"
    targets.append({"id": i + 1, "name": f"target {i + 1:04d}", "host": host,
                    "tags": ["lost" if lost else "lo", f"g{i % 7}"], "demo": "down" if lost else scen[i % len(scen)]})
tf = f"{OUT}/targets-{N}.json"
json.dump({"targets": targets}, open(tf, "w"))

def get(path, headers={}):
    req = urllib.request.Request(URL + path, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read(), dict(r.headers)

def proc_stat(pid):
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    rss = int(open(f"/proc/{pid}/statm").read().split()[1]) * 4096
    return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK"), rss

log = open(f"{OUT}/server-{N}.log", "w")
env = dict(os.environ)
if N > 200: env["ZPINGER_MAX_TARGETS"] = str(N)
srv = subprocess.Popen([BIN, "--demo", "--targets", tf, "--listen", f"127.0.0.1:{PORT}", "--cycle", str(CYCLE)], stdout=log, stderr=log, env=env)
res = {"N": N, "cycle_s": CYCLE}
try:
    t0 = time.time()
    while True:
        try:
            body, _ = get("/api/state")
            if json.loads(body)["demo_from"] > 0: break
        except Exception:
            pass
        if time.time() - t0 > 3 * CYCLE: raise SystemExit("no first cycle")
        time.sleep(0.5)
    res["first_cycle_s"] = round(time.time() - t0, 1)
    # One whole cycle from its start: CPU over it, the live view at its end.
    now = time.time(); time.sleep(CYCLE - now % CYCLE + 0.5)
    cpu0, _ = proc_stat(srv.pid); w0 = time.time()
    time.sleep(CYCLE - 3)
    live, _ = get("/api/live"); lj = json.loads(live)
    res["live_full_bytes"] = len(live); res["live_probes"] = lj["count"]
    res["live_expected"] = N * 5
    last_at = max((p[1] for p in lj["probes"]), default=0); res["live_last_at_ms"] = last_at
    part, _ = get(f"/api/live?cycle={lj['cycle']}&from={max(0, lj['count'] - N * 5 * 2 // CYCLE)}")
    res["live_2s_bytes"] = len(part)
    time.sleep(4)
    cpu1, rss = proc_stat(srv.pid)
    res["cpu_per_cycle_s"] = round((cpu1 - cpu0) * CYCLE / (time.time() - w0), 2); res["rss_mb"] = round(rss / 2**20, 1)
    st, h = get("/api/state"); sz, hz = get("/api/state", {"Accept-Encoding": "gzip"})
    res["state_bytes"] = len(st); res["state_gzip_bytes"] = len(sz)
    s = json.loads(st)
    dz, _ = get(f"/api/state?since={s['end'] - CYCLE}", {"Accept-Encoding": "gzip"})
    res["delta_gzip_bytes"] = len(dz)
    # Live (newest) samples of answering targets: loopback RTT, so anything
    # above a millisecond is the prober's own delay.
    rtts = sorted(t["rtt"][-2] for t in s["targets"] if t["rtt"][-2] is not None and t["tags"][0] == "lo")
    res["lo_rtt_ms_median_max"] = (rtts[len(rtts) // 2], rtts[-1]) if rtts else None
    res["sent_full"] = sum(1 for t in s["targets"] if t["loss"][-2] is not None)
    hz, _ = get("/healthz"); res["healthz"] = json.loads(hz)["ok"]
    res["cycle_done_after_start_s"] = json.loads(hz)["last_cycle"] % CYCLE

    # The page.
    chrome = subprocess.Popen([os.environ.get("CHROME", "google-chrome"), "--headless=new", "--no-sandbox", f"--remote-debugging-port={CDP}",
        f"--user-data-dir={tempfile.mkdtemp(dir=OUT)}", "--password-store=basic", "--use-mock-keychain",
        "--no-first-run", "--no-default-browser-check", "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    async def page():
        for _ in range(100):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{CDP}/json")); break
            except Exception:
                time.sleep(0.1)
        ws_url = next(t for t in tabs if t["type"] == "page")["webSocketDebuggerUrl"]
        errors = []
        async with websockets.connect(ws_url, max_size=None) as ws:
            n = 0
            async def cmd(method, **params):
                nonlocal n
                n += 1
                await ws.send(json.dumps({"id": n, "method": method, "params": params}))
                while True:
                    m = json.loads(await ws.recv())
                    if m.get("method") == "Runtime.exceptionThrown":
                        errors.append(m["params"]["exceptionDetails"]["text"])
                    if m.get("id") == n:
                        return m.get("result")
            async def js(e):
                r = await cmd("Runtime.evaluate", expression=e, awaitPromise=True, returnByValue=True, replMode=True)
                return r["result"].get("value")
            await cmd("Runtime.enable"); await cmd("Performance.enable")
            await cmd("Emulation.setDeviceMetricsOverride", width=1200, height=900, deviceScaleFactor=1, mobile=False)
            t = time.time()
            await cmd("Page.navigate", url=URL + "/")
            for _ in range(200):
                if await js("document.querySelectorAll('#targets .target').length") >= min(N, 20): break
                await asyncio.sleep(0.05)
            res["page_first_rows_s"] = round(time.time() - t, 2)
            await asyncio.sleep(3)
            res["page_render_ms"] = await js("(() => { const a = performance.now(); for (let i = 0; i < 5; i++) render(); return Math.round((performance.now() - a) / 5); })()")
            res["page_filter_ms"] = await js("(() => { const a = performance.now(); for (const q of ['t', 'ta', 'tar', 'targ', 'target 01', '']) { view.q = q; rowLimit = PAGE; render(); } return Math.round((performance.now() - a) / 6); })()")
            res["page_newstate_ms"] = await js("(() => { const a = performance.now(); for (let i = 0; i < 5; i++) { state = { ...state, targets: state.targets.map((t) => ({ ...t })) }; render({ shift: true, arrive: new Set(), flash: new Map() }); } return Math.round((performance.now() - a) / 5); })()")
            res["page_rows_drawn"] = await js("document.querySelectorAll('#targets .target').length")
            res["page_updateLive_ms"] = await js("(() => { const a = performance.now(); for (let i = 0; i < 5; i++) updateLive(); return Math.round(10 * (performance.now() - a) / 5) / 10; })()")
            res["page_feed_ms"] = await js("(() => { const a = performance.now(); feedOpen = true; render(); const d = performance.now() - a; feedOpen = false; render(); return Math.round(d); })()")
            res["page_tick_ms"] = await js("(() => { const a = performance.now(); for (let i = 0; i < 50; i++) { lineBg = null; tick(); } return Math.round(100 * (performance.now() - a) / 50) / 100; })()")
            res["line_bg_chars"] = await js("$('#line').style.backgroundImage.length")
            res["dom_nodes"] = await js("document.getElementsByTagName('*').length")
            met = {m["name"]: m["value"] for m in (await cmd("Performance.getMetrics"))["metrics"]}
            res["js_heap_mb"] = round(met["JSHeapUsedSize"] / 2**20, 1)
            r = await cmd("Page.captureScreenshot", format="png")
            open(f"{OUT}/page-{N}.png", "wb").write(base64.b64decode(r["data"]))
        res["page_errors"] = errors
    try:
        asyncio.run(page())
    finally:
        chrome.kill(); chrome.wait()
finally:
    srv.kill(); srv.wait()
print(json.dumps(res))
open(f"{OUT}/result-{N}.json", "w").write(json.dumps(res, indent=1))
