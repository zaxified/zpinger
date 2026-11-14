// zpinger front end: polls /api/state and renders it. No framework, no
// build step; every user-supplied string goes through textContent.
"use strict";

// The page polls /api/live (the cycle being probed, a few hundred bytes)
// every 2 s, and loads the state only when that says it changed; a slow
// fallback catches a server that probes nothing (every target paused).
const LIVE_MS = 2000;
const STATE_FALLBACK_MS = 60000;
const BEAT_PX = 9; // beat width + gap, see .beat in style.css
let state = null;
let live = null; // the last /api/live answer, its probes merged
let liveById = new Map(); // its probes by target id
let skew = 0; // server clock minus this browser's, ms
let online = true;
let lastHeard = Date.now(); // the last answer from the server

// What the list shows, kept in the URL fragment so a filtered view can be
// bookmarked or sent: #open=3,5&tags=dns,ipv6&q=google&sort=loss&rev=1.
// fping-watch's form, #3,5, still opens targets 3 and 5.
// The status pills, which filter the list too: health over the last hour
// (see healthOf), then the status now.
const PILLS = {
  ok: ["ok", "var(--up)", "Probed, and no problem in the last hour"],
  nok: ["nok", "var(--down)", "Needs attention: DOWN, losing probes now, or a problem in the last hour (1 % packet loss or 10 ms of jitter on average, or more); acknowledged outages are not counted"],
  up: ["up", "var(--up)", "Every probe of the last cycle answered"],
  down: ["down", "var(--down)", "Every probe of the last cycle lost"],
  degraded: ["loss", "var(--warn)", "Some probes of the last cycle lost"],
  acked: ["ack", "var(--ack)", "DOWN, and acknowledged"],
  pending: ["pending", "var(--paused)", "Not probed yet"],
  paused: ["paused", "var(--paused)", "Not probed: paused"],
};
const HEALTH = ["ok", "nok"];

// Sort keys: status, name, and a metric over a window (loss1h, max24h, ...).
const METRICS = { loss: "Packet loss", jitter: "Jitter", avg: "Average latency", max: "Worst latency" };
const WINDOWS = { "1h": ["Last hour", "1 h", "hour"], "24h": ["Last 24 hours", "24 h", "day"] };
const SORTS = { status: "Problems first", name: "Name" };
for (const [w, [, short]] of Object.entries(WINDOWS))
  for (const [m, label] of Object.entries(METRICS)) SORTS[m + w] = `${label} (${short})`;
function parseView() {
  const hash = location.hash.slice(1);
  const p = new URLSearchParams(/^[\d,]+$/.test(hash) ? `open=${hash}` : hash);
  const list = (key) => (p.get(key) || "").split(",").filter(Boolean);
  return {
    open: new Set(list("open").map(Number)), // ids of expanded targets
    tags: new Set(list("tags")), // a target must have every one
    // hasOwn, not `in`: a link's #sort=constructor must not reach Object.prototype.
    st: new Set(list("st").filter((k) => Object.hasOwn(PILLS, k))), // a target must be in one
    q: p.get("q") || "",
    sort: Object.hasOwn(SORTS, p.get("sort") ?? "") ? p.get("sort") : "status",
    rev: p.get("rev") === "1",
  };
}
const view = parseView();

function saveView() {
  const p = new URLSearchParams();
  if (view.open.size) p.set("open", [...view.open].join(","));
  if (view.tags.size) p.set("tags", [...view.tags].join(","));
  if (view.st.size) p.set("st", [...view.st].join(","));
  if (view.q) p.set("q", view.q);
  if (view.sort !== "status") p.set("sort", view.sort);
  if (view.rev) p.set("rev", "1");
  const hash = p.toString().replaceAll("%2C", ",");
  history.replaceState(null, "", hash ? `#${hash}` : location.pathname + location.search);
}

// The open editors, kept across re-renders (a new cycle redraws the list
// while someone types). The tag picker: whose tags (a target id, or "new"
// for the add form), the tags ticked so far, the list order fixed when it
// opened, the filter text. The name and host editor: the fields as typed.
let editing = null; // { id, selected: Set, order: [], filter }
let renaming = null; // { id, name, host, note, saving }
// Why the last change of a row failed, shown under its name.
let rowNote = null; // { id, text }
// The add form's tags; `auto` is the ipv4/ipv6 tag it ticked by itself for
// the host typed, `refused` one the user unticked (not ticked again).
let adding = { tags: [], auto: null, refused: null };
const MAX_TAGS = 8, MAX_TAG_LEN = 32;


const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};
const svgEl = (tag, attrs) => {
  const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  return e;
};

const STATUS = {
  up: ["UP", "var(--up)"],
  degraded: ["LOSS", "var(--warn)"],
  down: ["DOWN", "var(--down)"],
  acked: ["ACK", "var(--ack)"],
  paused: ["PAUSED", "var(--paused)"],
  pending: ["PENDING", "var(--paused)"],
};
const statusOf = (t) => (t.status === "down" && t.acked ? "acked" : t.status);

const beatColor = (loss) =>
  loss === null ? "" : loss === 0 ? "var(--up)" : loss < 100 ? "var(--warn)" : "var(--down)";

const ms = (v) =>
  v === null || v === undefined ? "–" : v < 1 ? `${v.toFixed(2)} ms` : v < 10 ? `${v.toFixed(1)} ms` : `${Math.round(v)} ms`;
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);
// Nearest-rank percentile.
const percentile = (a, p) => {
  if (!a.length) return null;
  const sorted = [...a].sort((x, y) => x - y);
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
};
// One cycle, for the beat strip and the chart tooltip. A demo marks the
// sample data (everything before demo_from).
const isSample = (t, at) => t.sample && at < state.demo_from;
const describe = (t, i, at) =>
  (isSample(t, at) ? "sample data · " : "") +
  (t.loss[i] === null
    ? `${time(at)} · no data`
    : `${time(at)} · ${ms(t.rtt[i])}` + (t.jitter[i] === null ? "" : ` ± ${ms(t.jitter[i])}`) + ` · ${t.loss[i]} % loss`);
// One formatter for every time on the page: making one per call (what
// toLocaleTimeString does) cost most of a render with many targets.
const HHMM = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit" });
const time = (unix) => HHMM.format(unix * 1000);

// Figures over the last `cycles` cycles (default: all 24 hours).
function summarize(t, cycles = t.rtt.length) {
  const from = Math.max(0, t.rtt.length - cycles);
  const rtts = t.rtt.slice(from).filter((v) => v !== null);
  const losses = t.loss.slice(from).filter((v) => v !== null);
  const jitters = t.jitter.slice(from).filter((v) => v !== null);
  const up = losses.filter((v) => v < 100).length;
  let last = null, lastJitter = null;
  for (let i = t.rtt.length - 1; i >= 0; i--) {
    if (t.loss[i] === null) continue;
    last = t.rtt[i];
    lastJitter = t.jitter[i];
    break;
  }
  return {
    samples: losses.length,
    uptime: losses.length ? (100 * up) / losses.length : null,
    avg: mean(rtts),
    min: rtts.length ? Math.min(...rtts) : null,
    max: rtts.length ? Math.max(...rtts) : null,
    p95: percentile(rtts, 95),
    jitter: mean(jitters),
    loss: mean(losses),
    last,
    lastJitter,
  };
}

// ----- API -------------------------------------------------------------------

let etag = null;

// Loads may overlap (a poll, a change, the fallback); an answer older than
// one already shown is dropped.
//
// Once the page has a state it asks only for what changed since its `end`
// (`?since=`): the series from that cycle on, which it puts after its own,
// a few bytes per target instead of the whole day every cycle. A delta that
// does not fit (another sample-data hour of a demo, a new target, a gap of
// more than a day) means the whole state again.
let loadSeq = 0, shownSeq = 0;
async function load(full = false) {
  const seq = ++loadSeq;
  try {
    const since = !full && state ? `?since=${state.end}` : "";
    // "no-cache": the browser revalidates with If-None-Match, and the server
    // answers 304 until the next cycle; nothing new means nothing to redraw.
    const res = await fetch(`api/state${since}`, { cache: "no-cache" });
    if (!res.ok) throw new Error(res.statusText);
    const tag = res.headers.get("etag");
    if (seq < shownSeq) return;
    if (tag === null || tag !== etag) {
      let next = await res.json();
      if (seq < shownSeq) return;
      if (next.since !== undefined) {
        next = mergeDelta(state, next);
        if (!next) return load(true);
      }
      etag = tag;
      if (state && next.version === state.version && next.end === state.end) return heard();
      shownSeq = seq;
      const before = state;
      state = next;
      render(before && changesSince(before, state));
    }
    heard();
  } catch (err) {
    lost(err);
  }
}

// `old` with the delta `d` put after it, or null when it does not fit.
function mergeDelta(old, d) {
  if (!old || d.since !== old.end || d.cycle_s !== old.cycle_s || d.demo_from !== old.demo_from) return null;
  const known = new Map(old.targets.map((t) => [t.id, t]));
  const shift = (d.end - d.since) / d.cycle_s;
  for (const t of d.targets) {
    const o = known.get(t.id);
    if (!o || shift >= o.loss.length) return null;
    // The old series without its newest cycle (the delta has it again,
    // recorded by now), then the delta.
    for (const key of ["rtt", "jitter", "loss"]) t[key] = o[key].slice(shift, o[key].length - 1).concat(t[key]);
  }
  delete d.since;
  return d;
}

let livePolling = false;
async function pollLive() {
  if (livePolling) return;
  livePolling = true;
  try {
    // Only the probes this page has not seen: after the first `from` of the
    // cycle it has (a few hundred bytes every 2 s, however many targets).
    const since = live ? `?cycle=${live.cycle}&from=${live.probes.length}` : "";
    const res = await fetch(`api/live${since}`, { cache: "no-store" });
    if (!res.ok) throw new Error(res.statusText);
    const next = await res.json();
    if (next.from > 0) {
      if (!live || next.cycle !== live.cycle || next.from !== live.probes.length) {
        live = null; // out of step: the next poll asks for everything
        return;
      }
      next.probes = live.probes.concat(next.probes);
    }
    live = next;
    liveById = new Map();
    for (const p of live.probes) {
      if (!liveById.has(p[0])) liveById.set(p[0], []);
      liveById.get(p[0]).push(p);
    }
    skew = live.now - Date.now();
    heard();
    // A recorded cycle, a changed target, a new cycle: the state has it.
    // (A new cycle by the clock too: with every target paused no cycle runs.)
    const cycle = Math.floor(serverNow() / 1000 / state?.cycle_s) * state?.cycle_s;
    if (!state || live.version !== state.version || live.cycle > state.end || cycle > state.end) await load();
    else updateLive();
  } catch (err) {
    lost(err);
  } finally {
    livePolling = false;
  }
}

function heard() {
  lastHeard = Date.now();
  if (!online) {
    online = true;
    tick();
  }
  $("#updated").textContent = `Updated ${new Date().toLocaleTimeString()}`;
}
function lost(err) {
  online = false;
  tick();
  $("#updated").textContent = `Cannot reach the server (${err.message}), retrying…`;
}

// What a new state changed, for the animations: the series moved on by a
// cycle (`shift`), a target's newest cycle was recorded (`arrive`), a
// target's status changed (`flash`, to the new status's colour).
function changesSince(before, now) {
  const old = new Map(before.targets.map((t) => [t.id, t]));
  const arrive = new Set(), flash = new Map();
  const shift = now.end !== before.end;
  for (const t of now.targets) {
    const o = old.get(t.id);
    if (!o) continue;
    const last = t.loss.length - 1;
    if (t.loss[last] !== null && (shift || o.loss[last] === null)) arrive.add(t.id);
    if (statusOf(o) !== statusOf(t) && t.status !== "pending") flash.set(t.id, STATUS[statusOf(t)][1]);
  }
  return { shift, arrive, flash };
}

// A read-only demo shows every control, so it looks like the real thing;
// using one explains instead of failing (the server refuses anyway).
const DEMO_NOTE = "This is a read-only demo: changes are disabled. Install zpinger to manage your own targets.";

async function call(method, path, body) {
  if (state.read_only) throw new Error(DEMO_NOTE);
  const res = await fetch(path, {
    method,
    headers: { "content-type": "application/json" },
    body: body ? JSON.stringify(body) : "{}",
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  await load();
  return data;
}

// ----- rendering ---------------------------------------------------------------

// `anim`: what changed since the last state (changesSince), when a new state
// came; any other redraw (a filter, an editor) animates nothing.
function render(anim) {
  $("#mode").hidden = !state.read_only;

  const hour = 3600 / state.cycle_s;
  const stats = new Map(state.targets.map((t) => [t.id, { day: summarize(t), hour: summarize(t, hour) }]));
  renderTab(stats);
  // The pills count what the tags and the search leave, like the facets of
  // a shop's search: with a tag selected they show that tag's health.
  const base = state.targets.filter(matches);
  renderPills(base, stats);
  const shown = sortTargets(base.filter((t) => inPills(t, stats.get(t.id))), stats);
  renderToolbar(shown.length);
  renderFeed(shown);

  // A re-render gives the focus back to the control of a row that had it
  // (an editor's field with its caret, an edit button), marked data-focus.
  const active = document.activeElement;
  const row = active && active.dataset.focus && active.closest("[data-target]");
  const refocus = row && { id: row.dataset.target, key: active.dataset.focus, caret: active.tagName === "INPUT" ? [active.selectionStart, active.selectionEnd] : null };

  // Swapping the list collapses the page for a moment, and the browser clamps
  // the scroll position to the shorter page: a reader scrolled down would land
  // at the top. Expanded details are filled in the same task (their chart
  // needs the attached width) and the position is put back before any paint.
  const y = window.scrollY;
  const list = $("#targets");
  const expand = [];
  list.replaceChildren(...shown.map((t) => renderTarget(t, stats.get(t.id).day, expand, anim)));
  // The beat strips once the rows are in the page: how many beats fit
  // depends on the width each one got.
  for (const t of shown) renderBeats($(`[data-target="${t.id}"] .beats`, list), t, anim);
  if (state.targets.length === 0) list.append(el("p", "empty", "No targets yet."));
  else if (shown.length === 0) {
    const p = el("p", "empty", "No target matches the filter. ");
    const clear = el("button", "link", "Show all");
    clear.type = "button";
    clear.addEventListener("click", clearFilter);
    p.append(clear);
    list.append(p);
  }
  for (const show of expand) show();
  renderAddTags();
  placePicker();
  renderLine();
  if (refocus) focusRow(refocus.id, refocus.key, refocus.caret);
  if (window.scrollY !== y) window.scrollTo(0, y);
}

// ----- live: the cycle being probed ----------------------------------------------

// The probes of target `t` in the cycle being probed, in order, [id, ms, rtt].
const liveProbes = (t) => (live && state && live.cycle === state.end ? liveById.get(t.id) || [] : []);

// The newest cycle is not recorded yet, and this one is probing it: its
// beat is built from the probes so far.
// A target added (or moved, or resumed) after the cycle started is not in
// it: its first beat waits for the next cycle.
const showsLive = (t) =>
  !t.paused && t.loss[t.loss.length - 1] === null && live !== null && live.cycle === state.end && live.targets.includes(t.id);

function liveBeat(t) {
  const b = el("span", "beat live");
  for (let i = 0; i < state.probes; i++) b.append(el("i"));
  fillLive(b, t, false);
  return b;
}

function fillLive(b, t, fresh) {
  const probes = liveProbes(t);
  const segs = b.children;
  probes.slice(0, segs.length).forEach((p, i) => {
    const cls = p[2] === null ? "lost" : "ok";
    // A segment just filled flashes once.
    if (segs[i].className !== cls) segs[i].className = fresh ? `${cls} fresh` : cls;
  });
  const answered = probes.filter((p) => p[2] !== null).length;
  b.title = `${time(state.end)} · this cycle so far: ${probes.length} of ${state.probes} probes, ${answered} answered`;
}

// The newest round-trip time: this cycle's last answer, else the last cycle's.
function latencyOf(t, s) {
  if (t.paused) return null;
  const answered = liveProbes(t).filter((p) => p[2] !== null);
  return answered.length ? answered[answered.length - 1][2] : s.last;
}

// A /api/live answer that changed nothing in the state: fill the live
// beats and the latency figures in place, no redraw.
function updateLive() {
  for (const row of document.querySelectorAll("#targets .target")) {
    const t = state.targets.find((x) => x.id === Number(row.dataset.target));
    if (!t) continue;
    const beats = $(".beats", row);
    const b = $(".beat.live", beats);
    if (showsLive(t) !== !!b) renderBeats(beats, t, null);
    else if (b) fillLive(b, t, true);
    const lat = $(".latency", row);
    const text = ms(latencyOf(t, { last: summarize(t, 1).last }));
    if (lat.textContent !== text) {
      lat.textContent = text;
      lat.classList.remove("fresh");
      void lat.offsetWidth; // restart the animation
      lat.classList.add("fresh");
    }
  }
  renderLine();
}

// The line along the bottom of the bar: the probing window of this cycle,
// left to right; every probe, as it comes, colours the stretch since the one
// before it (green answered, red lost), so by the end of the window the line
// is full. A faint stretch runs from the last probe to now.
let lineStops = "", lineLast = 0;
function renderLine() {
  if (!state || !live || live.cycle !== state.end) {
    lineStops = "";
    lineLast = 0;
  } else {
    // The last probe goes out 2 s before the next cycle (doc/how-it-works.md).
    const span = state.cycle_s * 1000 - 2000;
    const pct = (ms) => Math.min(100, (100 * ms) / span);
    // Runs of one colour are one stretch: a few stops even for a thousand
    // probes a cycle.
    let prev = 0, start = 0, color = null;
    const stops = [];
    const flush = () => color && stops.push(`${color} ${start.toFixed(2)}% ${prev.toFixed(2)}%`);
    for (const [, at, rtt] of live.probes) {
      const c = rtt === null ? "var(--down)" : "var(--up)";
      if (c !== color) {
        flush();
        color = c;
        start = prev;
      }
      prev = Math.max(prev, pct(at));
    }
    flush();
    lineStops = stops.join(", ");
    lineLast = prev;
  }
  tickLine();
}

function tickLine() {
  const line = $("#line");
  if (!state) return;
  const now = serverNow();
  const span = state.cycle_s * 1000 - 2000;
  const cycleStart = Math.floor(now / (state.cycle_s * 1000)) * state.cycle_s * 1000;
  const head = Math.max(lineLast, Math.min(100, (100 * (now - cycleStart)) / span));
  const faint = "color-mix(in srgb, var(--accent) 35%, transparent)";
  const parts = [lineStops, `${faint} ${lineLast.toFixed(2)}% ${head.toFixed(1)}%`, `transparent ${head.toFixed(1)}% 100%`].filter(Boolean);
  const bg = online ? `linear-gradient(90deg, ${parts.join(", ")})` : "";
  if (bg !== lineBg) line.style.backgroundImage = lineBg = bg;
  line.classList.toggle("offline", !online);
}

let lineBg = null;
const serverNow = () => Date.now() + skew;

// The logo's ring counts down to the next cycle, like a clock's hand; grey
// while the server does not answer.
function tick() {
  if (!state) return;
  const cycle = state.cycle_s * 1000;
  const into = serverNow() % cycle;
  const left = 100 * (1 - into / cycle);
  const ring = $("#ring");
  ring.style.strokeDasharray = `${left.toFixed(2)} 100`;
  ring.style.strokeDashoffset = `${(-(100 - left)).toFixed(2)}`;
  const logo = $("#logo");
  logo.classList.toggle("offline", !online);
  const ago = Math.round((Date.now() - lastHeard) / 1000);
  const label = online
    ? `Probing: next cycle in ${Math.ceil((cycle - into) / 1000)} s, updated ${ago} s ago`
    : `Cannot reach the server since ${ago} s; retrying`;
  if (logo.title !== label) {
    logo.title = label;
    logo.setAttribute("aria-label", label);
  }
  tickLine();
}

// The tab's title and icon: how many targets need attention, in the colour
// of the worst status, so a tab in the background still tells.
let favColor = null;
function renderTab(stats) {
  let nok = 0;
  for (const t of state.targets) if (healthOf(t, stats.get(t.id)) === "nok") nok++;
  const st = state.targets.map(statusOf);
  const color = st.includes("down") ? "down" : st.includes("degraded") || nok ? "warn" : st.includes("up") ? "up" : "idle";
  document.title = nok ? `(${nok}) zpinger` : "zpinger";
  if (color === favColor) return;
  favColor = color;
  // Served in each colour (the content security policy allows no data: icon).
  $("#favicon").href = `favicon-${color}.svg`;
}

// ----- events: problems of the last 24 hours ----------------------------------------
//
// Read from the series the page already has. An event is a run of cycles
// that lost probes; up to 5 clean cycles inside it do not end it, so an
// outage with its warning signs (cycles that lose some probes, then all) is
// one event, not a dozen. It is a DOWN event when some of its cycles lost
// every probe. One cycle that lost one probe is noise, not an event: it needs
// 2 lossy cycles, or 40 % in one. Cycles without data neither end nor extend
// an event.

const LOSS_GAP = 5;

function episodes(t) {
  const n = t.loss.length;
  const at = (i) => state.end - (n - 1 - i) * state.cycle_s;
  let newest = -1;
  for (let i = n - 1; i >= 0 && newest < 0; i--) if (t.loss[i] !== null) newest = i;
  const out = [];
  let cur = null, clean = 0;
  const close = () => {
    if (cur && (cur.down > 0 || cur.cycles >= 2 || cur.peak >= 40)) {
      cur.kind = cur.down > 0 ? "down" : "loss";
      cur.from = at(cur.first);
      cur.to = at(cur.last) + state.cycle_s;
      // Still going: it reaches the newest data, and that is from now (not
      // from before a pause, or before the daemon stopped).
      cur.ongoing = cur.last === newest && !t.paused && at(newest) >= state.end - 2 * state.cycle_s;
      cur.sample = isSample(t, cur.from);
      out.push(cur);
    }
    cur = null;
  };
  for (let i = 0; i < n; i++) {
    const v = t.loss[i];
    if (v === null) continue;
    if (v === 0) {
      if (cur && ++clean > LOSS_GAP) close();
      continue;
    }
    clean = 0;
    if (!cur) cur = { t, first: i, cycles: 0, down: 0, peak: 0 };
    cur.last = i;
    cur.cycles++;
    if (v === 100) cur.down++;
    cur.peak = Math.max(cur.peak, v);
  }
  close();
  return out;
}

const minutes = (s) => {
  const m = Math.max(1, Math.round(s / 60));
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}`;
};

function eventLine(e, withName) {
  const li = el("li", e.sample ? "sample" : null);
  li.style.setProperty("--c", e.kind === "down" ? "var(--down)" : "var(--warn)");
  const when = e.ongoing ? `since ${time(e.from)}` : `${time(e.from)}–${time(e.to)}`;
  const down = minutes(e.down * state.cycle_s), span = minutes(e.to - e.from);
  const what = e.kind === "loss" ? `lost up to ${e.peak} % of probes over ${span}`
    : e.down === e.cycles ? `DOWN for ${down}` : `DOWN for ${down}, losing probes over ${span}`;
  const text = el("span", "what");
  if (withName) {
    const name = el("button", "link", e.t.name);
    name.type = "button";
    name.title = "Show this target";
    name.addEventListener("click", () => showTarget(e.t.id));
    text.append(name, " ");
  }
  text.append(what);
  if (e.sample) text.append(el("span", "tag", "sample data"));
  li.append(el("time", null, when), el("span", "dot"), text);
  return li;
}

// The list of `events`, the newest (the latest to start) on top, or why it
// is empty.
function fillFeed(events, withName, empty) {
  events.sort((a, b) => b.from - a.from || b.to - a.to);
  const list = el("ol");
  for (const e of events) list.append(eventLine(e, withName));
  if (!events.length) list.append(el("li", "none", empty));
  return list;
}

// The global feed: the events of the targets the list shows.
let feedOpen = false;
function renderFeed(shown) {
  const box = $("#feed");
  box.hidden = !feedOpen;
  $("#events").setAttribute("aria-expanded", String(feedOpen));
  if (!feedOpen) return;
  const head = el("div", "feed-head");
  head.append(el("b", null, "Events"), el("span", "note", filtered() ? `last 24 hours, the ${shown.length} targets shown` : "last 24 hours"));
  head.title = "Runs of cycles that lost probes (DOWN: some lost every probe); a single cycle that lost one probe is left out";
  box.replaceChildren(head, fillFeed(shown.flatMap(episodes), true, "Nothing went wrong."));
}

function showTarget(id) {
  view.open.add(id);
  saveView();
  render();
  $(`[data-target="${id}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" });
}

// The per-target feed in a row's detail; open ones are remembered.
const rowFeeds = new Set();
function renderRowFeed(box, t) {
  box.hidden = !rowFeeds.has(t.id);
  if (box.hidden) return box.replaceChildren();
  const head = el("div", "feed-head");
  head.append(el("b", null, "Events"), el("span", "note", "last 24 hours"));
  box.replaceChildren(head, fillFeed(episodes(t), false, "Nothing went wrong."));
}

function focusRow(id, key, caret) {
  const e = $(`[data-target="${id}"] [data-focus="${key}"]`);
  if (!e) return;
  e.focus({ preventScroll: true });
  if (caret) e.setSelectionRange(...caret);
}

// ----- filter and order ----------------------------------------------------------

const filtered = () => view.tags.size > 0 || view.q !== "" || view.st.size > 0;

// ok, nok or neither: the first tiers of problems first need attention;
// acknowledged, pending and paused targets are neither.
function healthOf(t, st) {
  const tier = problemTier(t, st);
  return tier <= 2 ? "nok" : tier === 3 || tier === 5 ? "ok" : null;
}

// In one of the selected pills (none selected: every target).
const inPills = (t, st) => view.st.size === 0 || view.st.has(statusOf(t)) || view.st.has(healthOf(t, st));

function renderPills(base, stats) {
  const counts = Object.fromEntries(Object.keys(PILLS).map((k) => [k, 0]));
  for (const t of base) {
    counts[statusOf(t)]++;
    const h = healthOf(t, stats.get(t.id));
    if (h) counts[h]++;
  }
  // Every pill in the unfolded bar; the health ones also in its first line,
  // shown while it is folded.
  const bar = $("#summary"), health = $("#health");
  bar.replaceChildren();
  health.replaceChildren();
  for (const [key, [label, color, hint]] of Object.entries(PILLS)) {
    const on = view.st.has(key);
    const pill = () => {
      const p = el("button", `pill${counts[key] ? "" : " zero"}${HEALTH.includes(key) ? " health" : ""}`, `${counts[key]} ${label}`);
      p.type = "button";
      p.style.setProperty("--c", color);
      p.setAttribute("aria-pressed", String(on));
      p.title = `${hint}. Click to ${on ? "stop showing only these" : "show only these"}; several pills show any of them.`;
      p.addEventListener("click", () => setView(() => (on ? view.st.delete(key) : view.st.add(key))));
      return p;
    };
    bar.append(pill());
    if (HEALTH.includes(key)) health.append(pill());
    if (key === HEALTH[HEALTH.length - 1]) bar.append(el("span", "pill-sep"));
  }
}

// Every selected tag, and every word of the search somewhere in the name, the
// host or a tag.
function matches(t) {
  for (const tag of view.tags) if (!t.tags.includes(tag)) return false;
  const hay = [t.name, t.host, ...t.tags].map((s) => s.toLowerCase());
  return view.q.toLowerCase().split(/\s+/).filter(Boolean).every((w) => hay.some((h) => h.includes(w)));
}

// A window had a problem when it lost this much on average (percent), or its
// mean jitter reached this (milliseconds): how much, not whether at all, so
// one lost probe in an hour is not a problem.
const LOSS_WARN_PCT = 1;
const JITTER_WARN_MS = 10;
const troubled = (s) => s.loss >= LOSS_WARN_PCT || s.jitter >= JITTER_WARN_MS;

// Problems first, the most urgent on top: DOWN, LOSS now, a problem in the
// last hour, one in the last 24 hours, an acknowledged outage (known, so
// below the unknown ones), then the rest.
function problemTier(t, st) {
  switch (statusOf(t)) {
    case "down": return 0;
    case "degraded": return 1;
    case "acked": return 4;
    case "pending": return 6;
    case "paused": return 7;
  }
  return troubled(st.hour) ? 2 : troubled(st.day) ? 3 : 5;
}
// Within a tier: more loss, then more jitter; the last hour weighs first.
const severity = (st) => [st.hour.loss, st.hour.jitter, st.day.loss, st.day.jitter].map((v) => v ?? 0);

const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });

// Each order has a natural direction (problems first, A to Z, the worst
// figure first); `rev` turns it around. Targets without data go last either
// way, and ties keep name order.
function sortTargets(list, stats) {
  const dir = view.rev ? -1 : 1;
  const m = /^(loss|jitter|avg|max)(1h|24h)$/.exec(view.sort);
  const cmp = (a, b) => {
    const sa = stats.get(a.id), sb = stats.get(b.id);
    if (m) {
      const win = WINDOWS[m[2]][2];
      const x = sa[win][m[1]], y = sb[win][m[1]];
      // Times dir, so the reversal below cancels out: no data stays last.
      if (x === null || y === null) return ((x === null) - (y === null)) * dir;
      return y - x;
    }
    if (view.sort === "status") {
      const d = problemTier(a, sa) - problemTier(b, sb);
      if (d) return d;
      const va = severity(sa), vb = severity(sb);
      for (let i = 0; i < va.length; i++) if (va[i] !== vb[i]) return vb[i] - va[i];
    }
    return 0;
  };
  return list.sort((a, b) => dir * cmp(a, b) || (view.sort === "name" ? dir : 1) * byName(a, b));
}

function setView(change) {
  change();
  saveView();
  if (state) render();
}

function clearFilter() {
  setView(() => {
    view.tags.clear();
    view.st.clear();
    view.q = "";
    $("#find").value = "";
  });
}

// The tag chips (every tag in use, plus a selected one no target has any
// more, so it can be unselected), the order button and the match count.
function renderToolbar(count) {
  const all = new Set(state.targets.flatMap((t) => t.tags));
  for (const tag of view.tags) all.add(tag);
  const bar = $("#tagbar");
  bar.replaceChildren();
  for (const tag of [...all].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))) {
    const chip = el("button", "chip", tag);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(view.tags.has(tag)));
    chip.title = view.tags.has(tag) ? "Stop filtering by this tag" : "Show only targets with this tag";
    chip.addEventListener("click", () => setView(() => (view.tags.has(tag) ? view.tags.delete(tag) : view.tags.add(tag))));
    bar.append(chip);
  }
  bar.hidden = all.size === 0;

  const order = $("#order");
  const [fwd, back] = {
    status: ["problems first", "OK first"],
    name: ["A to Z", "Z to A"],
  }[view.sort] || ["highest first", "lowest first"];
  order.textContent = view.rev ? "↑" : "↓";
  order.title = `Order: ${view.rev ? back : fwd} (click: ${view.rev ? fwd : back})`;
  order.setAttribute("aria-label", order.title);

  // In the unfolded bar, and in its first line while folded (the filters
  // are out of sight then, and the list is shorter than it seems).
  for (const note of [$("#shown"), $("#shown-mini")]) {
    note.replaceChildren();
    if (!filtered()) continue;
    note.append(`${count} of ${state.targets.length} shown `);
    const clear = el("button", "link", "clear");
    clear.type = "button";
    clear.addEventListener("click", clearFilter);
    note.append(clear);
  }
}

// expand collects the detail renderers of expanded targets; render() calls
// them once the row is in the page.
function renderTarget(t, s, expand, anim) {
  const node = $("#row").content.firstElementChild.cloneNode(true);
  node.dataset.target = t.id;
  const [label, color] = STATUS[statusOf(t)];
  // A new status: the row flashes in its colour.
  if (anim && anim.flash.has(t.id)) {
    node.classList.add("flash");
    node.style.setProperty("--fc", color);
  }

  const badge = $(".badge", node);
  badge.textContent = label;
  badge.style.setProperty("--c", color);
  const head = $(".head", node);
  const who = $(".who", node);
  if (renaming && renaming.id === t.id) {
    head.classList.add("editing");
    who.replaceChildren(renderRenameEditor(t));
  } else {
    $(".name", node).textContent = t.name;
    $(".host", node).textContent = t.host;
    $(".edit-target", node).addEventListener("click", () => openRename(t));
    renderTagLine($(".tagline", node), t);
    if (rowNote && rowNote.id === t.id) who.append(el("span", "row-note", rowNote.text));
  }
  $(".uptime", node).textContent = s.uptime === null ? "–" : `${s.uptime.toFixed(s.uptime === 100 ? 0 : 2)} %`;
  $(".latency", node).textContent = ms(latencyOf(t, s));

  const expandButton = $(".expand", node);
  expandButton.setAttribute("aria-label", `${t.name}: chart, figures and actions`);
  const detail = $(".detail", node);
  const toggle = (show) => {
    detail.hidden = !show;
    expandButton.setAttribute("aria-expanded", String(show));
    if (show) renderDetail(detail, t, s);
    else stopTrace(t.id);
  };
  // A click anywhere in the head expands the row, except on its editors.
  // They stop the click themselves: by the time it would get here, they may
  // have redrawn the row, and the clicked element is no longer in it.
  for (const e of node.querySelectorAll(".edit-btn")) e.addEventListener("click", (ev) => ev.stopPropagation());
  head.addEventListener("click", () => {
    if (view.open.has(t.id)) view.open.delete(t.id);
    else view.open.add(t.id);
    saveView();
    toggle(view.open.has(t.id));
  });
  if (view.open.has(t.id)) expand.push(() => toggle(true));
  return node;
}

// The last cycles, one beat each; the newest, while it is being probed, is
// built from its probes so far (see liveBeat). On a new cycle the strip
// slides left by one beat; a beat just recorded arrives.
function renderBeats(box, t, anim) {
  // As many recent cycles as fit (the strip is in the page by now); refit
  // on resize via render().
  const width = box.clientWidth || Math.min(window.innerWidth - 80, 540);
  const n = Math.max(10, Math.min(90, Math.floor(width / BEAT_PX)));
  const last = t.loss.length - 1;
  box.replaceChildren();
  for (let i = t.loss.length - n; i < t.loss.length; i++) {
    if (i === last && showsLive(t)) {
      box.append(liveBeat(t));
      continue;
    }
    const b = el("span", "beat");
    const c = beatColor(t.loss[i]);
    if (c) b.style.setProperty("--c", c);
    b.dataset.i = i; // its tooltip is written when the pointer reaches it
    if (i === last && anim && anim.arrive.has(t.id)) b.classList.add("arrive");
    box.append(b);
  }
  box.classList.toggle("slide", !!(anim && anim.shift));
}

function renderDetail(detail, t, s) {
  renderChart($(".chart", detail), t);

  const stats = $(".stats", detail);
  stats.replaceChildren();
  const stat = (name, value) => {
    const d = el("div", null, name);
    d.prepend(el("b", null, value));
    stats.append(d);
  };
  stat("current", s.lastJitter === null ? ms(s.last) : `${ms(s.last)} ± ${ms(s.lastJitter)}`);
  stat("average (24 h)", ms(s.avg));
  stat("95th percentile (24 h)", ms(s.p95));
  stat("jitter (24 h)", ms(s.jitter));
  stat("best / worst", `${ms(s.min)} / ${ms(s.max)}`);
  stat("packet loss (24 h)", s.loss === null ? "–" : `${s.loss.toFixed(2)} %`);
  stat("uptime (24 h)", s.uptime === null ? "–" : `${s.uptime.toFixed(2)} %`);
  if (t.acked) stat("acknowledged", `clears after ${state.ack_clear_after - t.ok_streak} more good cycles`);
  if (t.error) stat("last error", t.error);
  // A name: the address it resolved to (kept for the DNS answer's TTL).
  if (t.address && t.address !== t.host) stat("address", t.address);
  if (t.dns === "stale") stat("DNS", "not answering; probing the last known address");


  const actions = $(".actions", detail);
  actions.replaceChildren();
  const note = el("span", "note");
  const action = (text, hint, fn, cls) => {
    const b = el("button", cls, text);
    b.type = "button";
    b.title = hint;
    b.addEventListener("click", async () => {
      b.disabled = true;
      note.textContent = "";
      try {
        if ((await fn()) === false) b.disabled = false; // confirm() cancelled
      } catch (err) {
        note.textContent = err.message;
        b.disabled = false;
      }
    });
    actions.append(b);
  };
  const base = `api/targets/${t.id}`;
  const feed = $(".row-feed", detail);
  renderRowFeed(feed, t);
  const events = el("button", null, rowFeeds.has(t.id) ? "Hide events" : "Events");
  events.type = "button";
  events.title = "This target's problems of the last 24 hours: DOWN, and loss of probes";
  events.setAttribute("aria-expanded", String(rowFeeds.has(t.id)));
  events.addEventListener("click", () => {
    if (rowFeeds.has(t.id)) rowFeeds.delete(t.id);
    else rowFeeds.add(t.id);
    renderRowFeed(feed, t);
    events.textContent = rowFeeds.has(t.id) ? "Hide events" : "Events";
    events.setAttribute("aria-expanded", String(rowFeeds.has(t.id)));
  });
  actions.append(events);
  renderTrace($(".trace", detail), t);
  if (!traces.has(t.id))
    action("Trace route", "Show the path to this host live, hop by hop, like mtr: one probe to every hop each second, with loss and latency per hop", () => startTrace(t));
  if (t.paused) action("Resume", "Start probing this target again", () => call("POST", `${base}/resume`));
  else action("Pause", "Stop probing this target, e.g. during maintenance; the history is kept", () => call("POST", `${base}/pause`));
  if (t.status === "down" && !t.acked)
    action("Acknowledge", `Mark this outage as known: the target shows ACK instead of DOWN until ${state.ack_clear_after} cycles in a row are not DOWN`, () => call("POST", `${base}/ack`));
  if (t.acked) action("Remove acknowledgement", "Show this target as DOWN again", () => call("POST", `${base}/unack`));
  action("Remove", "Stop monitoring this target and delete its history",
    () => (state.read_only || confirm(`Remove ${t.name}?`)) && call("DELETE", base).then(() => view.open.delete(t.id)), "danger");
  actions.append(note);
}

// ----- live trace ---------------------------------------------------------------------
//
// The server runs at most a few traces, one per host, shared by every viewer,
// at most two per viewer, and stops one nobody polls for 30 s. The page polls
// the open ones every second, and not at all while hidden; Stop only ends
// this page's watching (the trace goes on for other viewers).

const traces = new Map(); // target id -> { data, stopped, error }
let traceTimer = null;
let tracePolling = false;

// Seconds as the server's limits are set: "60 s", "10 min", "1 h".
const duration = (s) => (s % 60 ? `${s} s` : s % 3600 ? `${s / 60} min` : `${s / 3600} h`);

// Why a trace stopped; `d` is its last data (the limits come with it).
function traceReason(reason, d) {
  const texts = {
    idle: `stopped: nobody watched it for ${duration(d?.idle ?? 60)}`,
    max_age: `stopped after ${duration(d?.max_age ?? 600)}`,
    stopped: "stopped",
    unresolved: "stopped: the host name does not resolve",
    no_socket: "stopped: the server cannot open an ICMP socket",
    failed: "stopped: probing failed",
  };
  return texts[reason] || "stopped";
}

async function traceCall(method, t) {
  const res = await fetch(`api/targets/${t}/trace`, { method, headers: { "content-type": "application/json" }, body: method === "GET" ? undefined : "{}" });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || res.statusText), { status: res.status });
  return data;
}

async function startTrace(t) {
  await traceCall("POST", t.id);
  traces.set(t.id, { data: null, stopped: null, error: null });
  pollTraces();
  render();
}

function stopTrace(id) {
  if (!traces.has(id)) return;
  traces.delete(id);
  traceCall("DELETE", id).catch(() => {});
  if (traces.size === 0) {
    clearInterval(traceTimer);
    traceTimer = null;
  }
}

async function pollTraces() {
  if (traceTimer === null) traceTimer = setInterval(pollTraces, 1000);
  if (document.hidden || tracePolling) return;
  tracePolling = true;
  try {
    await pollTracesOnce();
  } finally {
    tracePolling = false;
  }
}

async function pollTracesOnce() {
  for (const [id, tr] of traces) {
    if (tr.stopped) continue;
    try {
      tr.data = await traceCall("GET", id);
      tr.error = null;
      if (tr.data.state !== "running") tr.stopped = traceReason(tr.data.reason, tr.data);
    } catch (err) {
      if (err.status === 404) tr.stopped = traceReason("idle", tr.data);
      else if (err.status === 429 || err.status === 503) tr.stopped = `stopped: ${err.message}`;
      else tr.error = `Cannot reach the server (${err.message}), retrying…`;
    }
    const panel = $(`[data-target="${id}"] .trace`);
    const t = state.targets.find((x) => x.id === id);
    // Someone selecting text in the table: keep it still (the data moves on).
    if (panel && t && !selectingIn(panel)) renderTrace(panel, t);
  }
}

const selectingIn = (node) => {
  const sel = document.getSelection();
  return !!sel && !sel.isCollapsed && sel.rangeCount > 0 && node.contains(sel.getRangeAt(0).commonAncestorContainer);
};

// The clipboard API needs a secure context (https, localhost); a plain-http
// address on the LAN gets the old execCommand path.
async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {}
  }
  const ta = el("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.cssText = "position:fixed;top:0;left:0;opacity:0";
  document.body.append(ta);
  ta.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch {}
  ta.remove();
  return ok;
}

// The trace as plain text, like `mtr --report`: one line per hop, further
// responders of a load-balanced hop on lines of their own.
function traceText(t, d) {
  const pct = (p) => `${(p / 10).toFixed(1)}%`;
  const rows = [["#", "Host", "Loss", "Sent", "Last", "Avg", "Best", "Worst", "Jitter"]];
  for (const h of d.hops) {
    const names = h.hosts.length ? h.hosts.map((a, i) => (h.names?.[i] ? `${a} ${h.names[i]}` : a)) : ["???"];
    rows.push([String(h.ttl), names[0], pct(h.loss), String(h.sent), ...["last", "avg", "best", "worst", "jitter"].map((k) => usMs(h[k]))]);
    for (const n of names.slice(1)) rows.push(["", n, "", "", "", "", "", "", ""]);
  }
  const width = rows[0].map((_, c) => Math.max(...rows.map((r) => r[c].length)));
  const lines = rows.map((r) => r.map((v, c) => (c === 1 ? v.padEnd(width[c]) : v.padStart(width[c]))).join("  ").trimEnd());
  const when = new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC";
  return `Route to ${d.address || t.host} (${t.host}), ${d.rounds} rounds, ${when}\n` + lines.join("\n") + "\n";
}

// Shows "copied" on the thing just copied, across the per-second rebuilds.
function flashCopied(tr, key, panel, t) {
  tr.copied = { key, until: Date.now() + 1500 };
  renderTrace(panel, t);
  setTimeout(() => {
    if (tr.copied?.key === key && Date.now() >= tr.copied.until && !selectingIn(panel)) renderTrace(panel, t);
  }, 1600);
}
const isCopied = (tr, key) => tr.copied?.key === key && Date.now() < tr.copied.until;

const usMs = (v) => (v === null ? "–" : v < 10000 ? (v / 1000).toFixed(2) : (v / 1000).toFixed(1));

function renderTrace(panel, t) {
  const tr = traces.get(t.id);
  panel.hidden = !tr;
  if (!tr) return panel.replaceChildren();
  const d = tr.data;
  const head = el("div", "trace-head");
  const title = el("b", null, `Route to ${d && d.address ? d.address : t.host}`);
  head.append(title);
  const facts = [];
  if (d) {
    facts.push(`${d.rounds} round${d.rounds === 1 ? "" : "s"}`);
    if (d.hops.length) facts.push(d.reached ? `destination at hop ${d.hops.length}` : "destination not reached");
  } else facts.push("starting…");
  if (tr.stopped) facts.push(tr.stopped);
  if (tr.error) facts.push(tr.error);
  head.append(el("span", "note", facts.join(" · ")));
  const again = el("button", null, tr.stopped ? "Run again" : "Stop");
  again.type = "button";
  again.addEventListener("click", async () => {
    if (!tr.stopped) {
      stopTrace(t.id);
      return render();
    }
    try {
      await traceCall("POST", t.id);
      traces.set(t.id, { data: null, stopped: null, error: null });
      renderTrace(panel, t);
    } catch (err) {
      tr.error = err.message;
      renderTrace(panel, t);
    }
  });
  if (d && d.hops.length) {
    const copy = el("button", isCopied(tr, "table") ? "copied" : null, isCopied(tr, "table") ? "Copied ✓" : "Copy");
    copy.type = "button";
    copy.title = "Copy the whole table as text (a click on an address copies just that address)";
    copy.addEventListener("click", async () => {
      if (await copyText(traceText(t, tr.data))) flashCopied(tr, "table", panel, t);
    });
    head.append(copy);
  }
  head.append(again);

  const table = el("table", "hops");
  const cols = [["#", "Hop: the TTL of the probe"], ["Host", "Who answered at this hop, address and reverse-DNS name (several: a load-balanced hop)"], ["Last 60 s", "One bar per round, the height is the round-trip time; red: no answer"], ["Loss", "Probes without an answer. Grey: loss the later hops do not show, the router limiting its answers rather than loss on the path"], ["Sent", "Probes sent to this hop"], ["Last", "Round-trip time of the last answer, ms"], ["Avg", "Average round-trip time, ms"], ["Best", "Best round-trip time, ms"], ["Worst", "Worst round-trip time, ms"], ["Jitter", "Mean change between consecutive round-trip times, ms"]];
  const hr = el("tr");
  for (const [name, hint] of cols) {
    const th = el("th", null, name);
    th.title = hint;
    hr.append(th);
  }
  table.append(hr);
  const hops = d ? d.hops : [];
  hops.forEach((h, idx) => {
    const row = el("tr");
    const host = el("td", "hop-host");
    if (h.hosts.length)
      host.append(
        // Address first, then the name, cut with an ellipsis (the whole in the tooltip).
        ...h.hosts.map((a, i) => {
          const name = h.names?.[i];
          const s = el("span", "hop-addr");
          const key = `ip ${h.ttl} ${a}`;
          const ip = el("span", isCopied(tr, key) ? "ip copied" : "ip", a);
          ip.tabIndex = 0;
          ip.setAttribute("role", "button");
          const copyIp = async (ev) => {
            ev.preventDefault();
            if (await copyText(a)) flashCopied(tr, key, panel, t);
          };
          ip.addEventListener("click", copyIp);
          ip.addEventListener("keydown", (ev) => {
            if (ev.key === "Enter" || ev.key === " ") copyIp(ev);
          });
          s.append(ip);
          if (name) s.append(" ", el("span", "name", name));
          s.title = `${name ? `${a} ${name}` : a}\n${isCopied(tr, key) ? "Copied" : "Click the address to copy it"}`;
          return s;
        }),
      );
    else host.append(el("span", "muted", "no answer"));
    const spark = el("td", "spark");
    spark.append(renderSpark(h.spark));
    // Loss that the hops after this one do not show is the router limiting
    // its ICMP answers, not loss on the path (as mtr reads it): grey, not red.
    const later = hops.slice(idx + 1).filter((x) => x.sent > 0);
    const pathLoss = later.length ? Math.min(...later.map((x) => x.loss)) : h.loss;
    const limited = h.loss >= 10 && pathLoss < h.loss;
    const loss = el("td", limited ? "num limited" : h.loss >= 10 ? "num bad" : "num", h.sent ? `${(h.loss / 10).toFixed(h.loss % 10 ? 1 : 0)} %` : "–");
    if (limited)
      loss.title = `This router answers only some probes: it limits its ICMP answers. The hops after it lose ${(pathLoss / 10).toFixed(pathLoss % 10 ? 1 : 0)} %, so the path itself does not lose this much.`;
    if (h.code !== null) loss.title = `Destination Unreachable, code ${h.code}`;
    const ttl = el("td", h.shared ? "num shared" : "num", String(h.ttl));
    if (h.shared) ttl.title = "Shared with other live traces: their paths cross this router, and one probe a second measures it for all of them";
    row.append(ttl, host, spark, loss, el("td", "num", String(h.sent)));
    for (const k of ["last", "avg", "best", "worst", "jitter"]) row.append(el("td", "num", usMs(h[k])));
    table.append(row);
  });
  // The panel is rebuilt every second (and on every page render): keep the
  // horizontal scroll position the viewer chose on a narrow screen.
  const wrap = el("div", "hops-wrap");
  wrap.append(table);
  wrap.addEventListener("scroll", () => (tr.scrollLeft = wrap.scrollLeft), { passive: true });
  panel.replaceChildren(head, wrap);
  if (tr.scrollLeft) wrap.scrollLeft = tr.scrollLeft;
}

function renderSpark(values) {
  const W = 120, H = 18, n = 60, bw = W / n;
  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, "aria-hidden": "true" });
  const max = Math.max(1, ...values.filter((v) => v !== null));
  values.forEach((v, i) => {
    const x = (n - values.length + i) * bw;
    const h = v === null ? H : Math.max(1.5, (v / max) * H);
    svg.append(svgEl("rect", { x: x.toFixed(2), y: (H - h).toFixed(2), width: (bw - 0.4).toFixed(2), height: h.toFixed(2), class: v === null ? "lost" : "ok" }));
  });
  return svg;
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && traces.size) pollTraces();
});

// ----- editors ----------------------------------------------------------------------
//
// Both editors work alike: Enter or a click outside closes the editor and
// saves what changed (nothing changed: nothing to save), Escape closes it and
// drops the changes.

const EDIT_HINT = "Enter or a click outside saves, Esc cancels";

// The tag a literal address implies, or null (a DNS name may be either).
const familyTag = (host) =>
  /^\d{1,3}(\.\d{1,3}){3}$/.test(host) ? "ipv4" : host.includes(":") && /^[0-9a-f:.]+(%\S+)?$/i.test(host) ? "ipv6" : null;

document.addEventListener("pointerdown", (ev) => {
  if (renaming && !ev.target.closest(".who-editor")) closeRename(true, false);
  if (editing && !ev.target.closest(".tag-popover, .edit-tags, .add-tags")) closeTagPicker(true, false);
});

// ----- name and host editor -----------------------------------------------------------

function openRename(t) {
  if (editing) closeTagPicker(true, false);
  renaming = { id: t.id, name: t.name, host: t.host, note: "", saving: false };
  rowNote = null;
  render();
  focusRow(t.id, "rename-name", [0, t.name.length]);
}

// A new host keeps the history but starts over as PENDING (the server
// drops the status and any acknowledgement); moving between an IPv4 and an
// IPv6 address swaps the ipv4/ipv6 tag too.
async function closeRename(save, refocus) {
  const r = renaming;
  if (!r || r.saving) return;
  const t = state.targets.find((x) => x.id === r.id);
  const change = {};
  if (save && t) {
    const name = r.name.trim(), host = r.host.trim();
    if (name !== t.name) change.name = name;
    if (host !== t.host) {
      change.host = host;
      const from = familyTag(t.host), to = familyTag(host);
      if (from && to && from !== to && t.tags.includes(from) && !t.tags.includes(to))
        change.tags = t.tags.map((x) => (x === from ? to : x));
    }
  }
  const done = () => {
    renaming = null;
    render();
    if (refocus) focusRow(r.id, "edit-target");
  };
  if (Object.keys(change).length === 0) return done();
  r.saving = true;
  try {
    await call("PATCH", `api/targets/${r.id}`, change);
    done();
  } catch (err) {
    r.saving = false;
    // A demo refuses every change: say so and close. A bad name or host
    // keeps the editor open, so nothing typed is lost.
    if (state.read_only) {
      rowNote = { id: r.id, text: err.message };
      return done();
    }
    r.note = err.message;
    render();
    if (refocus) focusRow(r.id, "rename-host");
  }
}

// In place of the name and host.
function renderRenameEditor(t) {
  const form = el("form", "who-editor");
  form.addEventListener("click", (ev) => ev.stopPropagation());
  form.setAttribute("aria-label", `Rename ${t.name}`);
  const field = (key, placeholder, maxLength, title) => {
    const input = el("input");
    input.dataset.focus = `rename-${key}`;
    input.value = renaming[key];
    input.placeholder = placeholder;
    input.maxLength = maxLength;
    input.required = true;
    input.title = title;
    input.setAttribute("aria-label", placeholder);
    input.addEventListener("input", () => (renaming[key] = input.value));
    return input;
  };
  const name = field("name", "Name", 64, "Shown in the list");
  const host = field("host", "IP address or host name", 253,
    "A new host keeps the history; the status starts over and an acknowledgement is dropped");
  // A form, so Enter submits from either field; no buttons, like the picker.
  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    closeRename(true, true);
  });
  form.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") closeRename(false, true);
  });
  form.append(name, host, el("span", renaming.note ? "row-note error" : "row-note", renaming.note || EDIT_HINT));
  return form;
}

// ----- tag picker ------------------------------------------------------------------
//
// Like GitHub's label picker: the edit button next to the tags opens a list
// of every tag in use with a tick per tag of this target, and a filter that
// also creates a new tag. The add form uses the same picker for the target
// it is about to add ("new"), whose tags stay in the form until it is sent.

// The tags, their edit button and, when open, the picker. `owner` is a
// target, or { id: "new", tags } for the add form.
function renderTagLine(line, owner) {
  const tags = $(".tags", line);
  tags.replaceChildren();
  for (const tag of owner.tags) tags.append(el("span", view.tags.has(tag) ? "rtag on" : "rtag", tag));
  tags.hidden = owner.tags.length === 0;
  const isOpen = editing !== null && editing.id === owner.id;
  const button = $(".edit-tags", line);
  button.textContent = owner.tags.length ? "✎" : "+ tags";
  button.classList.toggle("empty", owner.tags.length === 0);
  button.setAttribute("aria-expanded", String(isOpen));
  button.onclick = (ev) => {
    ev.stopPropagation();
    toggleTagPicker(owner);
  };
  $(".tag-popover", line)?.remove();
  if (isOpen) line.append(renderTagPicker(owner));
}

const toggleTagPicker = (owner) =>
  editing !== null && editing.id === owner.id ? closeTagPicker(true, true) : openTagPicker(owner);

// The add form's tag line, outside the list.
const newOwner = () => ({ id: "new", name: "the new target", tags: adding.tags });
const renderAddTags = () => renderTagLine($("#add-tags .tagline"), newOwner());
const redraw = () => {
  if (state) return render();
  renderAddTags();
  placePicker();
};

// The picker hangs under the tags it edits; on a narrow screen, where the
// tags start far from the left, it moves left just enough to stay on it.
function placePicker() {
  const pop = $(".tag-popover");
  if (!pop) return;
  pop.style.left = "";
  pop.style.top = "";
  pop.style.position = "";
  const margin = 12;
  // The add form's picker, in the bar: the bar's menu scrolls (it is never
  // taller than the window) and would cut the picker off, so it hangs from
  // the window instead, under the tag box.
  const box = pop.closest("#add-tags");
  if (box) {
    const b = box.getBoundingClientRect();
    pop.style.position = "fixed";
    pop.style.top = `${b.bottom + 4}px`;
    pop.style.left = `${Math.max(margin, Math.min(b.left, document.documentElement.clientWidth - margin - pop.offsetWidth))}px`;
    return;
  }
  const r = pop.getBoundingClientRect();
  const over = r.right - (document.documentElement.clientWidth - margin);
  if (over > 0) pop.style.left = `${-Math.min(over, r.left - margin)}px`;
}

function openTagPicker(owner) {
  if (renaming) closeRename(true, false);
  if (editing) closeTagPicker(true, false);
  const inUse = state ? state.targets.flatMap((x) => x.tags) : [];
  const others = [...new Set([...inUse, ...adding.tags])].filter((tag) => !owner.tags.includes(tag));
  const byTag = (a, b) => a.localeCompare(b, undefined, { numeric: true });
  editing = { id: owner.id, selected: new Set(owner.tags), order: [...[...owner.tags].sort(byTag), ...others.sort(byTag)], filter: "" };
  rowNote = null;
  redraw();
  focusRow(owner.id, "tag-filter");
}

async function closeTagPicker(save, refocus) {
  const e = editing;
  if (!e) return;
  editing = null;
  const tags = [...e.selected];
  if (save && e.id === "new") {
    if (adding.auto && !e.selected.has(adding.auto)) [adding.refused, adding.auto] = [adding.auto, null];
    adding.tags = tags;
  }
  redraw();
  if (refocus) focusRow(e.id, "edit-tags");
  const t = save && e.id !== "new" && state.targets.find((x) => x.id === e.id);
  if (!t || (tags.length === t.tags.length && tags.every((tag) => t.tags.includes(tag)))) return;
  try {
    await call("POST", `api/targets/${e.id}/tags`, { tags });
  } catch (err) {
    rowNote = { id: e.id, text: err.message };
    render();
  }
}

// Why `text` cannot be a tag, or null.
const tagProblem = (text) =>
  text.length > MAX_TAG_LEN ? `At most ${MAX_TAG_LEN} characters` : /[\s,]/.test(text) ? "No spaces or commas" : null;

function renderTagPicker(owner) {
  const pop = el("div", "tag-popover");
  pop.addEventListener("click", (ev) => ev.stopPropagation());
  pop.setAttribute("role", "dialog");
  pop.setAttribute("aria-label", `Tags of ${owner.name}`);
  const title = el("div", "pop-title", owner.id === "new" ? "Tags of the new target" : "Apply tags to this target");
  const input = el("input", "tag-input");
  input.dataset.focus = "tag-filter";
  input.placeholder = "Filter or create a tag";
  input.setAttribute("aria-label", "Filter or create a tag");
  input.maxLength = 64;
  input.value = editing.filter;
  const list = el("ul", "pop-list");
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-multiselectable", "true");
  const note = el("div", "pop-note");

  const toggle = (tag) => {
    if (editing.selected.has(tag)) editing.selected.delete(tag);
    else if (editing.selected.size < MAX_TAGS) editing.selected.add(tag);
    const keep = document.activeElement && document.activeElement.dataset.tag === tag;
    fill();
    if (keep) $(`.pop-item[data-tag="${CSS.escape(tag)}"]`, list)?.focus();
  };
  const create = (tag) => {
    if (editing.selected.size >= MAX_TAGS) return;
    editing.order.unshift(tag);
    editing.selected.add(tag);
    editing.filter = input.value = "";
    fill();
  };
  // What Enter does: the exact match, the only match, or a new tag; with
  // an empty filter, close and save.
  let enter = null;
  const fill = () => {
    const q = editing.filter.trim().toLowerCase();
    const full = editing.selected.size >= MAX_TAGS;
    list.replaceChildren();
    const shown = editing.order.filter((tag) => tag.includes(q));
    for (const tag of shown) {
      const on = editing.selected.has(tag);
      const b = el("button", "pop-item");
      b.type = "button";
      b.setAttribute("role", "option");
      b.setAttribute("aria-selected", String(on));
      b.disabled = !on && full;
      b.dataset.tag = tag;
      b.append(el("span", "check", on ? "✓" : ""), el("span", null, tag));
      b.addEventListener("click", () => toggle(tag));
      const li = el("li");
      li.append(b);
      list.append(li);
    }
    const problem = q ? tagProblem(q) : null;
    const canCreate = q !== "" && !problem && !editing.order.includes(q);
    if (canCreate) {
      const b = el("button", "pop-item create");
      b.type = "button";
      b.disabled = full;
      b.append(el("span", "check", "+"), el("span", null, `Create tag “${q}”`));
      b.addEventListener("click", () => create(q));
      const li = el("li");
      li.append(b);
      list.append(li);
    }
    if (!shown.length && !canCreate && !problem) list.append(el("li", "pop-empty", "No tags yet: type one"));
    enter = q === "" ? () => closeTagPicker(true, true)
      : editing.order.includes(q) ? () => toggle(q) : canCreate ? () => create(q) : shown.length === 1 ? () => toggle(shown[0]) : null;
    note.textContent = problem || (full ? `At most ${MAX_TAGS} tags per target` : EDIT_HINT);
  };
  input.addEventListener("input", () => {
    editing.filter = input.value;
    fill();
  });
  input.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") {
      ev.preventDefault(); // in the add form, Enter would send it
      if (!enter) return;
      const close = editing.filter.trim() === "";
      enter();
      if (close) return;
      editing.filter = input.value = "";
      fill();
    }
  });
  pop.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") {
      ev.preventDefault();
      closeTagPicker(false, true);
    }
  });
  fill();
  pop.append(title, input, list, note);
  return pop;
}

function renderChart(box, t) {
  const W = Math.max(300, box.clientWidth || 600);
  const H = 180, L = 44, R = 8, T = 10, B = 34, LOSS_H = 6;
  const n = t.rtt.length;
  const x = (i) => L + (i * (W - L - R)) / (n - 1);
  const values = t.rtt.map((v, i) => (v === null ? null : v + (t.jitter[i] || 0))).filter((v) => v !== null);
  const top = niceCeil(Math.max(1, ...values) * 1.1);
  const y = (v) => T + (H - T - B) * (1 - v / top);

  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": `Latency of ${t.name}, last 24 hours` });
  for (const f of [0, 0.5, 1]) {
    svg.append(svgEl("line", { class: "grid", x1: L, x2: W - R, y1: y(top * f), y2: y(top * f) }));
    const label = svgEl("text", { class: "axis", x: L - 6, y: y(top * f) + 4, "text-anchor": "end" });
    label.textContent = f === 0 ? "0" : `${+(top * f).toFixed(1)} ms`;
    svg.append(label);
  }
  // A demo: shade the sample data, so nobody takes it for a real record.
  const real = n - 1 - (state.end - state.demo_from) / state.cycle_s;
  if (t.sample && real > 0) {
    svg.append(svgEl("rect", { class: "sample", x: L, y: T, width: Math.min(x(real), W - R) - L, height: H - T - B }));
    const label = svgEl("text", { class: "axis", x: L + 6, y: T + 12 });
    label.textContent = "sample data";
    svg.append(label);
    if (x(real) + 34 < W - R) { // the live part is narrow in the first minutes
      const live = svgEl("text", { class: "axis", x: x(real) + 6, y: T + 12 });
      live.textContent = "live";
      svg.append(live);
    }
  }
  const perHour = 3600 / state.cycle_s;
  for (let i = n - 1; i >= 0; i -= 6 * perHour) {
    const label = svgEl("text", { class: "axis", x: x(i), y: H - 8, "text-anchor": i === n - 1 ? "end" : "middle" });
    label.textContent = time(state.end - (n - 1 - i) * state.cycle_s);
    svg.append(label);
  }

  // Latency: one path per run of consecutive samples, so gaps stay gaps; the
  // band around the line is ± the cycle's jitter.
  let line = "", area = "", band = "", run = [];
  const pt = (i, v) => `${x(i).toFixed(1)},${y(Math.max(0, v)).toFixed(1)}`;
  const flush = () => {
    if (run.length) {
      line += "M" + run.map(([i, v]) => pt(i, v)).join("L");
      area += `M${pt(run[0][0], 0)}` + run.map(([i, v]) => `L${pt(i, v)}`).join("") + `L${pt(run[run.length - 1][0], 0)}Z`;
      const j = (i) => t.jitter[i] || 0;
      band += "M" + run.map(([i, v]) => pt(i, v + j(i))).join("L") +
        "L" + run.slice().reverse().map(([i, v]) => pt(i, v - j(i))).join("L") + "Z";
    }
    run = [];
  };
  t.rtt.forEach((v, i) => (v === null ? flush() : run.push([i, v])));
  flush();
  svg.append(svgEl("path", { class: "area", d: area }), svgEl("path", { class: "band", d: band }), svgEl("path", { class: "rtt", d: line }));

  // Loss: a strip under the chart, orange for partial and red for total loss.
  const w = Math.max(1.5, (W - L - R) / n);
  t.loss.forEach((v, i) => {
    if (!v) return;
    svg.append(svgEl("rect", { class: v < 100 ? "partial" : "loss", x: x(i) - w / 2, y: H - B + 4, width: w, height: LOSS_H }));
  });

  const cursor = svgEl("line", { class: "cursor", y1: T, y2: H - B, visibility: "hidden" });
  svg.append(cursor);
  const tip = el("div", "tip");
  tip.hidden = true;
  svg.addEventListener("mousemove", (ev) => {
    const r = svg.getBoundingClientRect();
    const px = ((ev.clientX - r.left) / r.width) * W;
    const i = Math.round(((px - L) / (W - L - R)) * (n - 1));
    if (i < 0 || i >= n) return;
    cursor.setAttribute("x1", x(i));
    cursor.setAttribute("x2", x(i));
    cursor.setAttribute("visibility", "visible");
    tip.textContent = describe(t, i, state.end - (n - 1 - i) * state.cycle_s);
    tip.hidden = false;
    const left = (x(i) / W) * r.width;
    tip.style.left = `${Math.min(left + 8, r.width - tip.offsetWidth)}px`;
  });
  svg.addEventListener("mouseleave", () => {
    cursor.setAttribute("visibility", "hidden");
    tip.hidden = true;
  });
  box.replaceChildren(svg, tip);
}

function niceCeil(v) {
  const p = 10 ** Math.floor(Math.log10(v));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}

// ----- startup -------------------------------------------------------------------

// A beat's tooltip, written when the pointer first reaches it rather than
// for every beat of every row on every render.
$("#targets").addEventListener("pointerover", (ev) => {
  const b = ev.target.closest(".beat[data-i]");
  if (!b || b.title) return;
  const t = state && state.targets.find((x) => x.id === Number(b.closest("[data-target]").dataset.target));
  if (!t) return;
  const i = Number(b.dataset.i);
  b.title = describe(t, i, state.end - (t.loss.length - 1 - i) * state.cycle_s);
});

$("#add").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const form = ev.target;
  $("#add-error").textContent = "";
  try {
    await call("POST", "api/targets", { name: form.name.value.trim(), host: form.host.value.trim(), tags: adding.tags });
    form.reset();
    adding = { tags: [], auto: null, refused: null };
    renderAddTags();
  } catch (err) {
    $("#add-error").textContent = err.message;
    $("#add-error").classList.toggle("demo", state.read_only);
  }
});

// The host decides the ipv4/ipv6 tag, until the user unticks it.
$("#add").host.addEventListener("input", (ev) => {
  const want = familyTag(ev.target.value.trim());
  if (adding.auto && adding.auto !== want) {
    adding.tags = adding.tags.filter((tag) => tag !== adding.auto);
    adding.auto = null;
  }
  if (want && want !== adding.refused && !adding.tags.includes(want) && adding.tags.length < MAX_TAGS) {
    adding.tags = [...adding.tags, want];
    adding.auto = want;
  }
  renderAddTags();
});
// The whole tag box opens the picker, not just its button.
$("#add-tags").addEventListener("click", (ev) => {
  if (!ev.target.closest(".tag-popover")) toggleTagPicker(newOwner());
});
renderAddTags();

// Only a new width changes the layout. A mobile browser resizes the height
// whenever its toolbar slides in or out during scrolling; re-rendering on that
// would fight the scroll.
const find = $("#find");
const sort = $("#sort");
const syncControls = () => {
  find.value = view.q;
  sort.value = view.sort;
};
find.addEventListener("input", () => setView(() => (view.q = find.value.trim())));
sort.append(new Option(SORTS.status, "status"), new Option(SORTS.name, "name"));
for (const [w, [group]] of Object.entries(WINDOWS)) {
  const g = el("optgroup");
  g.label = group;
  for (const m of Object.keys(METRICS)) g.append(new Option(SORTS[m + w], m + w));
  sort.append(g);
}
syncControls();
sort.addEventListener("change", () => setView(() => (view.sort = sort.value)));
$("#order").addEventListener("click", () => setView(() => (view.rev = !view.rev)));
// A bookmark or a pasted link that differs only in the fragment does not
// reload the page.
window.addEventListener("hashchange", () => {
  Object.assign(view, parseView());
  syncControls();
  if (state) render();
});

let resizeTimer, renderedWidth = window.innerWidth;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!state || window.innerWidth === renderedWidth) return;
    renderedWidth = window.innerWidth;
    render();
  }, 150);
});

// The bar: folded by default; this browser remembers it unfolded.
const MENU_KEY = "zpinger.menu";
function setMenu(open) {
  $("#bar").classList.toggle("open", open);
  $("#menu-body").hidden = !open;
  $("#menu").setAttribute("aria-expanded", String(open));
  try {
    if (open) localStorage.setItem(MENU_KEY, "1");
    else localStorage.removeItem(MENU_KEY);
  } catch {}
}
let menuOpen = false;
try {
  menuOpen = localStorage.getItem(MENU_KEY) === "1";
} catch {}
setMenu(menuOpen);
$("#menu").addEventListener("click", () => setMenu($("#menu-body").hidden));
$("#add-open").addEventListener("click", () => {
  setMenu(true);
  $("#add").name.focus();
});
$("#events").addEventListener("click", () => {
  feedOpen = !feedOpen;
  if (state) render();
});

// A background tab does not poll; it catches up when shown again.
load().then(pollLive);
setInterval(() => document.hidden || pollLive(), LIVE_MS);
setInterval(() => document.hidden || load(), STATE_FALLBACK_MS);
setInterval(() => document.hidden || tick(), 250);
document.addEventListener("visibilitychange", () => document.hidden || pollLive());
