# SPDX-License-Identifier: MIT
# Multi-user load test of a zpinger server (and so of the zig-libs HTTP
# server under it). Run INSIDE scripts/netns-run (loopback only):
#   load.py BIN DEMO_TARGETS.json OUTDIR
# Phases: viewers (the page's polling, every answer checked), burst (over the
# connection cap), churn (Connection: close), slow readers, malformed
# requests, writers on a writable instance. Server RSS/threads/fds sampled
# all along; the log is checked for errors. Prints a JSON report; exit 1 on
# any finding.
import asyncio, gzip, json, os, random, subprocess, sys, time, urllib.request, zlib

BIN, TARGETS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
RO_PORT, RW_PORT = 18400, 18401
CYCLE = 20
os.makedirs(OUT, exist_ok=True)
findings, stats = [], {}

def finding(phase, what):
    if sum(1 for f in findings if f.startswith(phase)) < 20:
        findings.append(f"{phase}: {what}")

class Closed(Exception):
    pass

async def read_response(r, head_only=False):
    line = await r.readline()
    if not line:
        raise Closed("closed before a status line")
    parts = line.decode("latin1").split(" ", 2)
    status = int(parts[1])
    hdr = {}
    while True:
        l = await r.readline()
        if not l:
            raise Closed("closed in headers")
        if l in (b"\r\n", b"\n"):
            break
        k, _, v = l.decode("latin1").partition(":")
        hdr[k.strip().lower()] = v.strip()
    body = b""
    if head_only or status in (204, 304) or 100 <= status < 200:
        return status, hdr, body
    if "content-length" in hdr:
        body = await r.readexactly(int(hdr["content-length"]))
    elif hdr.get("transfer-encoding", "").lower() == "chunked":
        while True:
            n = int((await r.readline()).split(b";")[0], 16)
            if n == 0:
                await r.readline()
                break
            body += await r.readexactly(n)
            await r.readline()
    else:
        body = await r.read()
    if hdr.get("content-encoding") == "gzip":
        body = gzip.decompress(body)
    return status, hdr, body

class Conn:
    """One keep-alive connection; reconnects when the server ends it (it
    closes after 100 requests) between two requests."""
    def __init__(self, port, xff=None):
        self.port, self.xff, self.r, self.w, self.reconnects = port, xff, None, None, 0

    async def req(self, method, path, body=None, gz=True, headers=()):
        for attempt in range(2):
            if self.w is None:
                self.r, self.w = await asyncio.open_connection("127.0.0.1", self.port)
            h = [f"{method} {path} HTTP/1.1", "Host: 127.0.0.1"]
            if gz:
                h.append("Accept-Encoding: gzip")
            if self.xff:
                h.append(f"X-Forwarded-For: {self.xff}")
            if body is not None:
                h += ["Content-Type: application/json", f"Content-Length: {len(body)}"]
            h += list(headers)
            self.w.write(("\r\n".join(h) + "\r\n\r\n").encode() + (body or b""))
            try:
                await self.w.drain()
                t = time.perf_counter()
                st, hd, b = await asyncio.wait_for(read_response(self.r), 30)
                if hd.get("connection", "").lower() == "close":
                    self.close()
                return st, hd, b, time.perf_counter() - t
            except (Closed, ConnectionResetError, BrokenPipeError) as e:
                self.close()
                if attempt == 1:
                    raise
                self.reconnects += 1

    def close(self):
        if self.w:
            self.w.close()
        self.r = self.w = None

lat = {}
def note(name, s):
    lat.setdefault(name, []).append(s)

async def viewer(i, port, until, phase="viewers"):
    """The page: static files, the whole state, then live every 2 s and a
    delta when the live view says the state changed. Every answer checked."""
    c = Conn(port, f"10.{i // 250}.{i % 250}.7")
    try:
        for p in ("/", "/app.js", "/style.css", "/favicon.svg"):
            st, _, b, d = await c.req("GET", p)
            if st != 200 or not b:
                finding(phase, f"GET {p} -> {st}, {len(b)} bytes")
        st, _, b, d = await c.req("GET", "/api/state")
        note("state_full", d)
        if st != 200:
            finding(phase, f"state -> {st}"); return
        s = json.loads(b)
        end, version, n_targets = s["end"], s["version"], len(s["targets"])
        live_cycle, live_n = None, 0
        await asyncio.sleep(random.random() * 2)
        while time.time() < until:
            q = f"?cycle={live_cycle}&from={live_n}" if live_cycle is not None else ""
            st, _, b, d = await c.req("GET", "/api/live" + q)
            note("live", d)
            if st != 200:
                finding(phase, f"live -> {st}"); await asyncio.sleep(2); continue
            l = json.loads(b)
            if l["from"] > 0:
                if l["cycle"] != live_cycle or l["from"] != live_n:
                    finding(phase, f"live from={l['from']} for cycle {l['cycle']}, asked {live_cycle}/{live_n}")
                live_n += len(l["probes"])
            else:
                live_cycle, live_n = l["cycle"], len(l["probes"])
            if live_n != l["count"]:
                finding(phase, f"live merged {live_n} probes, server counts {l['count']}")
                live_n = l["count"]
            if l["version"] != version or l["cycle"] > end:
                st, _, b, d = await c.req("GET", f"/api/state?since={end}")
                note("state_delta", d)
                if st != 200:
                    finding(phase, f"delta -> {st}"); continue
                ds = json.loads(b)
                if "since" in ds:
                    want = (ds["end"] - ds["since"]) // ds["cycle_s"] + 1
                    if ds["since"] != end or any(len(t["loss"]) != want for t in ds["targets"]):
                        finding(phase, f"delta since={ds['since']} (had {end}) series of {want}?")
                elif ds["end"] != end:
                    # A whole state for a since off the series: allowed only
                    # when ours is older than a delta reaches (60 cycles).
                    if ds["end"] - end < 60 * ds["cycle_s"]:
                        finding(phase, f"whole state for since={end}, end now {ds['end']}")
                if len(ds["targets"]) != n_targets and phase != "writers":
                    finding(phase, f"delta with {len(ds['targets'])} targets, had {n_targets}")
                end, version = ds["end"], ds["version"]
            await asyncio.sleep(2 + random.uniform(-0.2, 0.2))
    except Exception as e:
        finding(phase, f"viewer {i}: {type(e).__name__}: {e}")
    finally:
        stats.setdefault(phase + "_reconnects", 0)
        stats[phase + "_reconnects"] += c.reconnects
        c.close()

def proc(pid):
    st = {l.split(":")[0]: l.split(":")[1].strip() for l in open(f"/proc/{pid}/status")}
    return {"rss_mb": int(st["VmRSS"].split()[0]) // 1024, "threads": int(st["Threads"]), "fds": len(os.listdir(f"/proc/{pid}/fd"))}

samples = {}
async def sampler(name, pid):
    while True:
        try:
            samples.setdefault(name, []).append((time.time(), proc(pid)))
        except FileNotFoundError:
            finding("server", f"{name} died"); return
        await asyncio.sleep(1)

def healthy(port):
    try:
        return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5))["ok"]
    except Exception as e:
        return f"{type(e).__name__}: {e}"

async def burst(port, n=400):
    """More connections at once than the server takes (256): each asks for
    the whole state uncompressed. Refused ones are closed unanswered."""
    async def one(i):
        try:
            c = Conn(port, f"10.9.{i // 250}.{i % 250}")
            st, _, b, d = await c.req("GET", "/api/state", gz=False)
            c.close()
            return st
        except Exception as e:
            return type(e).__name__
    res = await asyncio.gather(*(one(i) for i in range(n)))
    out = {}
    for r in res:
        out[str(r)] = out.get(str(r), 0) + 1
    stats["burst"] = out
    for k in out:
        if k not in ("200", "Closed", "ConnectionResetError", "IncompleteReadError", "503"):
            finding("burst", f"{out[k]} x {k}")

async def churn(port, secs=20, workers=40):
    n = [0]
    async def w(i):
        t = time.time() + secs
        while time.time() < t:
            try:
                r, wr = await asyncio.open_connection("127.0.0.1", port)
                wr.write(f"GET /api/live HTTP/1.1\r\nHost: x\r\nConnection: close\r\nX-Forwarded-For: 10.8.0.{i}\r\n\r\n".encode())
                await wr.drain()
                st, hd, b = await asyncio.wait_for(read_response(r), 10)
                if st != 200:
                    finding("churn", f"{st}")
                wr.close()
                n[0] += 1
            except Exception as e:
                finding("churn", f"{type(e).__name__}: {e}")
                await asyncio.sleep(0.05)
    await asyncio.gather(*(w(i) for i in range(workers)))
    stats["churn_requests_per_s"] = round(n[0] / secs)

async def slow_readers(port, n=120, secs=40):
    """Clients that ask for the whole state and read it a little at a time."""
    async def one(i):
        try:
            r, w = await asyncio.open_connection("127.0.0.1", port, limit=4096)
            sock = w.get_extra_info("socket")
            sock.setsockopt(__import__("socket").SOL_SOCKET, __import__("socket").SO_RCVBUF, 4096)
            w.write(f"GET /api/state HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 10.7.{i // 250}.{i % 250}\r\n\r\n".encode())
            await w.drain()
            t, got = time.time() + secs, 0
            while time.time() < t:
                b = await r.read(512)
                if not b:
                    return (f"closed by server after {int(secs - (t - time.time()))} s", got)
                got += len(b)
                await asyncio.sleep(0.5)
            w.close()
            return ("still reading", got)
        except Exception as e:
            return (type(e).__name__, 0)
    res = await asyncio.gather(*(one(i) for i in range(n)))
    out = {}
    for k, _ in res:
        out[k] = out.get(k, 0) + 1
    stats["slow_readers"] = out

MALFORMED = [
    b"GARBAGE\r\n\r\n",
    b"GET / HTTP/1.1\r\n\r\n",                              # no Host
    b"GET /api/state HTTP/1.1\r\nHost: x\r\nX-Long: " + b"a" * 70000 + b"\r\n\r\n",
    b"GET /" + b"a" * 20000 + b" HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /api/live?cycle=abc&from=-1 HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /api/live?cycle=1&from=99999999999999999999999 HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /api/live?cycle=-9223372036854775808&from=18446744073709551615 HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /api/state?since=-9223372036854775808 HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /api/state?since=9223372036854775807 HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /api/state?since=%00%ff&since=1 HTTP/1.1\r\nHost: x\r\n\r\n",
    b"POST /api/targets HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\n\r\n{",
    b"POST /api/targets HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\nzz\r\n",
    b"GET /api/live HTTP/1.1\r\nHost: x\r\n\r\nGET /api/live HTTP/1.1\r\nHost: x\r\n\r\nGET /healthz HTTP/1.1\r\nHost: x\r\n\r\n",  # pipelined
    b"GET /api/live HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",  # smuggling shape
    b"GET /api/live HTTP/1.0\r\n\r\n",
    b"GET /api/targets/99999999999999999999/trace HTTP/1.1\r\nHost: x\r\n\r\n",
    b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" + bytes(64),  # a TLS ClientHello
    b"GET /api/live HTTP/1.1\r\nHost: x\r\n",                    # never finished
]

async def malformed(port):
    out = []
    for i, raw in enumerate(MALFORMED):
        expect = 3 if raw.count(b"HTTP/1.1\r\n") == 3 else 1
        try:
            r, w = await asyncio.open_connection("127.0.0.1", port)
            w.write(raw)
            await w.drain()
            got = []
            try:
                while len(got) < expect:
                    st, _, b = await asyncio.wait_for(read_response(r), 15)
                    got.append(st)
            except (Closed, asyncio.IncompleteReadError, ConnectionResetError):
                pass
            except asyncio.TimeoutError:
                got.append("timeout")
            except ValueError as e:
                got.append(f"unparsable: {e}")
            w.close()
            out.append(got)
            if any(isinstance(g, int) and g >= 500 for g in got):
                finding("malformed", f"#{i} -> {got}")
            if "timeout" in got:
                finding("malformed", f"#{i} held for 15 s, no answer and not closed")
        except Exception as e:
            out.append(type(e).__name__)
        h = healthy(port)
        if h is not True:
            finding("malformed", f"#{i}: server not healthy after it: {h}")
    stats["malformed"] = out

async def writers(port, until, n=10):
    async def w(i):
        c = Conn(port)
        ids = []
        try:
            while time.time() < until:
                act = random.choice(["add", "add", "rename", "tags", "pause", "resume", "delete"])
                st = None
                if act == "add":
                    st, _, b, _ = await c.req("POST", "/api/targets", json.dumps({"name": f"w{i}-{random.randrange(10**6)}", "host": f"127.0.{100 + i}.{random.randrange(1, 250)}", "tags": ["load"]}).encode())
                    if st == 201:
                        ids.append(json.loads(b)["id"])
                        stats["writes_ok"] = stats.get("writes_ok", 0) + 1
                    elif st != 409:  # 409: the list is full
                        finding("writers", f"add -> {st} {b[:100]}")
                    continue
                if not ids:
                    await asyncio.sleep(0.05)  # (a bare continue never yields: it froze the event loop)
                    continue
                t = random.choice(ids)
                if act == "rename":
                    st, *_ = await c.req("PATCH", f"/api/targets/{t}", json.dumps({"name": f"r{random.randrange(10**6)}"}).encode())
                elif act == "tags":
                    st, *_ = await c.req("POST", f"/api/targets/{t}/tags", json.dumps({"tags": random.sample(["a", "b", "c", "d", "load"], 2)}).encode())
                elif act in ("pause", "resume"):
                    st, *_ = await c.req("POST", f"/api/targets/{t}/{act}", b"{}")
                elif act == "delete":
                    st, *_ = await c.req("DELETE", f"/api/targets/{t}", b"{}")
                    ids.remove(t)
                if st not in (200, 404):  # 404: another writer deleted it
                    finding("writers", f"{act} -> {st}")
                else:
                    stats["writes_ok"] = stats.get("writes_ok", 0) + 1
                await asyncio.sleep(random.uniform(0.05, 0.3))
        except Exception as e:
            finding("writers", f"writer {i}: {type(e).__name__}: {e}")
        finally:
            c.close()
    await asyncio.gather(*(w(i) for i in range(n)))

def pct(v, p):
    v = sorted(v)
    return round(1000 * v[min(len(v) - 1, int(p / 100 * len(v)))], 1) if v else None

async def main():
    logs = {n: open(f"{OUT}/{n}.log", "w") for n in ("ro", "rw")}
    rw_targets = f"{OUT}/rw-targets.json"
    json.dump({"targets": [{"name": f"rw{i}", "host": f"127.0.50.{i + 1}"} for i in range(50)]}, open(rw_targets, "w"))
    ro = subprocess.Popen([BIN, "--demo", "--targets", TARGETS, "--listen", f"127.0.0.1:{RO_PORT}", "--cycle", str(CYCLE)], stdout=logs["ro"], stderr=logs["ro"])
    rw = subprocess.Popen([BIN, "--targets", rw_targets, "--listen", f"127.0.0.1:{RW_PORT}", "--cycle", "10"], stdout=logs["rw"], stderr=logs["rw"])
    try:
        for _ in range(200):
            try:
                if json.load(urllib.request.urlopen(f"http://127.0.0.1:{RO_PORT}/api/state"))["demo_from"] > 0 and healthy(RW_PORT) is True:
                    break
            except Exception:
                pass
            await asyncio.sleep(0.5)
        base = {"ro": proc(ro.pid), "rw": proc(rw.pid)}
        stats["baseline"] = base
        tasks = [asyncio.create_task(sampler("ro", ro.pid)), asyncio.create_task(sampler("rw", rw.pid))]
        phases = []
        def phase(name):
            phases.append((name, time.time()))
            print(f"{time.strftime('%H:%M:%S')} phase {name}", flush=True)

        only = os.environ.get("PHASES")  # e.g. "slow,writers": run just those
        run = lambda p: not only or p in only.split(",")

        phase("viewers")
        until = time.time() + (75 if run("viewers") else 0)
        await asyncio.gather(*(viewer(i, RO_PORT, until) for i in range(150)))
        stats["after_viewers"] = proc(ro.pid)

        phase("burst")
        if run("burst"):
            await burst(RO_PORT)
            await asyncio.sleep(12)  # the server's 10 s deadlines close the rest
        stats["after_burst"] = {"healthy": healthy(RO_PORT), **proc(ro.pid)}

        phase("churn")
        if run("churn"):
            await churn(RO_PORT)
        await asyncio.sleep(2)
        stats["after_churn"] = proc(ro.pid)

        phase("slow readers + viewers")
        if run("slow"):
            until = time.time() + 40
            await asyncio.gather(slow_readers(RO_PORT), *(viewer(1000 + i, RO_PORT, until, "slow-phase viewers") for i in range(20)))
            await asyncio.sleep(12)
        stats["after_slow"] = {"healthy": healthy(RO_PORT), **proc(ro.pid)}

        phase("malformed")
        if run("malformed"):
            await malformed(RO_PORT)
            stats["malformed_ro"] = stats.pop("malformed")
            await malformed(RW_PORT)

        phase("writers + viewers")
        until = time.time() + 45
        await asyncio.gather(writers(RW_PORT, until), *(viewer(2000 + i, RW_PORT, until, "writers") for i in range(30)))
        await asyncio.sleep(2)  # saves are written after the lock is released
        st = json.load(urllib.request.urlopen(f"http://127.0.0.1:{RW_PORT}/api/state"))
        saved = json.load(open(rw_targets))
        if sorted(t["id"] for t in st["targets"]) != sorted(t.get("id", -1) for t in saved["targets"]):
            finding("writers", f"the target file ({len(saved['targets'])}) differs from the state ({len(st['targets'])})")
        stats["rw_targets_end"] = len(st["targets"])

        await asyncio.sleep(15)  # idle: what does it keep?
        stats["end"] = {"ro": {"healthy": healthy(RO_PORT), **proc(ro.pid)}, "rw": {"healthy": healthy(RW_PORT), **proc(rw.pid)}}
        for t in tasks:
            t.cancel()
    finally:
        for p in (ro, rw):
            if p.poll() is not None:
                finding("server", f"pid {p.pid} exited with {p.returncode}")
            p.terminate(); p.wait()
        for f in logs.values():
            f.close()
    for n in ("ro", "rw"):
        for line in open(f"{OUT}/{n}.log", errors="replace"):
            if " err " in line or "level=err" in line or "panic" in line or "error:" in line:
                finding(f"log {n}", line.strip()[:200])
        stats[f"peak_{n}"] = {k: max(s[1][k] for s in samples.get(n, [(0, {k: 0})])) for k in ("rss_mb", "threads", "fds")}
    stats["latency_ms"] = {k: {"n": len(v), "p50": pct(v, 50), "p99": pct(v, 99), "max": pct(v, 100)} for k, v in lat.items()}
    report = {"findings": findings, **stats}
    print(json.dumps(report, indent=1))
    json.dump(report, open(f"{OUT}/report.json", "w"), indent=1)
    sys.exit(1 if findings else 0)

try:
    asyncio.run(main())
except SystemExit:
    raise
except BaseException as e:
    finding("harness", f"{type(e).__name__}: {e}")
    print(json.dumps({"findings": findings, **stats}, indent=1, default=str))
    sys.exit(2)
