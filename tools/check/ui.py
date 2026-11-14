# SPDX-License-Identifier: MIT
# The whole page in headless Chrome over CDP (no keyring: basic password
# store, throwaway profile): filters, pills, sorts against an independent
# recomputation of the problem tiers, the fragment, the tag picker, the
# name/host editor, the add form. Needs a demo instance (deploy/demo-targets
# .json) and a writable one whose list is exactly
#   {"targets":[{"name":"x","host":"192.0.2.1","tags":["old"]}]}
#   ui.py DEMO_URL RW_URL SHOTDIR      `ok`/`FAIL` lines, exit 1 on any FAIL
import asyncio, base64, json, os, subprocess, sys, tempfile, time, urllib.request
import websockets

DEMO, RW, SHOTS = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = int(os.environ.get("CDP_PORT", "9334"))
fails = []

def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)

async def main():
    prof = tempfile.mkdtemp()
    chrome = subprocess.Popen([
        os.environ.get("CHROME", "google-chrome"), "--headless=new", *(["--no-sandbox"] if os.environ.get("ZPINGER_NETNS") else []),
        f"--remote-debugging-port={PORT}",
        f"--user-data-dir={prof}", "--password-store=basic", "--use-mock-keychain",
        "--no-first-run", "--no-default-browser-check", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json")); break
            except Exception:
                time.sleep(0.1)
        ws_url = next(t for t in tabs if t["type"] == "page")["webSocketDebuggerUrl"]
        async with websockets.connect(ws_url, max_size=None) as ws:
            n = 0
            errors = []
            async def cmd(method, **params):
                nonlocal n
                n += 1
                await ws.send(json.dumps({"id": n, "method": method, "params": params}))
                while True:
                    m = json.loads(await ws.recv())
                    if m.get("method") == "Runtime.exceptionThrown":
                        errors.append(m["params"]["exceptionDetails"].get("exception", {}).get("description"))
                    if m.get("id") == n:
                        return m.get("result")
            async def js(expr):
                r = await cmd("Runtime.evaluate", expression=expr, awaitPromise=True, returnByValue=True, replMode=True)
                if "exceptionDetails" in r:
                    raise RuntimeError(r["exceptionDetails"])
                return r["result"].get("value")
            async def vp(w, h, mobile):
                await cmd("Emulation.setDeviceMetricsOverride", width=w, height=h, deviceScaleFactor=1 if not mobile else 2, mobile=mobile)
            async def go(url):
                await cmd("Page.navigate", url=url)
                await asyncio.sleep(1.5)
            async def shot(name):
                r = await cmd("Page.captureScreenshot", format="png")
                open(f"{SHOTS}/{name}.png", "wb").write(base64.b64decode(r["data"]))
            names = "[...document.querySelectorAll('#targets .name')].map(e => e.textContent)"
            await cmd("Runtime.enable")
            await vp(1100, 900, False)

            # --- demo: filter, search, sort ---
            await go(DEMO + "/")
            all_names = await js(names)
            check(len(all_names) == 8, f"all 8 targets shown: {all_names}")
            chips = await js("[...document.querySelectorAll('#tagbar .chip')].map(e => e.textContent)")
            check(chips == ["asia", "cloudflare", "dns", "google", "ipv4", "ipv6", "ntp", "vpn", "web"], f"chips {chips}")
            await js("[...document.querySelectorAll('#tagbar .chip')].find(c => c.textContent === 'dns').click()")
            await js("[...document.querySelectorAll('#tagbar .chip')].find(c => c.textContent === 'ipv6').click()")
            got = await js(names)
            check(sorted(got) == ["Cloudflare DNS (IPv6)", "Google DNS (IPv6)"], f"dns AND ipv6: {got}")
            check(await js("location.hash") == "#tags=dns,ipv6", f"hash {await js('location.hash')}")
            check("2 of 8" in await js("$('#shown').textContent"), "count note")
            await shot("filter-tags")
            await js("$('#shown .link').click()")
            check(len(await js(names)) == 8, "clear shows all")
            await js("const f = $('#find'); f.value = 'google'; f.dispatchEvent(new Event('input'))")
            got = await js(names)
            check(sorted(got) == ["Google DNS", "Google DNS (IPv6)"], f"find google: {got}")
            await js("const f = $('#find'); f.value = 'ipv4 dns 9.9'; f.dispatchEvent(new Event('input'))")
            check(await js(names) == ["Quad9 DNS"], f"find words AND: {await js(names)}")
            await js("const f = $('#find'); f.value = 'nothing-like-this'; f.dispatchEvent(new Event('input'))")
            check("No target matches" in await js("$('#targets').textContent"), "empty result message")
            await js("$('#targets .link').click()")
            check(len(await js(names)) == 8 and await js("$('#find').value") == "", "Show all clears the search")

            # Status pills: always all eight, counts add up, a click filters.
            pills = "Object.fromEntries([...document.querySelectorAll('#summary .pill')].map(p => [p.textContent.replace(/^\\d+ /, ''), +p.textContent.split(' ')[0]]))"
            c = await js(pills)
            check(list(c) == ["ok", "nok", "up", "down", "loss", "ack", "pending", "paused"], f"all pills: {c}")
            total = len(await js(names))
            check(c["up"] + c["loss"] + c["down"] + c["ack"] + c["pending"] + c["paused"] == total, "status counts add up")
            check(c["ok"] + c["nok"] + c["ack"] + c["pending"] + c["paused"] == total, "health counts add up")
            check(await js("$('#summary .pill.zero') !== null"), "empty pills shown, faint")
            click = lambda label: js(f"[...document.querySelectorAll('#summary .pill')].find(p => p.textContent.endsWith(' {label}')).click()")
            await click("down")
            badges = "[...document.querySelectorAll('#targets .badge')].map(e => e.textContent)"
            check(await js(badges) == ["DOWN"] * c["down"], f"down only: {await js(badges)}")
            check(await js("location.hash") == "#st=down", f"hash {await js('location.hash')}")
            check(await js("[...document.querySelectorAll('#summary .pill')].find(p => p.textContent.endsWith(' down')).getAttribute('aria-pressed')") == "true", "pressed")
            await click("nok")
            got = await js("[...document.querySelectorAll('#targets [data-target]')].map(r => { const t = state.targets.find(x => x.id == r.dataset.target); const h = 3600 / state.cycle_s; return statusOf(t) === 'down' || healthOf(t, {day: summarize(t), hour: summarize(t, h)}) === 'nok'; })")
            check(len(got) == len(set(range(len(got)))) and all(got) and len(got) >= c["down"], f"down OR not ok: {len(got)} rows")
            check(len(got) == c["nok"] + sum(1 for b in await js(badges) if b == "ACK"), "the union, no more")  # DOWN is always not ok unless acked
            await js("$('#shown .link').click()")
            check(len(await js(names)) == total and await js("location.hash") == "", "clear drops the pills too")
            await js("[...document.querySelectorAll('#tagbar .chip')].find(c => c.textContent === 'google').click()")
            c = await js(pills)
            check(sum(c[k] for k in ["up", "loss", "down", "ack", "pending", "paused"]) == 2, f"pills count the tag's targets: {c}")
            await click("ok")
            check(all(n.startswith("Google") for n in await js(names)), "pill AND tag")
            await go(DEMO + "/#st=nok,down")
            check(await js("[...document.querySelectorAll('#summary .pill[aria-pressed=true]')].map(p => p.textContent.replace(/^\\d+ /, ''))") == ["nok", "down"], "pills from the fragment")
            await shot("pills-filter")
            await go(DEMO + "/")

            # Metric orders, both windows: the page's figures, worst first, no data last.
            for key in ["loss1h", "jitter1h", "avg1h", "max1h", "loss24h", "jitter24h", "avg24h", "max24h"]:
                await js(f"const s = $('#sort'); s.value = '{key}'; s.dispatchEvent(new Event('change'))")
                m, w = key.rstrip("1h24"), key[len(key.rstrip("1h24")):]
                cycles = "60" if w == "1h" else "1440"
                expr = f"[...document.querySelectorAll('#targets .name')].map(e => summarize(state.targets.find(t => t.name === e.textContent), {cycles}).{m})"
                vals = await js(expr)
                nums = [v for v in vals if v is not None]
                check(nums == sorted(nums, reverse=True) and vals[:len(nums)] == nums, f"sort {key}: {[round(v, 2) if v is not None else None for v in vals]}")
                await js("$('#order').click()")
                vals = await js(expr)
                nums = [v for v in vals if v is not None]
                check(nums == sorted(nums) and vals[:len(nums)] == nums, f"sort {key} reversed, no data last")
                await js("$('#order').click()")
            check(await js("location.hash") == "#sort=max24h", f"hash after sorts {await js('location.hash')}")
            check(await js("$('#sort').selectedOptions[0].parentElement.label") == "Last 24 hours", "option groups")

            # Problems first, recomputed here from the raw state.
            async def tiers():
                st = await js("state")
                by = {t["name"]: t for t in st["targets"]}
                out = []
                for name in await js(names):
                    t = by[name]
                    def win(k):
                        loss = [v for v in t["loss"][-k:] if v is not None]
                        jit = [v for v in t["jitter"][-k:] if v is not None]
                        return (sum(loss) / len(loss) if loss else 0), (sum(jit) / len(jit) if jit else 0)
                    h, d = win(60), win(1440)
                    status = "acked" if t["status"] == "down" and t["acked"] else t["status"]
                    tier = {"down": 0, "degraded": 1, "acked": 4, "pending": 6, "paused": 7}.get(status)
                    if tier is None:
                        tier = 2 if h[0] >= 1 or h[1] >= 10 else 3 if d[0] >= 1 or d[1] >= 10 else 5
                    out.append((tier, -h[0], name))
                return out
            await js("const s = $('#sort'); s.value = 'status'; s.dispatchEvent(new Event('change'))")
            got = await tiers()
            check([x[:2] for x in got] == sorted(x[:2] for x in got), f"problems first: {[(x[2], x[0]) for x in got]}")
            check(len({x[0] for x in got}) >= 3, "the demo spans several tiers")
            await js("$('#order').click()")
            got = await tiers()
            check([x[0] for x in got] == sorted((x[0] for x in got), reverse=True), f"problems reversed: {[(x[2], x[0]) for x in got]}")
            await js("$('#order').click()")
            await js("const s = $('#sort'); s.value = 'name'; s.dispatchEvent(new Event('change'))")
            order = await js(names)
            check(order == sorted(order, key=str.lower), "sort name")
            await js("$('#order').click()")
            check(await js(names) == order[::-1], "name reversed")

            # The fragment restores the view; the 1.0 form still opens a target.
            await go(DEMO + "/#tags=google&q=ipv6&sort=name&rev=1")
            check(await js(names) == ["Google DNS (IPv6)"], "view from the fragment")
            check(await js("$('#find').value") == "ipv6" and await js("$('#sort').value") == "name", "controls from the fragment")
            await go(DEMO + "/#3")
            check(await js("[...document.querySelectorAll('.detail')].filter(d => !d.hidden).length") == 1, "legacy #3 opens a target")
            await js("document.querySelector('.head').click()")  # close the first (status order) row? only if it is 3
            await go(DEMO + "/")
            await shot("demo-desktop")
            await vp(400, 800, True)
            await go(DEMO + "/#open=1&tags=dns")
            await shot("demo-mobile")
            outside = "document.body.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}))"
            esc = lambda sel: f"$('{sel}').dispatchEvent(new KeyboardEvent('keydown', {{key: 'Escape', bubbles: true}}))"
            pick = lambda i: f"$('[data-target=\"{i}\"] .edit-tags').click()"
            # Read-only: the picker opens; a change, saved by a click outside, is explained.
            await js(pick(1))
            check(await js("!!$('.tag-popover')"), "RO picker opens")
            await js("$('.tag-popover .pop-item').click()")
            await js(outside)
            await asyncio.sleep(0.3)
            check("read-only demo" in (await js("$('[data-target=\"1\"] .row-note')?.textContent") or ""), "RO change explained")
            # ... and so is a rename, which closes (nothing could be saved anyway).
            await js("$('[data-target=\"1\"] .edit-target').click()")
            await js("const i = $('[data-focus=\"rename-name\"]'); i.value = 'x'; i.dispatchEvent(new Event('input'))")
            await js("$('.who-editor').requestSubmit()")
            await asyncio.sleep(0.3)
            check(await js("!$('.who-editor')") and "read-only demo" in (await js("$('[data-target=\"1\"] .row-note')?.textContent") or ""), "RO rename explained, editor closed")

            # --- writable: the add form, its picker and the ipv4/ipv6 tag ---
            await vp(1100, 900, False)
            await go(RW + "/")
            # Since 2026-11-14 the form is in the bar's menu, folded by default.
            await js("if ($('#menu-body').hidden) $('#menu').click()")
            check(await js("!$('#menu-body').hidden"), "the menu unfolds (the add form is in it)")
            addtags = "[...document.querySelectorAll('#add-tags .rtag')].map(e => e.textContent)"
            host = lambda v: js(f"const h = $('#add').host; h.value = {json.dumps(v)}; h.dispatchEvent(new Event('input'))")
            await host("192.0.2.50")
            check(await js(addtags) == ["ipv4"], f"IPv4 ticks ipv4: {await js(addtags)}")
            await host("2001:db8::50")
            check(await js(addtags) == ["ipv6"], f"IPv6 swaps it: {await js(addtags)}")
            await host("example.org")
            check(await js(addtags) == [], "a name ticks nothing")
            await host("192.0.2.50")
            typ = lambda v: js(f"const i = $('.tag-popover .tag-input'); i.value = {json.dumps(v)}; i.dispatchEvent(new Event('input'))")
            enter = "$('.tag-popover .tag-input').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}))"
            await js("$('#add-tags .tags').click()")  # the whole box opens it
            check(await js("!!$('#add-tags .tag-popover')"), "add form picker opens")
            for tag in ["Lab", "core"]:
                await typ(tag)
                await js(enter)
            await js(enter)  # empty filter: close and keep
            check(await js("!$('#add-tags .tag-popover')") and await js(addtags) == ["ipv4", "lab", "core"], f"picked: {await js(addtags)}")
            check(await js("document.activeElement.dataset.focus") == "edit-tags", "focus back on the add form's button")
            await js("$('#add-tags').click()")
            await typ("drop")
            await js(enter)
            await js(esc(".tag-popover"))
            check(await js(addtags) == ["ipv4", "lab", "core"], "Esc drops the change")
            await js("const f = $('#add'); f.name.value = 'Lab router'")
            await js("$('#add button[type=submit]').click()")
            await asyncio.sleep(1)
            t = await js("state.targets.find(t => t.name === 'Lab router')")
            check(t and t["tags"] == ["ipv4", "lab", "core"], f"added with tags: {t and t['tags']}")
            check(await js(addtags) == [] and await js("$('#add').host.value") == "", "form reset")
            tid = t["id"]
            await go(RW + f"/#open={tid}")

            # --- the row's tag picker ---
            items = "[...document.querySelectorAll('.pop-item')].map(b => [b.textContent, b.getAttribute('aria-selected')])"
            await js(pick(tid))
            got = await js(items)
            check(got == [["✓core", "true"], ["✓ipv4", "true"], ["✓lab", "true"], ["old", "false"]], f"picker lists: {got}")
            check(await js("document.activeElement.dataset.focus") == "tag-filter", "filter focused")
            await typ("praha")
            check(await js("$('.pop-item.create')?.textContent") == "+Create tag “praha”", "offers to create")
            await js(enter)
            check(await js("$('.tag-popover .tag-input').value") == "", "filter cleared after Enter")
            await js("[...document.querySelectorAll('.pop-item')].find(b => b.textContent.endsWith('core')).click()")
            await typ("pr")
            await js("$('.tag-popover .tag-input').setSelectionRange(1, 1)")
            await js("render()")  # a new cycle while picking
            check(await js("$('.tag-popover .tag-input').value") == "pr", "filter survives a re-render")
            check(await js("document.activeElement.dataset.focus === 'tag-filter' && document.activeElement.selectionStart === 1"), "focus and caret survive")
            await typ("a b")
            check(await js("$('.pop-note').textContent") == "No spaces or commas" and await js("!$('.pop-item.create')"), "bad name refused")
            await js(esc(".tag-popover"))
            await asyncio.sleep(0.5)
            check(sorted(await js(f"state.targets.find(t => t.id === {tid}).tags")) == ["core", "ipv4", "lab"], "Esc drops the changes")
            check(await js("document.activeElement.dataset.focus") == "edit-tags", "focus back on the edit button")
            await js(pick(tid))
            await typ("praha")
            await js(enter)
            await js(outside)
            await asyncio.sleep(1)
            check(sorted(await js(f"state.targets.find(t => t.id === {tid}).tags")) == ["core", "ipv4", "lab", "praha"], "a click outside saves")
            await js(pick(tid))
            for i in range(5):
                await typ(f"t{i}")
                await js(enter)
            check("At most 8" in await js("$('.pop-note').textContent"), "limit note")
            check(await js("[...document.querySelectorAll('.pop-item')].filter(b => b.disabled).length") >= 1, "unticked items disabled at the limit")
            await js(outside)
            await asyncio.sleep(1)
            check(len(await js(f"state.targets.find(t => t.id === {tid}).tags")) == 8, "saved at the limit")
            check(await js(f"!$('[data-target=\"{tid}\"] .detail').hidden"), "editing tags did not toggle the row")

            # --- name and host, in the head ---
            row = f"$('[data-target=\"{tid}\"]')"
            await js(f"{row}.querySelector('.edit-target').click()")
            check(await js(f"!!{row}.querySelector('.who-editor')"), "rename editor opens")
            check(await js(f"!{row}.querySelector('.who-editor button')"), "no buttons, like the picker")
            check(await js("document.activeElement.dataset.focus") == "rename-name", "name field focused")
            check(await js(f"!{row}.querySelector('.detail').hidden"), "opening it did not toggle the row")
            fld = lambda k, v: js(f"const i = {row}.querySelector('[data-focus=\"rename-{k}\"]'); i.value = {json.dumps(v)}; i.dispatchEvent(new Event('input'))")
            await fld("name", "Core router")
            await js(f"{row}.querySelector('[data-focus=\"rename-name\"]').setSelectionRange(2, 2)")
            await js("render()")
            check(await js(f"{row}.querySelector('[data-focus=\"rename-name\"]').value") == "Core router", "typed name survives a re-render")
            check(await js("document.activeElement.dataset.focus === 'rename-name' && document.activeElement.selectionStart === 2"), "focus and caret survive")
            await fld("host", "no such host!")
            await js(outside)
            await asyncio.sleep(0.5)
            check("host:" in (await js(f"{row}.querySelector('.who-editor .row-note.error')?.textContent") or ""), "bad host: editor stays, with the error")
            await fld("host", "2001:db8::51")
            await js(f"{row}.querySelector('.who-editor').requestSubmit()")  # Enter
            await asyncio.sleep(1)
            t = await js(f"state.targets.find(t => t.id === {tid})")
            check(t["name"] == "Core router" and t["host"] == "2001:db8::51", f"renamed and moved: {t['name']} {t['host']}")
            check("ipv6" in t["tags"] and "ipv4" not in t["tags"] and len(t["tags"]) == 8, f"ipv4 tag swapped for ipv6: {t['tags']}")
            check(t["status"] == "pending", f"new host starts over: {t['status']}")
            check(await js(f"!{row}.querySelector('.who-editor')") and await js(f"{row}.querySelector('.name').textContent") == "Core router", "editor closed, row shows the new name")
            check(await js("document.activeElement.dataset.focus") == "edit-target", "focus back on the edit button")
            await js(f"{row}.querySelector('.edit-target').click()")
            await fld("name", "Something else")
            await js(esc(".who-editor"))
            check(await js(f"state.targets.find(t => t.id === {tid}).name") == "Core router" and await js(f"!{row}.querySelector('.who-editor')"), "Esc cancels")
            await js(f"{row}.querySelector('.edit-target').click()")
            await js(outside)
            check(await js(f"!{row}.querySelector('.who-editor')"), "unchanged: a click outside just closes")
            await js(f"{row}.querySelector('.host').click()")
            check(await js(f"{row}.querySelector('.detail').hidden"), "a click on the head collapses the row")
            await js(f"{row}.querySelector('.expand').click()")
            check(await js(f"!{row}.querySelector('.detail').hidden"), "the expand button opens it")
            check(not errors, f"no page errors: {errors}")
    finally:
        chrome.kill()

asyncio.run(main())
print("FAILED:", len(fails) if fails else "none")
sys.exit(1 if fails else 0)
