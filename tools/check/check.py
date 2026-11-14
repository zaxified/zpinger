# SPDX-License-Identifier: MIT
# The release check: limits and expected values of the server and the page,
# measured on this machine, against tools/check/budgets.json (a breach
# fails) and tools/check/baseline.json (the numbers of the last release: a
# metric twice as bad warns). Run by scripts/release-check.sh: fuzz, scale,
# load and serve INSIDE scripts/netns-run (loopback only, no real network),
# ui outside it (the demo's targets answer from the internet).
#   check.py BIN OUTDIR [--only fuzz,scale,load,serve,ui] [--update-baseline]
import json, os, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BIN, OUT = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
args = sys.argv[3:]
only = args[args.index("--only") + 1].split(",") if "--only" in args else ["fuzz", "scale", "load", "serve", "ui"]
os.makedirs(OUT, exist_ok=True)
N = 200  # what the defaults are tuned for (monitor.zig default_max_targets)
metrics, notes = {}, []

def py(script, *a, timeout=900):
    """Runs a check script; its stdout ends in JSON (or ok/FAIL lines)."""
    r = subprocess.run([sys.executable, os.path.join(HERE, script), *a], capture_output=True, text=True, timeout=timeout)
    open(os.path.join(OUT, script + ".out"), "w").write(r.stdout + r.stderr)
    return r

def start(args, log):
    p = subprocess.Popen([BIN, *args], stdout=open(log, "w"), stderr=subprocess.STDOUT)
    return p

def wait_ready(port, demo, secs=150):
    t = time.time()
    while time.time() - t < secs:
        try:
            s = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5))
            if not demo or s["demo_from"] > 0:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False

def stage(name):
    print(f"{time.strftime('%H:%M:%S')} {name}", flush=True)

if "fuzz" in only:
    stage("fuzz: history file, targets file, the whole API (src/fuzz_test.zig, ~2 min)")
    test_bin = os.path.join(os.path.dirname(BIN), "zpinger-test")
    env = dict(os.environ, ZPINGER_FUZZ="20000", ZPINGER_FUZZ_SEEDFILE=os.path.join(OUT, "fuzz.seed"))
    t = time.time()
    r = subprocess.run([test_bin], capture_output=True, text=True, env=env, cwd=ROOT, timeout=900)
    out = r.stdout + r.stderr
    open(os.path.join(OUT, "fuzz.out"), "w").write(out)
    bad = [l for l in out.splitlines() if l.startswith(("FAIL ", "HANG "))]
    metrics["fuzz.failures"] = len(bad) + (0 if r.returncode == 0 else 1)
    notes += [f"fuzz: {l}" for l in bad[:5]]
    if r.returncode != 0 and not bad:
        notes.append(f"fuzz: the test binary exited {r.returncode} (see {OUT}/fuzz.out)")
    labels = ("history_rejected", "history_loaded", "targets_rejected", "targets_loaded", "api_2xx", "api_304", "api_4xx")
    metrics["fuzz.labels_reached"] = sum(1 for lab in labels if any(l.startswith("REACH ") and f" {lab}=" in l and not l.endswith("=0") for l in out.splitlines()))
    metrics["fuzz.seconds"] = round(time.time() - t)

if "scale" in only:
    stage(f"scale: {N} targets, one whole cycle, the page in Chrome (~3 min)")
    r = py("scale.py", BIN, os.path.join(OUT, "scale"), str(N), "60")
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
        for k, v in res.items():
            if k == "lo_rtt_ms_median_max":
                metrics["scale.lo_rtt_max_ms"] = v[1] if v else None
            elif k == "page_errors":
                metrics["scale.page_errors"] = len(v)
            elif isinstance(v, (int, float, bool)):
                metrics["scale." + k] = v
        metrics["scale.live_probes_ratio"] = round(res["live_probes"] / res["live_expected"], 3)
        metrics["scale.sent_all"] = res["sent_full"] == N
    except Exception as e:
        notes.append(f"scale did not finish: {type(e).__name__}: {e} (see {OUT}/scale.py.out)")

if "load" in only:
    stage("load: viewers, burst, churn, slow readers, malformed, writers (~5 min)")
    targets = os.path.join(OUT, "scale", f"targets-{N}.json")
    if not os.path.exists(targets):
        py("scale.py", BIN, os.path.join(OUT, "scale"), str(N), "60")
    r = py("load.py", BIN, targets, os.path.join(OUT, "load"))
    try:
        rep = json.load(open(os.path.join(OUT, "load", "report.json")))
        metrics["load.findings"] = len(rep["findings"])
        notes += [f"load: {f}" for f in rep["findings"]]
        metrics["load.peak_rss_mb"] = rep["peak_ro"]["rss_mb"]
        metrics["load.end_fds_over_baseline"] = rep["end"]["ro"]["fds"] - rep["baseline"]["ro"]["fds"]
        metrics["load.healthy_at_end"] = rep["end"]["ro"]["healthy"] is True and rep["end"]["rw"]["healthy"] is True
        metrics["load.burst_served"] = rep["burst"].get("200", 0)
        metrics["load.churn_requests_per_s"] = rep["churn_requests_per_s"]
        metrics["load.writes_ok"] = rep.get("writes_ok", 0)
        metrics["load.live_p99_ms"] = rep["latency_ms"]["live"]["p99"]
    except Exception as e:
        notes.append(f"load did not finish: {type(e).__name__}: {e} (see {OUT}/load.py.out)")

if "serve" in only:
    stage("serve: 150 clients fetch the whole state at once, gzip and plain")
    targets = os.path.join(OUT, "scale", f"targets-{N}.json")
    if not os.path.exists(targets):
        py("scale.py", BIN, os.path.join(OUT, "scale"), str(N), "60")
    p = start(["--demo", "--targets", targets, "--listen", "127.0.0.1:18410", "--cycle", "60"], os.path.join(OUT, "serve.log"))
    try:
        if not wait_ready(18410, True):
            notes.append("serve: the server did not get ready")
        else:
            urls = os.path.join(OUT, "urls.txt")
            open(urls, "w").write("".join('url = "http://127.0.0.1:18410/api/state"\noutput = "/dev/null"\n' for _ in range(150)))
            for enc in ("gzip", "identity"):
                r = subprocess.run(["curl", "-s", "--parallel", "--parallel-max", "150", "-H", f"Accept-Encoding: {enc}",
                                    "-K", urls, "-w", "%{time_total} %{http_code}\\n"], capture_output=True, text=True, timeout=120)
                rows = [l.split() for l in r.stdout.splitlines() if l.strip()]
                t = sorted(float(x[0]) for x in rows)
                metrics[f"serve.state_{enc}_p99_s"] = round(t[int(0.99 * len(t))], 3) if t else None
                metrics[f"serve.state_{enc}_non200"] = sum(1 for x in rows if x[1] != "200") + (150 - len(rows))
    finally:
        p.terminate(); p.wait()

if "ui" in only:
    stage("ui: the whole page (filters, pills, sorts, editors, add form) and the scroll position")
    rw_list = os.path.join(OUT, "ui-targets.json")
    open(rw_list, "w").write('{"targets":[{"name":"x","host":"192.0.2.1","tags":["old"]}]}')
    # The shipped demo list, as the public demo runs it: this stage runs
    # outside the namespace (scripts/release-check.sh), its targets answer
    # from the internet, so the page shows what a visitor sees.
    demo_list = os.path.join(ROOT, "deploy", "demo-targets.json")
    # A fresh demo each time: a history left by an earlier check (one run
    # inside the namespace, where nothing answers) is real data to the demo.
    history = os.path.join(OUT, "ui-history.json")
    if os.path.exists(history):
        os.remove(history)
    ro = start(["--demo", "--targets", demo_list, "--listen", "127.0.0.1:18420",
                "--history", os.path.join(OUT, "ui-history.json")], os.path.join(OUT, "ui-ro.log"))
    rw = start(["--targets", rw_list, "--listen", "127.0.0.1:18421", "--cycle", "5"], os.path.join(OUT, "ui-rw.log"))
    try:
        if not (wait_ready(18420, True) and wait_ready(18421, False)):
            notes.append("ui: the servers did not get ready")
        else:
            os.makedirs(os.path.join(OUT, "ui-shots"), exist_ok=True)
            r = py("ui.py", "http://127.0.0.1:18420", "http://127.0.0.1:18421", os.path.join(OUT, "ui-shots"))
            fails = [l[5:] for l in r.stdout.splitlines() if l.startswith("FAIL ")]
            metrics["ui.checks"] = sum(1 for l in r.stdout.splitlines() if l.startswith("ok "))
            metrics["ui.failures"] = len(fails) + (0 if "FAILED:" in r.stdout else 1)
            notes += [f"ui: {f}" for f in fails]
            r = py("scroll.py", "http://127.0.0.1:18420/")
            try:
                s = json.loads(r.stdout.strip().splitlines()[-1])
                metrics["ui.scroll_height_change_px"] = s["height_change_moved_px"]
                metrics["ui.scroll_redraw_px"] = s["redraw_moved_px"]
            except Exception as e:
                notes.append(f"ui: scroll check did not finish: {e}")
    finally:
        for p in (ro, rw):
            p.terminate(); p.wait()

# ---- verdict --------------------------------------------------------------------------
budgets = json.load(open(os.path.join(HERE, "budgets.json")))
base_path = os.path.join(HERE, "baseline.json")
baseline = json.load(open(base_path)) if os.path.exists(base_path) else {}
breaches, warns, rows = [], [], []
for key, rule in budgets.items():
    if key.startswith("_") or key.split(".")[0] not in only:
        continue
    v = metrics.get(key)
    b = baseline.get(key)
    ok = v is not None and (
        ("max" not in rule or v <= rule["max"]) and ("min" not in rule or v >= rule["min"]) and ("eq" not in rule or v == rule["eq"]))
    lim = " ".join(f"{k} {rule[k]}" for k in ("max", "min", "eq") if k in rule)
    if not ok:
        breaches.append(f"{key} = {v} (budget {lim})")
    # Twice as bad as the last release: worth a look, even within budget.
    elif isinstance(v, (int, float)) and not isinstance(v, bool) and isinstance(b, (int, float)) and b > 0:
        if ("max" in rule and v > 2 * b and v - b > rule.get("noise", 0)) or ("min" in rule and v < b / 2):
            warns.append(f"{key} = {v}, last release {b}")
    rows.append((key, v, lim, b, rule.get("why", "")))
print()
w = max(len(r[0]) for r in rows) if rows else 10
for key, v, lim, b, why in rows:
    mark = "FAIL" if any(x.startswith(key + " ") for x in breaches) else "ok  "
    print(f"{mark} {key:<{w}}  {str(v):>10}   {lim:<12} last {b}   {why}")
for n in notes:
    print("note:", n)
for x in warns:
    print("WARN (2x the last release):", x)
for x in breaches:
    print("BREACH:", x)
json.dump(metrics, open(os.path.join(OUT, "metrics.json"), "w"), indent=1, sort_keys=True)
failed = bool(breaches) or any(n.endswith(")") and "did not" in n for n in notes)
if "--update-baseline" in args and failed:
    print("baseline NOT updated: the check failed")
elif "--update-baseline" in args:
    baseline.update({k: v for k, v in metrics.items() if k in budgets})
    json.dump(dict(sorted(baseline.items())), open(base_path, "w"), indent=1)
    open(base_path, "a").write("\n")
    print(f"baseline updated: {base_path}")
print("\nrelease check:", "FAILED" if failed else "passed", f"({len(breaches)} breaches, {len(warns)} warnings)")
sys.exit(1 if failed else 0)
