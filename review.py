"""
Sift's review page: a web page on this Mac for going through the duplicate sets a scan
found, marking what to keep and what to delete, and comparing copies side by side in full
quality (photos zoom together; videos play side by side). The ones you choose go to an
album in Photos, "Sift - To Delete", where you delete them yourself: other apps aren't
allowed to delete from your library.

The scan saves its sets as review.json next to its report; this serves them.

  uv run sift.py --review "~/Desktop/Sift Report (Photos)"
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import webbrowser
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

DELETE_ALBUM = "Sift - To Delete"
PORT = 8765                       # the same each time, so the page remembers your sort order
PUBLIC = ("id", "name", "date", "width", "height", "size", "duration", "favorite", "edited", "live",
          "burst", "raw", "cloud_only", "action", "reason")


def render_jpeg(path: str, max_side: int, quality: int, width: int = 0, height: int = 0) -> bytes:
    """A JPEG of any image the Mac can read (HEIC and RAW included, via sips), no larger
    than max_side."""
    if sys.platform == "darwin":
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "full.jpg")
            cmd = ["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(quality)]
            if max(width, height) > max_side or not (width and height):
                cmd += ["-Z", str(max_side)]
            r = subprocess.run(cmd + [path, "--out", out], capture_output=True, timeout=180)
            if r.returncode == 0 and os.path.exists(out):
                return Path(out).read_bytes()
    from PIL import Image, ImageOps
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        im.thumbnail((max_side, max_side))
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def send_to_album(ids: list[str]) -> str:
    import photoscript
    try:
        from photoscript.script_loader import configure_run_script
        configure_run_script(retry_enabled=False)   # don't quit Photos if it's slow to answer
    except ImportError:
        pass
    lib = photoscript.PhotosLibrary()
    album = lib.album(DELETE_ALBUM) or lib.create_album(DELETE_ALBUM)
    items = [photoscript.Photo(u) for u in ids]
    for k in range(0, len(items), 200):
        album.add(items[k:k + 200])
    return f"Added {len(ids)} to the album “{DELETE_ALBUM}” in Photos."


def make_handler(state: dict):
    report_dir = Path(state["dir"])
    by_id = {it["id"]: it for g in state["groups"] for it in g}
    large_cache: OrderedDict = OrderedDict()      # compare-view images are big: keep a few
    lock, export_lock = threading.Lock(), threading.Lock()

    def visible_groups() -> list:
        sent = set(state["sent"])
        groups = [[it for it in g if it["id"] not in sent] for g in state["groups"]]
        return [g for g in groups if len(g) > 1]

    def export_from_photos(it: dict) -> str:
        """Ask Photos for the photo as it looks now (edits included), downloading it from
        iCloud first if it isn't on this Mac. Photos handles one export at a time."""
        with export_lock:
            done = it.get("_exported")
            if done and os.path.exists(done):
                return done
            import photoscript
            dest = Path(state["export_dir"]) / it["id"]
            dest.mkdir(parents=True, exist_ok=True)
            files = photoscript.Photo(it["id"]).export(str(dest), original=False, overwrite=True, timeout=180)
            images = [f for f in files if Path(f).suffix.lower() not in (".mov", ".mp4", ".m4v")]
            if not images:
                raise RuntimeError("Photos didn't return an image")
            it["_exported"] = images[0]
            return images[0]

    def large(it: dict) -> tuple[bytes, str, str]:
        """A big JPEG for the compare view, and whether it's full quality or a preview."""
        with lock:
            if it["id"] in large_cache:
                large_cache.move_to_end(it["id"])
                return large_cache[it["id"]]
        preview = it.get("preview") or (str(report_dir / it["thumb"]) if it.get("thumb") else None)
        try:
            if state["kind"] == "video":
                # the video itself plays in the compare view; this is its poster
                result = (render_jpeg(preview, 2048, 88), "preview", "")
            else:
                src = next((p for p in (it.get("edited_path"), it.get("orig")) if p and os.path.exists(p)), None)
                src = src or export_from_photos(it)
                result = (render_jpeg(src, 4096, 92, it.get("width", 0), it.get("height", 0)), "full", "")
        except Exception as exc:
            print(f"(Full quality unavailable for {it['name']}: {exc})", flush=True)
            if not preview:
                raise
            result = (render_jpeg(preview, 4096, 92), "preview", "Photos couldn't provide the full-quality version")
        with lock:
            large_cache[it["id"]] = result
            while len(large_cache) > 24:
                large_cache.popitem(last=False)
        return result

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def ours(self) -> bool:
            """Only answer our own page: the Host must be this Mac, and changes must come
            from the page itself (not another website open in the browser)."""
            port = state["port"]
            host = self.headers.get("Host", "")
            if host not in (f"localhost:{port}", f"127.0.0.1:{port}"):
                return False
            origin = self.headers.get("Origin")
            return origin is None or origin in (f"http://localhost:{port}", f"http://127.0.0.1:{port}")

        def send(self, code: int, body: bytes, ctype: str, headers: dict | None = None) -> None:
            self.send_response(code)
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store" if "json" in ctype or "html" in ctype else "max-age=3600")
            self.end_headers()
            self.wfile.write(body)

        def send_video(self, path: str) -> None:
            """Stream a video, in parts when asked (Safari won't play one otherwise)."""
            size = os.path.getsize(path)
            start, end = 0, size - 1
            rng = self.headers.get("Range", "")
            if rng.startswith("bytes="):
                a, _, b = rng[6:].split(",")[0].partition("-")
                if a.strip():
                    start = int(a)
                    end = min(int(b), size - 1) if b.strip() else size - 1
                elif b.strip():                       # the last N bytes
                    start = max(0, size - int(b))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                try:
                    while left > 0:
                        chunk = f.read(min(1 << 20, left))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        left -= len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass                              # the browser only wanted part of it

        def do_GET(self):
            if not self.ours():
                return self.send(403, b"forbidden", "text/plain")
            path = urlparse(self.path).path
            if path == "/":
                return self.send(200, PAGE.encode(), "text/html; charset=utf-8")
            if path == "/api/groups":
                groups = [[{k: it.get(k) for k in PUBLIC} | {"playable": bool(it.get("orig"))}
                           for it in g] for g in visible_groups()]
                body = {"groups": groups, "kind": state["kind"], "album": DELETE_ALBUM, "source": state["source"]}
                return self.send(200, json.dumps(body).encode(), "application/json")
            kind, _, pid = path[1:].partition("/")
            it = by_id.get(unquote(pid))
            if kind not in ("thumb", "large", "video") or not it:
                return self.send(404, b"not found", "text/plain")
            try:
                if kind == "thumb":
                    if it.get("thumb") and (report_dir / it["thumb"]).exists():
                        return self.send(200, (report_dir / it["thumb"]).read_bytes(), "image/jpeg")
                    return self.send(200, render_jpeg(it["preview"] or it["orig"], 480, 82), "image/jpeg")
                if kind == "large":
                    data, quality, note = large(it)
                    return self.send(200, data, "image/jpeg", {"X-Quality": quality, "X-Note": note})
                if it.get("orig") and os.path.exists(it["orig"]):
                    return self.send_video(it["orig"])
                return self.send(404, b"not on this Mac", "text/plain")
            except Exception:
                return self.send(500, b"could not read it", "text/plain")

        def do_POST(self):
            if not self.ours() or urlparse(self.path).path != "/api/delete":
                return self.send(403, b"forbidden", "text/plain")
            try:
                length = int(self.headers.get("Content-Length", 0))
                ids = [i for i in json.loads(self.rfile.read(length))["ids"] if i in by_id]
                if not ids:
                    raise RuntimeError("Nothing selected.")
                message = state["send"](ids)
                with lock:
                    state["sent"] = list(dict.fromkeys(state["sent"] + ids))
                    save_sent(report_dir, state["sent"])
                self.send(200, json.dumps({"ok": True, "message": message}).encode(), "application/json")
            except Exception as exc:
                self.send(500, json.dumps({"ok": False, "message": str(exc)}).encode(), "application/json")

    return Handler


def save_sent(report_dir: Path, sent: list[str]) -> None:
    f = report_dir / "review.json"
    try:
        data = json.loads(f.read_text())
        data["sent"] = sent
        f.write_text(json.dumps(data))
    except Exception:
        pass


def serve(report_dir: str | Path, open_browser: bool = True, announce=None, send=send_to_album) -> None:
    """Serve the review page for a report folder until stopped (Ctrl-C, or the app quits)."""
    report_dir = Path(report_dir).expanduser()
    try:
        data = json.loads((report_dir / "review.json").read_text())
    except Exception:
        sys.exit(f"There's nothing to review in {report_dir}. Run a scan first.")
    state = {"dir": str(report_dir), "groups": data.get("groups", []), "kind": data.get("kind", "video"),
             "source": data.get("source", ""), "sent": data.get("sent", []), "send": send,
             "export_dir": tempfile.mkdtemp(prefix="sift-review-")}
    server = None
    for port in (PORT, PORT + 1, PORT + 2, 0):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port), None)
            break
        except OSError:
            continue
    state["port"] = server.server_address[1]
    server.RequestHandlerClass = make_handler(state)
    url = f"http://localhost:{state['port']}/"
    if announce:
        announce(url)
    else:
        print(f"Review page: {url}  (press Ctrl-C here when you've finished)", flush=True)
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nReview page closed.")
    finally:
        server.server_close()


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sift - Review</title>
<style>
:root{--bg:#f6f5f2;--card:#fff;--ink:#1d1d1f;--muted:#6e6e73;--line:#e3e1dc;--keep:#1f8a4c;--del:#c4302b;--rev:#a16207;--accent:#0a66d8}
@media (prefers-color-scheme:dark){:root{--bg:#161616;--card:#222;--ink:#f2f2f2;--muted:#a1a1a6;--line:#333;--keep:#3fbf74;--del:#ff5a52;--rev:#facc15;--accent:#4c9bff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
header{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(12px);border-bottom:1px solid var(--line)}
.bar{max-width:1240px;margin:auto;padding:12px 20px;display:flex;gap:10px 14px;align-items:center;flex-wrap:wrap}
h1{font-size:19px;margin:0;font-weight:650;letter-spacing:-.01em}
.stats{color:var(--muted);font-size:13.5px}
.spacer{flex:1}
button{font:inherit;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);padding:7px 13px;cursor:pointer}
button:hover{border-color:var(--muted)}
button.on{border-color:var(--del);color:var(--del);font-weight:600}
button.primary{background:var(--del);border-color:var(--del);color:#fff;font-weight:600}
button:disabled{opacity:.45;cursor:default}
main{max-width:1240px;margin:auto;padding:20px}
.help{color:var(--muted);font-size:13.5px;margin:0 0 16px;max-width:900px}
.group{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:16px}
.ghead{display:flex;gap:12px;align-items:center;margin-bottom:10px;font-size:13.5px;color:var(--muted);flex-wrap:wrap}
.ghead b{color:var(--ink)}
.ghead button{padding:4px 9px;font-size:12.5px}
.ghead .cmpBtn{border-color:var(--accent);color:var(--accent);font-weight:600}
.items{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:12px}
.it{position:relative;border-radius:9px;overflow:hidden;border:3px solid var(--keep);cursor:pointer;background:var(--bg);user-select:none}
.it.del{border-color:var(--del)}
.it.del img{opacity:.45;filter:grayscale(.6)}
.it img{display:block;width:100%;height:170px;object-fit:cover;background:#000}
.tag{position:absolute;top:7px;left:7px;font-size:11.5px;font-weight:700;padding:2px 8px;border-radius:99px;background:var(--keep);color:#fff;letter-spacing:.03em}
.it.del .tag,.cp.del .tag{background:var(--del)}
.badges{position:absolute;top:7px;right:7px;display:flex;gap:4px;flex-wrap:wrap;justify-content:flex-end;max-width:70%}
.badges span{font-size:11px;background:rgba(0,0,0,.62);color:#fff;padding:2px 6px;border-radius:99px}
.badges span.best{background:#f5b301;color:#1d1d1f;font-weight:700}
.badges span.rev{background:var(--rev);color:#1d1d1f;font-weight:600}
.dur{position:absolute;right:7px;top:146px;background:rgba(0,0,0,.65);color:#fff;font-size:11.5px;padding:1px 6px;border-radius:6px}
.meta{padding:7px 9px;font-size:12px;color:var(--muted);line-height:1.35}
.meta .n{color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta .why{margin-top:3px;color:var(--ink);font-size:11.5px}
.empty{text-align:center;padding:80px 20px;color:var(--muted)}
.tools{display:flex;justify-content:flex-end;align-items:center;gap:8px;margin:0 0 12px;color:var(--muted);font-size:13.5px}
select,.pager input{font:inherit;color:var(--ink);background:var(--card);border:1px solid var(--line);border-radius:8px;padding:6px 8px}
.pager{display:flex;gap:8px;justify-content:center;align-items:center;flex-wrap:wrap;margin:10px 0 30px;color:var(--muted)}
.pager.top{margin:0 0 16px}
.pager input{width:4.5em;text-align:center}
/* compare view */
.cmp{position:fixed;inset:0;z-index:20;background:var(--bg);display:flex;flex-direction:column}
.cmp[hidden]{display:none}
.cmp-bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:10px 16px;border-bottom:1px solid var(--line)}
.cmp-bar .hint{color:var(--muted);font-size:12.5px}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
.seg button{border:0;border-radius:0;padding:6px 11px;background:var(--card)}
.seg button+button{border-left:1px solid var(--line)}
.seg button.on{background:var(--ink);color:var(--bg)}
.cmp-grid{flex:1;min-height:0;overflow:auto;display:grid;gap:12px;padding:12px 16px 16px;grid-auto-rows:minmax(340px,1fr)}
.cp{display:flex;flex-direction:column;min-height:0;border:3px solid var(--keep);border-radius:10px;overflow:hidden;background:var(--card)}
.cp.del{border-color:var(--del)}
.cp-img{flex:1;min-height:0;overflow:hidden;position:relative;background:#000;cursor:zoom-in}
.cp-img.zoomed{cursor:zoom-out}
.cp-img img,.cp-img video{width:100%;height:100%;object-fit:contain;display:block;transform:scale(var(--z,1));transform-origin:var(--ox,50%) var(--oy,50%);transition:transform .12s ease-out}
.cp.del .cp-img img,.cp.del .cp-img video{opacity:.55}
.cp-img .q{position:absolute;bottom:8px;right:8px;background:rgba(0,0,0,.7);color:#fff;font-size:11.5px;padding:3px 9px;border-radius:99px;max-width:calc(100% - 60px)}
.cp-img .q.warn{background:#b8860b}
.cp-img .num{position:absolute;bottom:8px;left:8px;background:rgba(0,0,0,.6);color:#fff;font-size:11.5px;padding:2px 7px;border-radius:99px}
.cp-info{padding:8px 10px;font-size:12.5px;color:var(--muted);display:flex;gap:6px 10px;align-items:center;flex-wrap:wrap}
.cp-info .n{color:var(--ink);font-weight:600;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.cp-info .best{color:var(--keep);font-weight:700}
.cp-info .hi{color:var(--ink);font-weight:600}
.cp-info .why{flex-basis:100%;color:var(--ink)}
.cp-actions{display:flex;gap:6px;margin-left:auto}
.cp-actions button{padding:4px 9px;font-size:12.5px}
@media (max-width:700px){.cmp-grid{grid-template-columns:1fr !important;grid-auto-rows:minmax(300px,70vh)}.cmp-bar .hint{display:none}}
.toast{z-index:30;position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--ink);color:var(--bg);padding:12px 18px;border-radius:10px;max-width:min(600px,92vw);font-size:14px;box-shadow:0 6px 30px rgba(0,0,0,.25);display:none}
</style></head>
<body>
<header><div class="bar">
  <h1 id="title">Review</h1>
  <span class="stats" id="stats">Loading…</span>
  <span class="spacer"></span>
  <button id="selectPage">Select suggested on this page</button>
  <button id="selectAll">Select suggested in all sets</button>
  <button id="clearSel">Clear selection</button>
  <button class="primary" id="go" disabled>Move to delete album</button>
</div></header>
<main>
  <p class="help" id="help"></p>
  <div class="tools"><label for="sort">Sort by</label>
    <select id="sort">
      <option value="space">Most space saved first</option>
      <option value="count">Largest sets first</option>
      <option value="date-asc">Oldest first</option>
      <option value="date-desc">Newest first</option>
    </select></div>
  <div class="pager top" id="pagerTop"></div>
  <div id="list"></div>
  <div class="pager" id="pager"></div>
</main>
<div class="cmp" id="cmp" hidden role="dialog" aria-modal="true" aria-labelledby="cmpTitle">
  <div class="cmp-bar">
    <b id="cmpTitle"></b>
    <span class="hint" id="cmpHint"></span>
    <span class="spacer"></span>
    <button id="cmpPlay" hidden>▶ Play all</button>
    <span class="seg" id="cmpZoom"><button data-z="1" class="on">Fit</button><button data-z="2">2×</button><button data-z="4">4×</button></span>
    <button id="cmpKeepAll">Keep all</button>
    <button id="cmpPrev">← Previous</button>
    <button id="cmpNext">Next →</button>
    <button class="primary" id="cmpDelete" disabled>Move to delete album</button>
    <button id="cmpClose">✕ Close</button>
  </div>
  <div class="cmp-grid" id="cmpGrid"></div>
</div>
<div class="toast" id="toast"></div>
<script>
const PER_PAGE = 40;
let data = null, page = 0, marked = new Set(), allSets = false, noun = "photo";

// A selection only covers the page on screen and is cleared when you change page, unless
// "Select suggested in all sets" is used. "Suggested" means Sift's Delete suggestions: real
// copies. Photos and videos it only marked for Review (bursts, look-alikes) are never selected for you.
const SORTS = {
  "space":     (a, b) => extra(b) - extra(a) || b.length - a.length,
  "count":     (a, b) => b.length - a.length || extra(b) - extra(a),
  "date-asc":  (a, b) => gdate(a).localeCompare(gdate(b)),
  "date-desc": (a, b) => gdate(b).localeCompare(gdate(a)),
};
let sortBy = "space";
try { const v = localStorage.getItem("siftSort"); if(SORTS[v]) sortBy = v; } catch(e) {}
function gdate(g){ return g.reduce((m, p) => (p.date && p.date < m ? p.date : m), g[0].date || ""); }
function extra(g){ return g.filter(p => p.action === "delete").reduce((a, p) => a + (p.size || 0), 0); }
function pageGroups(){ return data.groups.slice(page*PER_PAGE, (page+1)*PER_PAGE); }
function suggest(groups){ marked = new Set(); groups.forEach(g => g.forEach(p => { if(p.action === "delete") marked.add(p.id); })); }
function goToPage(n){ const pages = Math.ceil(data.groups.length / PER_PAGE); n = Math.max(0, Math.min(pages-1, n)); if(n === page) return render(); page = n; if(!allSets) marked.clear(); render(); scrollTo(0,0); }
function fmtSize(b){ if(!b) return ""; const u=["B","KB","MB","GB"]; let i=0; while(b>=1000&&i<3){b/=1000;i++} return b.toFixed(i?1:0)+" "+u[i]; }
function fmtDate(s){ if(!s) return ""; const d=new Date(s); return d.toLocaleDateString(undefined,{year:"numeric",month:"short",day:"numeric"})+" "+d.toLocaleTimeString(undefined,{hour:"2-digit",minute:"2-digit"}); }
function fmtDur(s){ s = Math.round(s||0); const h=Math.floor(s/3600), m=Math.floor(s%3600/60), x=String(s%60).padStart(2,"0"); return h ? `${h}:${String(m).padStart(2,"0")}:${x}` : `${m}:${x}`; }
function esc(s){ return String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
function plural(n, w){ return `${n} ${w}${n === 1 ? "" : "s"}`; }
function toast(msg, ms=6000){ const t=document.getElementById("toast"); t.textContent=msg; t.style.display="block"; clearTimeout(t._h); t._h=setTimeout(()=>t.style.display="none", ms); }
function badges(p, i){
  return (i===0 ? '<span class="best" title="The copy Sift suggests keeping">★ Best</span>' : "")
    + (p.action === "review" ? `<span class="rev" title="${esc(p.reason)}">Review</span>` : "")
    + (p.favorite ? "<span>♥ Favourite</span>" : "") + (p.live ? "<span>Live</span>" : "") + (p.burst ? "<span>Burst</span>" : "")
    + (p.raw ? "<span>RAW</span>" : "") + (p.edited ? "<span>Edited</span>" : "") + (p.cloud_only ? "<span>iCloud</span>" : "");
}
function moveLabel(n){ return `Move ${n} to delete album`; }

function updateStats(){
  const total = data.groups.reduce((a,g)=>a+g.length,0);
  const bytes = data.groups.flat().filter(p=>marked.has(p.id)).reduce((a,p)=>a+(p.size||0),0);
  document.getElementById("stats").textContent =
    `${plural(data.groups.length, "set")} · ${plural(total, noun)} · ${marked.size} selected ${allSets ? "in all sets" : "on this page"}` + (bytes ? ` (${fmtSize(bytes)})` : "");
  const go = document.getElementById("go");
  go.disabled = marked.size === 0;
  go.textContent = moveLabel(marked.size);
  document.getElementById("selectAll").classList.toggle("on", allSets);
}

function render(){
  const list = document.getElementById("list");
  if(!data.groups.length){
    list.innerHTML = `<div class="empty"><h2>Nothing left to review</h2><p>Every set has been dealt with. Open Photos › Albums › “${esc(data.album)}” to delete what you chose.</p></div>`;
    document.getElementById("pager").innerHTML = document.getElementById("pagerTop").innerHTML = "";
    return updateStats();
  }
  const pages = Math.ceil(data.groups.length / PER_PAGE);
  page = Math.min(page, pages-1);
  list.innerHTML = pageGroups().map((g, gi) => {
    const k = page*PER_PAGE + gi;
    return `<section class="group">
      <div class="ghead"><b>Set ${k+1}</b><span>${plural(g.length, noun)}</span><span class="spacer"></span>
        <button data-g="${k}" data-act="compare" class="cmpBtn">⤢ Expand &amp; compare</button>
        <button data-g="${k}" data-act="keep">Keep all</button></div>
      <div class="items">${g.map((p, i) => `
        <div class="it ${marked.has(p.id)?"del":""}" data-id="${esc(p.id)}" title="Click to switch between keep and delete">
          <img loading="lazy" src="/thumb/${encodeURIComponent(p.id)}" alt="">
          <span class="tag">${marked.has(p.id)?"DELETE":"KEEP"}</span>
          <span class="badges">${badges(p, i)}</span>
          ${data.kind === "video" ? `<span class="dur">${fmtDur(p.duration)}</span>` : ""}
          <div class="meta"><div class="n">${esc(p.name)}</div>${fmtDate(p.date)}<br>${p.width&&p.height?p.width+"×"+p.height+" · ":""}${fmtSize(p.size)}
            ${i ? `<div class="why">${esc(p.reason)}</div>` : ""}</div>
        </div>`).join("")}</div>
    </section>`;
  }).join("");
  const pager = pages > 1 ? `
    <button data-go="0" ${page?"":"disabled"}>« First</button>
    <button data-go="${page-1}" ${page?"":"disabled"}>← Previous</button>
    <span>Page</span><input class="pageInput" type="number" min="1" max="${pages}" value="${page+1}" aria-label="Page number"><span>of ${pages}</span>
    <button class="pageGoBtn">Go</button>
    <button data-go="${page+1}" ${page<pages-1?"":"disabled"}>Next →</button>
    <button data-go="${pages-1}" ${page<pages-1?"":"disabled"}>Last »</button>` : "";
  document.getElementById("pager").innerHTML = document.getElementById("pagerTop").innerHTML = pager;
  updateStats();
}

document.getElementById("list").addEventListener("click", e => {
  const b = e.target.closest("button[data-act]");
  if(b && b.dataset.act === "compare") return openCompare(+b.dataset.g);
  if(b){ data.groups[+b.dataset.g].forEach(p => marked.delete(p.id)); return render(); }
  const it = e.target.closest(".it"); if(!it) return;
  const id = it.dataset.id;
  marked.has(id) ? marked.delete(id) : marked.add(id);
  it.classList.toggle("del", marked.has(id));
  it.querySelector(".tag").textContent = marked.has(id) ? "DELETE" : "KEEP";
  updateStats();
});

// ---- compare view: one set at a time, big and side by side, zooming together
let cmpIdx = -1, zoom = 1;
const cmpEl = document.getElementById("cmp"), cmpGrid = document.getElementById("cmpGrid");
function openCompare(gi){ cmpIdx = gi; zoom = 1; cmpEl.hidden = false; document.body.style.overflow = "hidden"; renderCompare(); document.getElementById("cmpClose").focus(); }
function closeCompare(){
  if(cmpEl.hidden) return;
  const gi = cmpIdx; cmpEl.hidden = true; cmpIdx = -1; document.body.style.overflow = ""; cmpGrid.innerHTML = "";
  render();
  const sec = document.querySelectorAll(".group")[gi - page*PER_PAGE];
  if(sec) sec.scrollIntoView({block:"center"});
}
function cols(n){ const w = innerWidth; if(w <= 700) return 1; if(n <= 3) return n; if(n === 4) return w > 1500 ? 4 : 2; return w > 1500 ? 4 : 3; }
function renderCompare(){
  const g = data.groups[cmpIdx];
  if(!g) return closeCompare();
  const video = data.kind === "video";
  const first = page*PER_PAGE, last = Math.min(data.groups.length, first+PER_PAGE) - 1;
  document.getElementById("cmpTitle").textContent = `Set ${cmpIdx+1} · ${plural(g.length, noun)}`;
  document.getElementById("cmpPrev").disabled = cmpIdx <= first;
  document.getElementById("cmpNext").disabled = cmpIdx >= last;
  document.getElementById("cmpPlay").hidden = !video;
  const n = g.filter(p => marked.has(p.id)).length, del = document.getElementById("cmpDelete");
  del.disabled = n === 0; del.textContent = moveLabel(n);
  document.querySelectorAll("#cmpZoom button").forEach(b => b.classList.toggle("on", +b.dataset.z === zoom));
  const maxPx = Math.max(...g.map(p => (p.width||0)*(p.height||0))), maxSize = Math.max(...g.map(p => p.size||0));
  cmpGrid.style.gridTemplateColumns = `repeat(${cols(g.length)}, minmax(0,1fr))`;
  cmpGrid.style.setProperty("--z", zoom);
  cmpGrid.innerHTML = g.map((p, i) => {
    const d = marked.has(p.id), px = (p.width||0)*(p.height||0);
    const media = video && p.playable
      ? `<video src="/video/${encodeURIComponent(p.id)}" poster="/thumb/${encodeURIComponent(p.id)}" muted playsinline preload="metadata" controls></video>`
      : `<img src="/thumb/${encodeURIComponent(p.id)}" alt="${esc(p.name)}"><span class="q">${video ? "Only in iCloud: can't play here" : "Loading full quality…"}</span>`;
    return `<div class="cp ${d?"del":""}" data-id="${esc(p.id)}">
      <div class="cp-img ${zoom>1?"zoomed":""}">${media}
        <span class="tag">${d?"DELETE":"KEEP"}</span>${i<9?`<span class="num">${i+1}</span>`:""}
        <span class="badges">${badges(p, -1)}</span></div>
      <div class="cp-info">
        <span class="n" title="${esc(p.name)}">${esc(p.name)}</span>
        ${i===0?'<span class="best">★ Best copy: suggested to keep</span>':""}
        <span>${fmtDate(p.date)}</span>
        ${video ? `<span>${fmtDur(p.duration)}</span>` : ""}
        ${p.width&&p.height?`<span class="${px===maxPx&&g.length>1?"hi":""}">${p.width}×${p.height}</span>`:""}
        ${p.size?`<span class="${p.size===maxSize?"hi":""}">${fmtSize(p.size)}</span>`:""}
        <span class="cp-actions"><button data-cact="toggle">${d?"Keep":"Delete"}</button><button data-cact="only">Keep only this</button></span>
        ${i ? `<span class="why">${esc(p.reason)}</span>` : ""}
      </div></div>`;
  }).join("");
  if(!video) g.forEach(p => loadLarge(p.id).then(res => showLarge(p.id, res)));
  updateStats();
}
// Full quality can take a few seconds (Photos may download it from iCloud first), so each
// panel shows the preview straight away and swaps in the full version when it's ready.
const largeImages = new Map();
function loadLarge(id){
  if(!largeImages.has(id)) largeImages.set(id, fetch(`/large/${encodeURIComponent(id)}`).then(async r => {
    if(!r.ok) throw new Error();
    return {url: URL.createObjectURL(await r.blob()), quality: r.headers.get("X-Quality"), note: r.headers.get("X-Note")};
  }).catch(() => { largeImages.delete(id); return {url: null, quality: "preview", note: "couldn't load the full-quality version"}; }));
  return largeImages.get(id);
}
function showLarge(id, res){
  const cp = cmpGrid.querySelector(`.cp[data-id="${CSS.escape(id)}"]`); if(!cp) return;
  if(res.url) cp.querySelector(".cp-img img").src = res.url;
  const q = cp.querySelector(".q"); if(!q) return;
  if(res.quality === "full") q.remove();
  else { q.classList.add("warn"); q.textContent = "Preview only: " + (res.note || "full quality unavailable"); }
}
function cmpToggle(id){ marked.has(id) ? marked.delete(id) : marked.add(id); renderCompare(); }
function setZoom(z){ zoom = z; cmpGrid.style.setProperty("--z", zoom); document.querySelectorAll("#cmpZoom button").forEach(b => b.classList.toggle("on", +b.dataset.z === zoom)); cmpGrid.querySelectorAll(".cp-img").forEach(el => el.classList.toggle("zoomed", zoom > 1)); }
cmpGrid.addEventListener("click", e => {
  const cp = e.target.closest(".cp"); if(!cp) return;
  const act = e.target.closest("button[data-cact]");
  if(act && act.dataset.cact === "toggle") return cmpToggle(cp.dataset.id);
  if(act && act.dataset.cact === "only"){ data.groups[cmpIdx].forEach(p => p.id === cp.dataset.id ? marked.delete(p.id) : marked.add(p.id)); return renderCompare(); }
  if(e.target.closest(".cp-img") && !e.target.closest("video")) setZoom(zoom === 1 ? 2 : 1);
});
cmpGrid.addEventListener("pointermove", e => {      // every panel pans to the same spot
  const box = e.target.closest(".cp-img"); if(!box) return;
  const r = box.getBoundingClientRect();
  cmpGrid.style.setProperty("--ox", ((e.clientX - r.left) / r.width * 100).toFixed(1) + "%");
  cmpGrid.style.setProperty("--oy", ((e.clientY - r.top) / r.height * 100).toFixed(1) + "%");
});
document.getElementById("cmpPlay").onclick = () => {   // start every video together
  const vids = [...cmpGrid.querySelectorAll("video")];
  const playing = vids.some(v => !v.paused);
  vids.forEach(v => { if(playing) v.pause(); else { v.currentTime = 0; v.play().catch(()=>{}); } });
  document.getElementById("cmpPlay").textContent = playing ? "▶ Play all" : "❚❚ Pause all";
};
document.getElementById("cmpZoom").addEventListener("click", e => { const b = e.target.closest("button[data-z]"); if(b) setZoom(+b.dataset.z); });
document.getElementById("cmpClose").onclick = closeCompare;
document.getElementById("cmpPrev").onclick = () => { cmpIdx--; renderCompare(); };
document.getElementById("cmpNext").onclick = () => { cmpIdx++; renderCompare(); };
document.getElementById("cmpKeepAll").onclick = () => { data.groups[cmpIdx].forEach(p => marked.delete(p.id)); renderCompare(); };
addEventListener("resize", () => { if(!cmpEl.hidden) cmpGrid.style.gridTemplateColumns = `repeat(${cols(data.groups[cmpIdx].length)}, minmax(0,1fr))`; });
document.addEventListener("keydown", e => {
  if(cmpEl.hidden || e.metaKey || e.ctrlKey || e.altKey) return;
  const g = data.groups[cmpIdx];
  if(e.key === "Escape") closeCompare();
  else if(e.key === "ArrowLeft" && !document.getElementById("cmpPrev").disabled){ cmpIdx--; renderCompare(); }
  else if(e.key === "ArrowRight" && !document.getElementById("cmpNext").disabled){ cmpIdx++; renderCompare(); }
  else if(e.key === "z" || e.key === "Z") setZoom(zoom === 1 ? 2 : zoom === 2 ? 4 : 1);
  else if(/^[1-9]$/.test(e.key) && g[+e.key-1]) cmpToggle(g[+e.key-1].id);
  else if((e.key === "Backspace" || e.key === "Delete") && !document.getElementById("cmpDelete").disabled) compareDelete();
  else return;
  e.preventDefault();
});

function jumpFrom(input){ const n = parseInt(input.value, 10); if(Number.isFinite(n)) goToPage(n-1); else input.value = page+1; }
document.querySelectorAll(".pager").forEach(el => {
  el.addEventListener("click", e => {
    const b = e.target.closest("button"); if(!b || b.disabled) return;
    if(b.dataset.go !== undefined) goToPage(+b.dataset.go);
    else if(b.classList.contains("pageGoBtn")) jumpFrom(el.querySelector(".pageInput"));
  });
  el.addEventListener("keydown", e => { if(e.key === "Enter" && e.target.classList.contains("pageInput")) jumpFrom(e.target); });
});
document.getElementById("sort").onchange = e => {
  sortBy = e.target.value;
  try { localStorage.setItem("siftSort", sortBy); } catch(err) {}
  data.groups.sort(SORTS[sortBy]); page = 0; if(!allSets) marked.clear(); render(); scrollTo(0,0);
};
document.getElementById("selectPage").onclick = () => { allSets = false; suggest(pageGroups()); render(); };
document.getElementById("selectAll").onclick = () => { allSets = true; suggest(data.groups); render(); };
document.getElementById("clearSel").onclick = () => { marked.clear(); allSets = false; render(); };

// Sends items to the delete album and drops them from the page; sets left with fewer
// than two disappear.
async function sendToDelete(ids){
  const r = await fetch("/api/delete", {method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify({ids})});
  const j = await r.json();
  if(!j.ok) throw new Error(j.message);
  toast(j.message + `  When you're ready, open Photos › Albums › “${data.album}”, press ⌘A, then ⌘⌫ to delete them.`, 15000);
  const done = new Set(ids);
  data.groups = data.groups.map(g => g.filter(p => !done.has(p.id))).filter(g => g.length > 1);
  ids.forEach(id => marked.delete(id));
}
async function compareDelete(){
  const g = data.groups[cmpIdx], ids = g.filter(p => marked.has(p.id)).map(p => p.id);
  if(!ids.length) return;
  let q = `Add ${plural(ids.length, noun)} from this set to the album “${data.album}” in Photos?`;
  if(ids.length === g.length) q = `⚠️ You've marked EVERY ${noun} in this set, so none would be kept.\n\n` + q;
  if(!confirm(q)) return;
  const btn = document.getElementById("cmpDelete"); btn.disabled = true; btn.textContent = "Working…";
  try{
    await sendToDelete(ids);
    const last = Math.min(data.groups.length, (page+1)*PER_PAGE) - 1;   // the next set slides into its place
    if(cmpIdx > last) closeCompare(); else renderCompare();
  }catch(err){ toast("Something went wrong: " + err.message, 12000); renderCompare(); }
}
document.getElementById("cmpDelete").onclick = compareDelete;
document.getElementById("go").onclick = async () => {
  const allGone = (allSets ? data.groups : pageGroups()).filter(g => g.every(p => marked.has(p.id))).length;
  let q = `Add ${plural(marked.size, noun)} to the album “${data.album}” in Photos?\n\nNothing is deleted yet: you'll delete them from that album yourself.`;
  if(allGone) q = `⚠️ In ${plural(allGone, "set")} you've marked EVERY ${noun}, so none would be kept.\n\n` + q;
  if(!confirm(q)) return;
  if(allSets){
    const pages = Math.ceil(data.groups.length / PER_PAGE);
    if(pages > 1 && !confirm(`Last check: this covers all ${pages} pages, including ones you may not have looked at. Continue with all ${marked.size}?`)) return;
  }
  const go = document.getElementById("go"); go.disabled = true; go.textContent = "Working…";
  try{ await sendToDelete([...marked]); marked.clear(); allSets = false; render(); }
  catch(err){ toast("Something went wrong: " + err.message, 12000); updateStats(); }
};

(async () => {
  data = await (await fetch("/api/groups")).json();
  noun = data.kind === "video" ? "video" : "photo";
  document.getElementById("title").textContent = `Review ${noun}s`;
  document.title = `Sift - Review ${noun}s`;
  document.getElementById("cmpHint").textContent = `← → switch set · 1–9 keep/delete · Z zoom · ⌫ move marked to the album · Esc close`;
  document.getElementById("help").innerHTML =
    `Click a ${noun} to switch it between <b style="color:var(--keep)">KEEP</b> and <b style="color:var(--del)">DELETE</b>. ` +
    `<b>★ Best</b> is the copy Sift suggests keeping. <b>Select suggested</b> marks only the copies Sift is sure about; ` +
    `ones marked <b style="color:var(--rev)">Review</b> (similar shots, look-alikes) are for you to decide. ` +
    `Use <b>⤢ Expand &amp; compare</b> to see a set big and side by side${noun === "photo" ? " in full quality, zooming together" : ", and play them together"}. ` +
    `Marked ${noun}s go to the album “${esc(data.album)}”, where you delete them in Photos (they stay in Recently Deleted for 30 days).`;
  document.getElementById("sort").value = sortBy;
  data.groups.sort(SORTS[sortBy]); render();
})();
</script>
</body></html>
"""
