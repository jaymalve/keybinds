// The palette and click mode demos. Drives the DOM rendered by demo.tsx; returns a cleanup.
export function startDemo() {
  const controller = new AbortController();
  const { signal } = controller;
  const addEventListener = (type, fn, capture = false) => window.addEventListener(type, fn, { capture, signal });

  // Everything the demo palette can jump to.
  const targets = [
    { title: "Inbox (3)", sub: "mail.google.com · Chrome", kind: "Tab", c: "#D8DCE3", g: "M", app: "Chrome", url: "mail.google.com/mail/u/0/#inbox" },
    { title: "npm run dev — ~/keybinds", sub: "Terminal", kind: "Tab", c: "#8B9099", g: ">_", app: "Terminal", lines: ["~/keybinds $ npm run dev", "", "> keybinds-site@0.1.0 dev", "> next dev", "", "  ▲ Next.js 16.0.1", "  - Local:   http://localhost:3000", "", "  ✓ Ready in 812ms", "  ✓ Compiled / in 412ms"] },
    { title: "Landing page v3", sub: "Figma", kind: "Window", c: "#F7F8FA", g: "F", app: "Figma" },
    { title: "keybinds/PLAN.md", sub: "github.com · Chrome", kind: "Tab", c: "#D8DCE3", g: "G", app: "Chrome", url: "github.com/jaymalve/keybinds/blob/main/docs/PLAN.md" },
    { title: "ssh prod-1 — ~", sub: "Terminal", kind: "Tab", c: "#8B9099", g: ">_", app: "Terminal", lines: ["~ $ ssh prod-1", "Last login: Tue Oct 27 20:41:12 2026", "", "prod-1:~$ uptime", " 21:04  up 41 days,  2 users,  load average: 0.12 0.09 0.08", "prod-1:~$ systemctl status api --no-pager | head -3", "● api.service - API server", "     Active: active (running) since Mon 2026-09-16"] },
    { title: "#design", sub: "Slack", kind: "Window", c: "#A9AEB7", g: "#", app: "Slack" },
    { title: "My issues", sub: "linear.app · Safari", kind: "Tab", c: "#D8DCE3", g: "L", app: "Safari", url: "linear.app/keybinds/my-issues" },
    { title: "Groceries", sub: "Notes", kind: "Window", c: "#F7F8FA", g: "N", app: "Notes" },
    { title: "lo-fi beats to code to", sub: "youtube.com · Chrome", kind: "Tab", c: "#A9AEB7", g: "▶", app: "Chrome", url: "youtube.com/watch?v=jfKfPfyJRdk" },
    { title: "Q4 roadmap", sub: "docs.google.com · Chrome", kind: "Tab", c: "#D8DCE3", g: "D", app: "Chrome", url: "docs.google.com/document/d/q4-roadmap/edit" },
    { title: "Spotify", sub: "Application", kind: "App", c: "#8B9099", g: "♪", app: "Spotify" },
  ];

  // ---------- Fuzzy match: letters in order; consecutive and word-start hits score higher ----------
  function match(query, text) {
    const q = query.toLowerCase(), s = text.toLowerCase();
    let qi = 0, score = 0, prev = -2, hits = [];
    for (let i = 0; i < s.length && qi < q.length; i++) {
      if (s[i] !== q[qi]) continue;
      score += 1 + (i === prev + 1 ? 4 : 0) + (i === 0 || /[\s\-/.#·]/.test(s[i - 1]) ? 3 : 0);
      hits.push(i); prev = i; qi++;
    }
    return qi === q.length ? { score, hits } : null;
  }

  function search(query) {
    const live = targets.filter(t => !t.closed);
    const words = query.trim().split(/\s+/).filter(Boolean);
    if (!words.length) return live.map(t => ({ t, hits: [] }));
    return live.map(t => {
      let score = 0, hits = [];
      for (const w of words) {
        const a = match(w, t.title), b = match(w, t.sub);
        if (!a && !b) return null;
        if (a && (!b || a.score >= b.score * .8)) { score += a.score; hits.push(...a.hits); }
        else score += b.score * .8;
      }
      return { t, score, hits };
    }).filter(Boolean).sort((a, b) => b.score - a.score);
  }

  // ---------- Palette ----------
  const palette = document.getElementById("palette"), scrim = document.getElementById("scrim");
  const q = document.getElementById("q"), rows = document.getElementById("rows"), count = document.getElementById("count");
  let results = [], sel = 0;

  function render() {
    results = search(q.value);
    sel = Math.min(sel, Math.max(0, results.length - 1));
    rows.innerHTML = "";
    if (!results.length) rows.innerHTML = `<li class="empty">No matches</li>`;
    results.forEach((r, i) => {
      const li = document.createElement("li");
      li.className = "row" + (i === sel ? " sel" : "");
      const hit = new Set(r.hits);
      const title = [...r.t.title].map((ch, j) => hit.has(j) ? `<mark>${esc(ch)}</mark>` : esc(ch)).join("");
      li.innerHTML = `<span class="ico" style="background:${r.t.c}">${esc(r.t.g)}</span>
        <span class="txt"><div class="ttl">${title}</div><div class="sub">${esc(r.t.sub)}</div></span>
        <span class="badge">${r.t.kind}</span>`;
      li.onmouseenter = () => { sel = i; paint(); };
      li.onclick = () => jump(r.t);
      rows.appendChild(li);
    });
    const live = targets.filter(t => !t.closed);
    count.textContent = `${live.filter(t => t.kind === "Tab").length} tabs · ${live.filter(t => t.kind === "Window").length} windows`;
  }
  function paint() {
    [...rows.children].forEach((li, i) => li.classList.toggle("sel", i === sel));
    rows.children[sel]?.scrollIntoView({ block: "nearest" });
  }
  const esc = s => s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  function open() {
    leave();
    q.value = ""; sel = 0; render();
    palette.classList.add("open"); scrim.classList.add("open");
    setTimeout(() => q.focus(), 10);
  }
  function close() {
    palette.classList.remove("open"); scrim.classList.remove("open"); q.blur();
  }
  const isOpen = () => palette.classList.contains("open");

  // A jump lands on a mock of the real thing: the browser with that tab selected, the terminal, or the window.
  const stage = document.getElementById("stage"), mock = document.getElementById("mock");
  function jump(t) {
    close();
    mock.innerHTML = t.url ? browser(t) : t.lines ? terminal(t) : windowOf(t);
    stage.classList.remove("open"); void stage.offsetWidth; stage.classList.add("open");
    toast(`→ ${t.title}  ·  ${t.sub}`);
  }
  const leave = () => stage.classList.remove("open");
  stage.onclick = e => { if (!mock.contains(e.target)) leave(); };
  const lights = `<span class="lights"><i></i><i></i><i></i></span>`;
  const skeleton = n => Array.from({ length: n }, (_, i) => `<i style="width:${[92, 78, 85, 60, 88, 70, 45][i % 7]}%"></i>`).join("");
  function browser(t) {
    const siblings = targets.filter(x => x.app === t.app && x.url && !x.closed);
    const tabs = siblings.map(x => `<span class="tab${x === t ? " on" : ""}"><b style="background:${x.c}">${esc(x.g)}</b>${esc(x.title)}</span>`).join("");
    const [host, ...path] = t.url.split("/");
    return `<div class="titlebar">${lights}<span class="tabs">${tabs}</span></div>
      <div class="address"><span><em>${esc(host)}</em>/${esc(path.join("/"))}</span></div>
      <div class="page"><h2>${esc(t.title)}</h2>${skeleton(7)}</div>`;
  }
  function terminal(t) {
    const body = t.lines.map(esc).join("\n");
    return `<div class="titlebar">${lights}<span class="name2">${esc(t.title)}</span></div>
      <div class="term">${body}\n<span class="cursor"></span></div>`;
  }
  function windowOf(t) {
    const title = t.kind === "App" ? t.app : `${t.app} — ${t.title}`;
    return `<div class="titlebar">${lights}<span class="name2">${esc(title)}</span></div>
      <div class="split"><aside>${skeleton(6)}</aside><div class="page"><h2>${esc(t.kind === "App" ? t.app : t.title)}</h2>${skeleton(6)}</div></div>`;
  }
  function closeTarget(t) {
    t.closed = true;
    toast(`Closed ${t.title}`);
    render();
    if (!targets.some(x => !x.closed)) setTimeout(() => {   // bring them all back
      targets.forEach(x => { x.closed = false; }); render();
    }, 1200);
  }

  let toastTimer;
  function toast(text) {
    const el = document.getElementById("toast");
    el.textContent = text; el.classList.add("show");
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove("show"), 1800);
  }

  q.addEventListener("input", () => { sel = 0; render(); }, { signal });
  q.addEventListener("keydown", e => {
    if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) { sel = (sel + 1) % Math.max(1, results.length); paint(); e.preventDefault(); }
    else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) { sel = (sel - 1 + results.length) % Math.max(1, results.length); paint(); e.preventDefault(); }
    else if (e.key === "Enter" && results[sel]) { jump(results[sel].t); e.preventDefault(); }
    else if (e.key === "Backspace" && e.metaKey && results[sel]) { closeTarget(results[sel].t); e.preventDefault(); }
  }, { signal });
  scrim.onclick = close;
  document.getElementById("try").onclick = open;

  // ---------- Tap ⌥, same rule as the app: released within 200 ms, nothing else pressed; held 250 ms is click mode ----------
  const k1 = document.getElementById("k1");
  let altDown = 0, holdTimer;
  const notTap = () => { altDown = 0; clearTimeout(holdTimer); };
  addEventListener("keydown", e => {
    if (e.key === "Alt") {
      if (e.repeat || e.metaKey || e.ctrlKey || e.shiftKey) return;
      e.preventDefault();
      altDown = performance.now(); k1.classList.add("down");
      if (!isOpen() && !stage.classList.contains("open")) holdTimer = setTimeout(cmStart, 250);
      return;
    }
    notTap();
    if (e.key === "Escape") isOpen() ? close() : leave();
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); isOpen() ? close() : open(); }
  });
  addEventListener("keyup", e => {
    if (e.key !== "Alt") return;
    k1.classList.remove("down");
    const tapped = altDown && performance.now() - altDown <= 200;
    notTap();
    if (tapped) isOpen() ? close() : open();
  });
  addEventListener("mousedown", notTap);
  addEventListener("blur", notTap);

  if (location.hash === "#try") open();

  // ---------- Click mode, same rules as the app: hold ⌥, type to narrow, let go or ↩ clicks the ring, a digit clicks that match, Tab moves the ring ----------
  const cmEl = document.getElementById("cm"), kOpt = document.getElementById("kOpt");
  const clickables = [...document.querySelectorAll("button, a")];
  let cm = null;   // { query, ring, hits } while ⌥ is held

  function cmDraw() {
    const label = el => `${el.textContent} ${el.getAttribute("aria-label") || ""}`;
    cm.hits = clickables.map(el => ({ el, m: match(cm.query, label(el)) })).filter(h => h.m)
      .sort((a, b) => b.m.score - a.m.score).map(h => h.el);
    cm.ring = Math.min(cm.ring, Math.max(0, cm.hits.length - 1));
    const typing = cm.query.length > 0;
    document.body.classList.toggle("narrowing", typing);
    clickables.forEach(el => el.classList.toggle("cm-off", !cm.hits.includes(el)));
    const boxes = cm.hits.map((el, i) => {
      const r = el.getBoundingClientRect();
      return `<div class="box${typing && i === cm.ring ? " best" : ""}" style="left:${r.left - 5}px;top:${r.top - 5}px;width:${r.width + 10}px;height:${r.height + 10}px">${typing && i < 9 ? `<span>${i + 1}</span>` : ""}</div>`;
    }).join("");
    const pill = typing ? esc(cm.query) + (cm.hits.length ? "" : " — no matches") : "Type to find anything clickable";
    cmEl.innerHTML = `${boxes}<div class="pill${typing ? "" : " idle"}">${pill}</div>`;
  }
  function cmStart() {
    cm = { query: "", ring: 0, hits: [] };
    kOpt.classList.add("down"); cmEl.classList.add("on"); cmDraw();
  }
  function cmEnd(el) {
    cm = null;
    kOpt.classList.remove("down"); cmEl.classList.remove("on");
    document.body.classList.remove("narrowing");
    clickables.forEach(c => c.classList.remove("cm-off"));
    el?.click();
  }
  const cmRinged = () => cm.query ? cm.hits[cm.ring] : null;

  addEventListener("keydown", e => {
    if (!cm) return;
    if (e.metaKey || e.ctrlKey) return cmEnd();   // leave browser shortcuts alone
    e.preventDefault(); e.stopImmediatePropagation();
    // e.code, because with ⌥ held e.key is "å" rather than "a".
    const letter = e.code.match(/^Key([A-Z])$/), digit = e.code.match(/^Digit([1-9])$/);
    if (e.key === "Escape") cmEnd();
    else if (e.key === "Enter") cmEnd(cmRinged());
    else if (e.key === "Tab" && cm.hits.length) { cm.ring = (cm.ring + (e.shiftKey ? -1 : 1) + cm.hits.length) % cm.hits.length; cmDraw(); }
    else if (e.key === "Backspace") { cm.query = cm.query.slice(0, -1); cm.ring = 0; cmDraw(); }
    else if (digit && cm.query) { const el = cm.hits[digit[1] - 1]; if (el) cmEnd(el); }
    else if (letter) { cm.query += letter[1].toLowerCase(); cm.ring = 0; cmDraw(); }
  }, true);
  addEventListener("keyup", e => { if (e.key === "Alt" && cm) cmEnd(cmRinged()); }, true);
  addEventListener("blur", () => { if (cm) cmEnd(); });

  // ---------- Light / dark ----------
  const root = document.documentElement;
  document.getElementById("theme").onclick = () => {
    root.dataset.theme = root.dataset.theme === "light" ? "dark" : "light";
    localStorage.setItem("theme", root.dataset.theme);
  };
  matchMedia("(prefers-color-scheme: light)").addEventListener("change", e => {
    if (!localStorage.getItem("theme")) root.dataset.theme = e.matches ? "light" : "dark";
  }, { signal });
  document.getElementById("download").onclick = e => { e.preventDefault(); toast("Coming soon — the first build is in testing"); };

  return () => controller.abort();
}
