# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "osxphotos>=0.70; sys_platform == 'darwin'",
#   "numpy>=2.0",
#   "pillow>=10",
#   "imageio-ffmpeg>=0.5",
# ]
# ///
"""
Sift — the Mac app.

A small window around sift.py, so it can be used without Terminal.
The scan runs in a separate process (this same program started with --worker).
That process sends its questions and progress here as "@@{json}" lines, and
reads the answers on stdin. Everything else it prints goes into the log.

  uv run app.py               # open the window, straight from the code
  uv run app.py --self-test   # check the packages and ffmpeg work
"""
from __future__ import annotations

import json
import os
import queue
import signal
import subprocess
import sys
import threading
import webbrowser
from pathlib import Path

APP_NAME = "Sift"
FDA_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
AUTOMATION_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
BUNDLE_ID = "com.rajvirb.sift"         # as in sift.spec


# ---------------------------------------------------------------- worker
def worker_command(*args: str) -> list[str]:
    if getattr(sys, "frozen", False):          # inside the built .app
        return [sys.executable, "--worker", *args]
    return [sys.executable, os.path.abspath(__file__), "--worker", *args]


def run_worker(args: list[str]) -> None:
    import sift
    sys.argv = [APP_NAME, *args]
    sift.main()


def self_test() -> int:
    """Used by the build to check the finished app actually works."""
    import tempfile
    import sift as vc
    failed = False

    def report(ok: bool, what: str, warn_only: bool = False) -> None:
        nonlocal failed
        print(f"{'ok  ' if ok else 'WARN' if warn_only else 'FAIL'}  {what}")
        failed |= not ok and not warn_only

    mods = ["numpy", "PIL", "imageio_ffmpeg", "tkinter", "review"]
    if sys.platform == "darwin":
        mods += ["osxphotos", "photoscript"]
    for mod in mods:
        try:
            __import__(mod)
            report(True, f"import {mod}")
        except Exception as exc:
            report(False, f"import {mod}: {exc}")
    try:
        import tkinter
        root = tkinter.Tk()
        root.destroy()
        report(True, f"open a window (Tk {tkinter.TkVersion})")
    except Exception as exc:
        report(False, f"open a window: {exc}")

    ff = vc.ffmpeg_exe()
    report(os.path.exists(ff), f"ffmpeg at {ff}")
    try:                       # the review page's full-quality images (sips on a Mac)
        import review
        from PIL import Image
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, "test.png")
            Image.new("RGB", (5000, 3000), (40, 120, 200)).save(src)
            jpeg = review.render_jpeg(src, 4096, 90, 5000, 3000)
            from io import BytesIO
            size = Image.open(BytesIO(jpeg)).size
        report(max(size) == 4096, f"full-quality image for the review page: {size}")
    except Exception as exc:
        report(False, f"full-quality image for the review page: {exc}")
    with tempfile.TemporaryDirectory() as td:
        clip = os.path.join(td, "test.mp4")
        subprocess.run([ff, "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=320x240:d=3",
                        "-pix_fmt", "yuv420p", clip], capture_output=True)
        frames = vc.hash_video_frames(ff, clip, vc.probe_duration(ff, clip)) if os.path.exists(clip) else []
        report(len(frames) >= vc.MIN_INFORMATIVE, f"fingerprint a test video ({len(frames)} frames)")
    if sys.platform == "darwin":
        # compile (not run) the Photos import script, which checks it against Photos' dictionary
        with tempfile.TemporaryDirectory() as td:
            try:
                r = subprocess.run(["osacompile", "-o", os.path.join(td, "import.scpt"), "-e",
                                    vc.IMPORT_SCRIPT], capture_output=True, text=True, timeout=120)
                report(r.returncode == 0, "Photos import script compiles"
                       + (f": {r.stderr.strip()}" if r.returncode else ""))
            except subprocess.TimeoutExpired:
                report(False, "Photos import script: osacompile timed out", warn_only=True)
    enc = vc.pick_encoder(ff)
    report(bool(enc), f"HEVC encoder for making smaller copies: {enc or 'none found'}", warn_only=True)
    if sys.platform == "darwin" and enc:
        # a smaller copy should keep the camera details, as Apple's own video framework sees them
        import AVFoundation
        import Foundation

        def apple_sees(path: str) -> dict:
            """The QuickTime metadata Apple's video framework reads from a file and its video track."""
            import threading
            asset = AVFoundation.AVURLAsset.URLAssetWithURL_options_(
                Foundation.NSURL.fileURLWithPath_(path), None)
            got = []

            def load(thing) -> None:
                done = threading.Event()

                def loaded(items, error):
                    got.extend(items or [])
                    done.set()
                thing.loadMetadataForFormat_completionHandler_(
                    AVFoundation.AVMetadataFormatQuickTimeMetadata, loaded)
                done.wait(30)

            load(asset)
            for track in asset.tracksWithMediaType_(AVFoundation.AVMediaTypeVideo) or []:
                load(track)
            return {str(i.key()): str(i.value()) for i in got}

        def add_lens_details(path: str, lens: str) -> None:
            """Give a test clip's video track lens details, stored the way iPhones store them."""
            import struct
            key = b"com.apple.quicktime.camera.lens_model"
            hdlr = vc._box(b"hdlr", b"\0" * 8 + b"mdta" + b"\0" * 13)
            keys = vc._box(b"keys", struct.pack(">II", 0, 1) + struct.pack(">I4s", 8 + len(key), b"mdta") + key)
            value = lens.encode()
            ilst = vc._box(b"ilst", vc._box(struct.pack(">I", 1),
                                              vc._box(b"data", struct.pack(">II", 1, 0) + value)))
            meta = vc._box(b"meta", hdlr + keys + ilst)
            pos, old, mdat = vc._read_moov(path)
            children = vc._children(old, (0, 8, len(old)))
            track = vc._video_track(old, children)
            parts = [old[o:o + n] if (o, n) != (track[1], track[3]) else
                     vc._box(b"trak", old[o + h:o + n] + meta) for typ, o, h, n in children]
            vc._write_moov(path, pos, old, bytearray(vc._box(b"moov", b"".join(parts))), mdat)

        with tempfile.TemporaryDirectory() as td:
            # noisy, high quality, so that compressing it really does make it smaller
            src = os.path.join(td, "camera.mov")
            subprocess.run([ff, "-nostdin", "-v", "error", "-f", "lavfi",
                            "-i", "testsrc2=s=1280x720:d=2,noise=alls=40:allf=t",
                            "-c:v", "mpeg4", "-q:v", "1", "-metadata", "com.apple.quicktime.make=Apple",
                            "-metadata", "com.apple.quicktime.model=iPhone 15 Pro",
                            "-movflags", "use_metadata_tags", src], capture_output=True)
            vc.move_metadata_to_moov(src)        # lay it out like an iPhone video
            lens = "iPhone 15 Pro back triple camera 6.765mm f/1.78"
            add_lens_details(src, lens)
            report(apple_sees(src).get("com.apple.quicktime.camera.lens_model") == lens,
                   f"test clip has camera details: {apple_sees(src)}")
            fixed = os.path.join(td, "fixed.mov")
            ok, why = vc.encode_hevc(ff, enc, src, fixed, vc.Plan("same", 720, 1500, 0, "test"))
            seen = apple_sees(fixed) if ok else {}
            report(ok and seen.get("com.apple.quicktime.model") == "iPhone 15 Pro"
                   and seen.get("com.apple.quicktime.camera.lens_model") == lens,
                   f"smaller copy keeps camera and lens details for Apple's software: {seen or why}")
    return 1 if failed else 0


# ---------------------------------------------------------------- window
def asset(name: str) -> Path:
    """A file from the assets folder, inside the built app or next to this script."""
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    return base / "assets" / name


def eta(seconds: float) -> str:
    if seconds < 60:
        return "less than a minute left"
    minutes = round(seconds / 60)
    if minutes < 60:
        return f"about {minutes} minute{'s' if minutes != 1 else ''} left"
    hours = seconds / 3600
    return f"about {hours:.0f} hour{'s' if round(hours) != 1 else ''} left"


class App:
    def __init__(self) -> None:
        import tkinter as tk
        from tkinter import font, ttk
        self.tk, self.ttk = tk, ttk
        self.root = root = tk.Tk()
        root.title(APP_NAME)
        root.geometry("620x520")
        root.minsize(540, 460)
        self.mac = root.tk.call("tk", "windowingsystem") == "aqua"

        # ---- look: the Mac's own theme, fonts and colours; a tidy theme elsewhere
        style = ttk.Style(root)
        if not self.mac and "clam" in style.theme_names():
            style.theme_use("clam")
        base = font.nametofont("TkDefaultFont")
        size = base.cget("size")

        def sized(points: int, weight: str = "normal") -> font.Font:
            f = base.copy()
            f.configure(size=points if size > 0 else -points, weight=weight)
            return f
        n = abs(size) or 13
        self.bold = sized(n, "bold")
        self.title_font = sized(n + 9, "bold")
        self.head_font = sized(n + 3, "bold")
        self.big_font = sized(n + 15, "bold")
        muted = "systemSecondaryLabelColor" if self.mac else "#6e6e73"
        style.configure("Muted.TLabel", foreground=muted)
        style.configure("Title.TLabel", font=self.title_font)
        style.configure("Head.TLabel", font=self.head_font)
        style.configure("Bold.TLabel", font=self.bold)
        style.configure("Big.TLabel", font=self.big_font)
        style.configure("Step.TLabel", font=self.head_font, foreground="#2f5bea" if not self.mac
                        else "systemBlueColor")
        style.configure("Option.TRadiobutton", font=self.bold)
        self.bg = style.lookup("TFrame", "background") or None

        self.icon = None
        try:
            self.icon = tk.PhotoImage(file=str(asset("icon.png")))
            root.iconphoto(True, self.icon)           # also the Dock icon when run from the code
        except Exception:
            pass

        self.proc: subprocess.Popen | None = None
        self.events: queue.Queue = queue.Queue()
        self.context: list[str] = []     # recent lines, shown above each question
        self.report: str | None = None
        self.summary: dict = {}
        self.stopping = False
        self.needs_fda = False
        self.asking = False
        self.progress_label, self.progress_started = "", 0.0
        self.review_proc: subprocess.Popen | None = None   # the review page's server, once started
        self.review_url = ""

        outer = ttk.Frame(root, padding=(26, 22, 26, 20))
        outer.pack(fill="both", expand=True)

        # ---- header: icon, name, one line about what it does
        header = ttk.Frame(outer)
        header.pack(fill="x")
        if self.icon:
            self.small_icon = self.icon.subsample(4)
            ttk.Label(header, image=self.small_icon).pack(side="left", padx=(0, 14))
        words = ttk.Frame(header)
        words.pack(side="left", fill="x", expand=True)
        ttk.Label(words, text=APP_NAME, style="Title.TLabel").pack(anchor="w")
        ttk.Label(words, style="Muted.TLabel", wraplength=440, justify="left",
                  text="Finds duplicate and similar videos and photos in your Photos library. "
                       "It never deletes anything.").pack(anchor="w", pady=(2, 0))
        ttk.Separator(outer).pack(fill="x", pady=(18, 18))

        # ---- the middle: one of four panels
        self.body = ttk.Frame(outer)
        self.body.pack(fill="both", expand=True)
        self.panels = {name: ttk.Frame(self.body) for name in ("welcome", "running", "done", "problem")}

        welcome = self.panels["welcome"]
        ttk.Label(welcome, text="How it works", style="Head.TLabel").pack(anchor="w", pady=(0, 10))
        for k, line in enumerate((
                "Choose videos or photos, which albums to look in, and how strict to be.",
                "It finds copies, similar shots and the things taking the most space. "
                "A big library can take a while.",
                "Check what it found in a report and in an album in Photos, then delete what "
                "you don't need yourself."), 1):
            row = ttk.Frame(welcome)
            row.pack(fill="x", pady=5)
            ttk.Label(row, text=str(k), style="Step.TLabel", width=2).pack(side="left", anchor="n")
            ttk.Label(row, text=line, wraplength=480, justify="left").pack(side="left", fill="x")
        ttk.Label(welcome, style="Muted.TLabel", wraplength=520, justify="left",
                  text="Reports are saved in a folder on your Desktop.").pack(anchor="w", pady=(14, 0))

        running = self.panels["running"]
        self.status = ttk.Label(running, text="Starting…", style="Head.TLabel", wraplength=540, justify="left")
        self.status.pack(anchor="w")
        self.bar = ttk.Progressbar(running, mode="determinate", maximum=1)
        self.bar.pack(fill="x", pady=(14, 6))
        self.detail = ttk.Label(running, text="", style="Muted.TLabel")
        self.detail.pack(anchor="w")

        done = self.panels["done"]
        self.done_big = ttk.Label(done, text="", style="Big.TLabel", wraplength=540, justify="left")
        self.done_big.pack(anchor="w")
        self.done_line = ttk.Label(done, text="", style="Bold.TLabel", wraplength=540, justify="left")
        self.done_line.pack(anchor="w", pady=(6, 0))
        self.done_more = ttk.Label(done, text="", style="Muted.TLabel", wraplength=540, justify="left")
        self.done_more.pack(anchor="w", pady=(10, 0))

        problem = self.panels["problem"]
        self.problem_head = ttk.Label(problem, text="", style="Head.TLabel", wraplength=540, justify="left")
        self.problem_head.pack(anchor="w")
        self.problem_text = ttk.Label(problem, text="", style="Muted.TLabel", wraplength=540, justify="left")
        self.problem_text.pack(anchor="w", pady=(8, 0))

        # ---- details: the scan's own words, hidden until asked for
        self.logbox = ttk.Frame(outer)
        self.log = tk.Text(self.logbox, height=8, wrap="word", state="disabled", borderwidth=0,
                           highlightthickness=0, font="TkFixedFont", padx=8, pady=6)
        scroll = ttk.Scrollbar(self.logbox, command=self.log.yview)
        self.log.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.log.pack(side="left", fill="both", expand=True)

        # ---- buttons along the bottom
        buttons = ttk.Frame(outer)
        buttons.pack(fill="x", side="bottom", pady=(16, 0))
        self.details_btn = ttk.Button(buttons, text="Show details", command=self.toggle_details)
        self.details_btn.pack(side="left")
        self.start_btn = ttk.Button(buttons, text="Start scan", command=self.start, default="active")
        self.stop_btn = ttk.Button(buttons, text="Stop", command=self.stop)
        self.review_btn = ttk.Button(buttons, text="Review & choose", command=self.open_review, default="active")
        self.report_btn = ttk.Button(buttons, text="Open report", command=self.open_report)
        self.photos_btn = ttk.Button(buttons, text="Open Photos", command=self.open_photos)
        self.show("welcome", [self.start_btn])

        root.protocol("WM_DELETE_WINDOW", self.quit)
        root.after(50, self.poll)

    def run(self) -> None:
        self.root.mainloop()

    def show(self, panel: str, buttons: list) -> None:
        """Show one panel, and these buttons (right to left: the first is the main one)."""
        for p in self.panels.values():
            p.pack_forget()
        self.panels[panel].pack(fill="both", expand=True)
        for b in (self.start_btn, self.stop_btn, self.review_btn, self.report_btn, self.photos_btn):
            b.pack_forget()
        for k, b in enumerate(buttons):
            b.pack(side="right", padx=(0, 8) if k else 0)

    def toggle_details(self) -> None:
        if self.logbox.winfo_ismapped():
            self.logbox.pack_forget()
            self.details_btn.configure(text="Show details")
        else:
            self.logbox.pack(fill="both", expand=True, pady=(14, 0))   # between the panel and the buttons
            self.details_btn.configure(text="Hide details")

    # ---- running the scan
    def start(self) -> None:
        self.stop_review()
        self.stop_btn.configure(text="Stop")
        self.show("running", [self.stop_btn])
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.bar.configure(value=0, maximum=1)
        self.detail.configure(text="")
        self.context, self.report, self.summary = [], None, {}
        self.stopping, self.needs_fda = False, False
        self.set_status("Starting…")
        env = {**os.environ, "SIFT_GUI": "1", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8"}
        self.proc = subprocess.Popen(
            worker_command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1, env=env)
        threading.Thread(target=self.read_output, args=(self.proc,), daemon=True).start()

    def read_output(self, proc: subprocess.Popen) -> None:
        for line in proc.stdout:
            self.events.put(("line", line.rstrip("\n")))
        self.events.put(("exit", proc.wait()))

    def poll(self) -> None:
        if not self.asking:
            try:
                while True:
                    kind, data = self.events.get_nowait()
                    if kind == "line":
                        self.handle_line(data)
                    elif kind == "review":
                        self.handle_review_line(data)
                    elif kind == "exit":
                        self.finished(data)
            except queue.Empty:
                pass
        self.root.after(50, self.poll)

    def handle_line(self, line: str) -> None:
        if line.startswith("@@"):
            try:
                msg = json.loads(line[2:])
            except ValueError:
                msg = None
            if isinstance(msg, dict):
                self.handle_message(msg)
                return
        text = line.strip()
        if not text:
            return
        self.append_log(text if not line.startswith(" ") else "  " + text)
        self.context = (self.context + [text])[-8:]
        if text.startswith("Report: "):
            self.report = text[len("Report: "):]
        if not line.startswith(" "):           # top-level lines are the stages
            self.set_status(text)

    def answer(self, text: str) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.write(text + "\n")
                self.proc.stdin.flush()
            except OSError:
                pass

    def handle_message(self, msg: dict) -> None:
        kind = msg.get("kind")
        if kind == "progress":
            import time
            n, i = max(int(msg.get("n", 1)), 1), int(msg.get("i", 0))
            label = msg.get("label", "")
            if label != self.progress_label or i <= 1:
                self.progress_label, self.progress_started = label, time.time()
            self.bar.configure(maximum=n, value=i)
            text = f"{label} · {i:,} of {n:,}"
            spent = time.time() - self.progress_started
            if 0 < i < n and spent > 5:
                text += " · " + eta(spent * (n - i) / i)
            self.detail.configure(text=text)
        elif kind == "ask":
            self.answer(self.ask(msg.get("question", ""), msg.get("buttons", ["OK"]), msg.get("default"),
                                 self.context, msg.get("details") or None))
            self.context = []
        elif kind == "choose":
            answer = self.choose(msg.get("question", ""), msg.get("items", []), int(msg.get("total", 0)),
                                 msg.get("noun", "video"), bool(msg.get("largest")))
            self.context = []
            if answer == "cancel":
                self.stopping = True
            self.answer(answer)
        elif kind == "summary":
            self.summary = msg
        elif kind == "full_disk_access":
            self.needs_fda = True
        elif kind == "automation":
            self.ask_for_automation()

    # ---- the review page: served by a second process, so it keeps going after the scan
    def start_review(self, folder: str) -> None:
        self.stop_review()
        env = {**os.environ, "SIFT_GUI": "1", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8"}
        self.review_proc = proc = subprocess.Popen(
            worker_command("--review", folder), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1, env=env)

        def read() -> None:
            for line in proc.stdout:
                self.events.put(("review", line.rstrip("\n")))
        threading.Thread(target=read, daemon=True).start()

    def handle_review_line(self, line: str) -> None:
        if line.startswith("@@"):
            try:
                msg = json.loads(line[2:])
            except ValueError:
                return
            if msg.get("kind") == "review":
                self.review_url = msg.get("url", "")
        elif line.strip():
            self.append_log(line.strip())

    def open_review(self) -> None:
        if self.review_proc and self.review_proc.poll() is None and self.review_url:
            webbrowser.open(self.review_url)
        elif self.summary.get("folder"):
            self.start_review(self.summary["folder"])      # it opens the page when it's ready

    def stop_review(self) -> None:
        if self.review_proc and self.review_proc.poll() is None:
            self.review_proc.terminate()
        self.review_proc, self.review_url = None, ""

    def finished(self, code: int) -> None:
        self.proc = None
        self.start_btn.configure(text="Scan again")
        if self.report:
            self.show_results()
        elif self.needs_fda:
            self.show_problem("Sift needs Full Disk Access",
                              "It needs it to read your Photos library. Follow the steps in the window "
                              "that opened, then quit Sift and open it again.")
            self.ask_for_fda()
        elif self.stopping:
            self.show_problem("Stopped", "Nothing was deleted. You can start again at any time.")
        else:
            self.show_problem("Something went wrong",
                              f"The scan stopped unexpectedly (code {code}). Click Show details to see why.")

    def show_results(self) -> None:
        s = self.summary
        noun = s.get("noun", "video")
        sets, delete, review = s.get("sets", 0), s.get("delete", 0), s.get("review", 0)
        if not s:
            self.done_big.configure(text="All done")
            self.done_line.configure(text="The report has opened in your browser.")
        elif sets:
            self.done_big.configure(text=f"{s.get('saving', '0 B')} could be freed" if delete else
                                    f"{sets:,} set{'s' if sets != 1 else ''} to look at")
            parts = [f"{sets:,} set{'s' if sets != 1 else ''} of duplicate or similar {noun}s"]
            if delete:
                parts.append(f"{delete:,} {'copy' if delete == 1 else 'copies'} to delete")
            if review:
                parts.append(f"{review:,} to review")
            self.done_line.configure(text=" · ".join(parts))
        else:
            self.done_big.configure(text=f"No duplicate {noun}s found")
            self.done_line.configure(text=f"Checked {s.get('scanned', 0):,} {noun}s.")
        if sets and s.get("folder"):
            self.start_review(s["folder"])
            more = [f"The review page has opened in your browser: go through the sets there and mark what "
                    f"to delete. Marked {noun}s go to the album “Sift - To Delete” in Photos, where you "
                    "delete them yourself. Nothing has been deleted."]
        else:
            self.open_report()
            more = ["The report has opened in your browser. Nothing was deleted."]
        if s.get("compressed"):
            more.append(f"{s['compressed']:,} smaller copies were made.")
        if s.get("album"):
            more.append(f"They're also in the album “{s['album']}” in Photos, "
                        "where you can check and delete them on your Mac or iPhone.")
        self.done_more.configure(text=" ".join(more))
        main = [self.review_btn] if sets and s.get("folder") else []
        buttons = main + [self.report_btn] + ([self.photos_btn] if s.get("album") else []) + [self.start_btn]
        self.report_btn.configure(default="normal" if main else "active")
        self.start_btn.configure(default="normal")
        self.show("done", buttons)

    def show_problem(self, head: str, text: str) -> None:
        self.problem_head.configure(text=head)
        self.problem_text.configure(text=text)
        self.start_btn.configure(default="active")
        self.show("problem", [self.start_btn])

    def stop(self) -> None:
        if not self.proc:
            return
        if not self.stopping:
            # like pressing Ctrl-C: the scan keeps what it has done so far
            self.stopping = True
            self.proc.send_signal(signal.SIGINT)
            self.stop_btn.configure(text="Force stop")
            self.set_status("Stopping…")
        else:
            self.proc.kill()

    def quit(self) -> None:
        if self.proc and self.proc.poll() is None:
            if self.ask("A scan is still running. Stop it and quit?", ["Quit", "Keep scanning"],
                        "Keep scanning") != "Quit":
                return
            self.proc.kill()
        self.stop_review()
        self.root.destroy()

    # ---- pieces of the window
    def set_status(self, text: str) -> None:
        self.status.configure(text=text)

    def append_log(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def open_report(self) -> None:
        if self.report:
            webbrowser.open(Path(self.report).resolve().as_uri())

    def open_photos(self) -> None:
        subprocess.run(["open", "-a", "Photos"])

    def scroll_with_wheel(self, win, canvas) -> None:
        """Scroll a canvas with a mouse wheel or trackpad, whichever events this Tk sends:
        Tk 8.6 sends trackpad scrolling as <MouseWheel>, Tk 9 as <TouchpadScroll>."""
        canvas.configure(yscrollincrement=1)      # so a "unit" is one pixel

        def wheel(e):
            d = e.delta                           # 120 a notch on a mouse; small steps from a Tk 8.6 trackpad
            canvas.yview_scroll(int(-d * 30 / 120) if abs(d) >= 120 else -d * 10, "units")

        def touchpad(e):
            dx, dy = (int(v) for v in self.root.tk.splitlist(
                self.root.tk.call("tk::PreciseScrollDeltas", e.delta)))
            if dy:
                canvas.yview_scroll(-dy, "units")

        win.bind("<MouseWheel>", wheel)
        win.bind("<Button-4>", lambda e: canvas.yview_scroll(-30, "units"))   # X11
        win.bind("<Button-5>", lambda e: canvas.yview_scroll(30, "units"))
        try:
            win.bind("<TouchpadScroll>", touchpad)
        except self.tk.TclError:                  # Tk 8.6 has no such event
            pass

    def dialog(self, title: str = APP_NAME, size: str | None = None):
        tk, ttk = self.tk, self.ttk
        self.asking = True
        win = tk.Toplevel(self.root)
        win.title(title)
        win.transient(self.root)
        if size:
            win.geometry(size)
        else:
            win.resizable(False, False)
        body = ttk.Frame(win, padding=(24, 20, 24, 18))
        body.pack(fill="both", expand=True)
        return win, body

    def ask(self, question: str, buttons: list[str], default: str | None,
            context: list[str] | None = None, details: list[str] | None = None) -> str:
        """A question with a row of buttons, in the order given (callers put the default on
        the right where that's the Mac way) — or, with a line describing each choice, a
        list of options to pick from."""
        if details and len(details) == len(buttons):
            return self.ask_options(question, buttons, default, details)
        ttk = self.ttk
        default = default if default in buttons else buttons[-1]
        answer = [default]
        win, body = self.dialog()
        ttk.Label(body, text=question, style="Head.TLabel", wraplength=480, justify="left").pack(anchor="w")
        if context:
            ttk.Label(body, text="\n".join(context), style="Muted.TLabel", wraplength=480,
                      justify="left").pack(anchor="w", pady=(10, 0))
        row = ttk.Frame(body)
        row.pack(fill="x", pady=(20, 0))

        def choose(b: str) -> None:
            answer[0] = b
            win.destroy()

        for b in reversed(buttons):           # in the order given, left to right
            ttk.Button(row, text=b, command=lambda b=b: choose(b),
                       default="active" if b == default else "normal").pack(side="right", padx=(8, 0))
        win.bind("<Return>", lambda e: choose(default))
        win.bind("<Escape>", lambda e: choose(default))
        win.protocol("WM_DELETE_WINDOW", lambda: choose(default))
        self.show_modal(win)
        return answer[0]

    def ask_options(self, question: str, options: list[str], default: str | None, details: list[str]) -> str:
        tk, ttk = self.tk, self.ttk
        choice = tk.StringVar(value=default if default in options else options[0])
        win, body = self.dialog()
        ttk.Label(body, text=question, style="Head.TLabel", wraplength=460, justify="left").pack(anchor="w")
        for option, line in zip(options, details):
            row = ttk.Frame(body)
            row.pack(fill="x", pady=(14, 0))
            ttk.Radiobutton(row, text=option, value=option, variable=choice,
                            style="Option.TRadiobutton").pack(anchor="w")
            text = ttk.Label(row, text=line, style="Muted.TLabel", wraplength=430, justify="left")
            text.pack(anchor="w", padx=(26, 0))
            text.bind("<Button-1>", lambda e, o=option: choice.set(o))
        row = ttk.Frame(body)
        row.pack(fill="x", pady=(22, 0))
        ttk.Button(row, text="Continue", command=win.destroy, default="active").pack(side="right")
        win.bind("<Return>", lambda e: win.destroy())
        win.bind("<Escape>", lambda e: win.destroy())
        win.protocol("WM_DELETE_WINDOW", win.destroy)
        self.show_modal(win)
        return choice.get()

    def choose(self, question: str, items: list[dict], total: int, noun: str = "video",
               largest: bool = False) -> str:
        """Pick everything, tick folders and albums, or (with largest) just the N biggest.
        Returns "all", "cancel", "largest:N", or a JSON list of the ticked items' ids."""
        tk, ttk = self.tk, self.ttk
        answer = ["cancel"]
        win, body = self.dialog(size="540x540")
        win.minsize(440, 380)
        ttk.Label(body, text=question, style="Head.TLabel").pack(anchor="w")
        mode = tk.StringVar(value="all")
        ttk.Radiobutton(body, text=f"Everything in my library ({total:,} {noun}s)", variable=mode,
                        value="all").pack(anchor="w", pady=(12, 4))
        if largest:
            how_many = tk.StringVar(value=str(min(50, total) or 50))
            row = ttk.Frame(body)
            row.pack(anchor="w", pady=(0, 4))
            ttk.Radiobutton(row, text="Only my largest", variable=mode, value="largest").pack(side="left")
            spin = ttk.Spinbox(row, from_=1, to=max(total, 1), width=6, textvariable=how_many,
                               command=lambda: mode.set("largest"))
            spin.pack(side="left", padx=(6, 6))
            spin.bind("<FocusIn>", lambda e: mode.set("largest"))
            ttk.Label(row, text=f"{noun}s").pack(side="left")
        ttk.Radiobutton(body, text="Only the folders and albums I tick:", variable=mode,
                        value="some").pack(anchor="w")

        # a scrollable list of tick boxes, indented to show what's inside each folder
        box = ttk.Frame(body, padding=(0, 8, 0, 0))
        box.pack(fill="both", expand=True)
        canvas = tk.Canvas(box, highlightthickness=0, borderwidth=0)
        if self.bg:
            canvas.configure(background=self.bg)
        scroll = ttk.Scrollbar(box, command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        inner = ttk.Frame(canvas)
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        self.scroll_with_wheel(win, canvas)

        ticks = [tk.BooleanVar(value=False) for _ in items]

        def toggled(k: int) -> None:
            mode.set("some")
            if items[k].get("folder"):         # a folder ticks or unticks what's inside it
                for j in range(k + 1, len(items)):
                    if items[j].get("depth", 0) <= items[k].get("depth", 0):
                        break
                    ticks[j].set(ticks[k].get())
            if not ticks[k].get():             # and a folder can't stay ticked without it
                depth = items[k].get("depth", 0)
                for j in range(k - 1, -1, -1):
                    if items[j].get("depth", 0) < depth:
                        ticks[j].set(False)
                        depth = items[j].get("depth", 0)

        for k, item in enumerate(items):
            count = int(item.get("count", 0))
            text = f"{item.get('label', '')}  ({count:,} {noun}{'' if count == 1 else 's'})"
            row = ttk.Frame(inner)
            row.pack(anchor="w", padx=(22 * int(item.get("depth", 0)), 0), pady=2)
            ttk.Checkbutton(row, variable=ticks[k], command=lambda k=k: toggled(k)).pack(side="left")
            label = ttk.Label(row, text=text, style="Bold.TLabel" if item.get("folder") else "TLabel")
            label.pack(side="left")

            def click(e, k=k) -> None:        # clicking the name ticks it too
                ticks[k].set(not ticks[k].get())
                toggled(k)
            label.bind("<Button-1>", click)

        def tick_all(value: bool) -> None:
            mode.set("some" if value else mode.get())
            for t in ticks:
                t.set(value)

        note = ttk.Label(body, text="", style="Muted.TLabel")
        note.pack(anchor="w", pady=(6, 0))

        def scan() -> None:
            if mode.get() == "all":
                answer[0] = "all"
            elif mode.get() == "largest":
                n = how_many.get().strip()
                if not n.isdigit() or int(n) < 1:
                    note.configure(text=f"Type how many {noun}s to scan, such as 50.")
                    return
                answer[0] = f"largest:{int(n)}"
            else:
                picked = [item.get("id") for item, t in zip(items, ticks) if t.get()]
                if not picked:
                    note.configure(text="Tick at least one folder or album, or choose Everything.")
                    return
                answer[0] = json.dumps(picked)
            win.destroy()

        def cancel() -> None:
            answer[0] = "cancel"
            win.destroy()

        row = ttk.Frame(body)
        row.pack(fill="x", pady=(12, 0))
        ttk.Button(row, text="Select all", command=lambda: tick_all(True)).pack(side="left")
        ttk.Button(row, text="Clear", command=lambda: tick_all(False)).pack(side="left", padx=(8, 0))
        ttk.Button(row, text="Scan", command=scan, default="active").pack(side="right", padx=(8, 0))
        ttk.Button(row, text="Cancel", command=cancel).pack(side="right")
        win.bind("<Return>", lambda e: scan())
        win.bind("<Escape>", lambda e: cancel())
        win.protocol("WM_DELETE_WINDOW", cancel)
        self.show_modal(win)
        return answer[0]

    def show_modal(self, win) -> None:
        """Bring a dialog to the front and wait until it's closed."""
        self.root.deiconify()
        self.root.lift()
        win.lift()
        win.focus_force()
        win.grab_set()
        self.root.bell()
        self.root.wait_window(win)
        self.asking = False

    def ask_for_automation(self) -> None:
        if getattr(sys, "frozen", False):
            who, reset = APP_NAME, f"tccutil reset AppleEvents {BUNDLE_ID}"
        else:                                  # run from the code: macOS asks on Terminal's behalf
            who, reset = "Terminal (or Visual Studio Code)", "tccutil reset AppleEvents com.apple.Terminal"
        steps = [
            "macOS isn't letting Sift control Photos, so it can't make albums, "
            "download videos from iCloud or import the smaller copies. The scan carries on without them.",
            "",
            "1. Click Open Settings.",
            f"2. Under {who}, turn on Photos.",
            "3. Run the scan again.",
            "",
            f"If {who} isn't in the list, macOS needs to ask again. Open Terminal, run this, "
            "then run the scan again and click OK when asked:",
            f"    {reset}",
        ]
        if self.ask("Open Automation settings?", ["Not now", "Open Settings"],
                    "Open Settings", steps) == "Open Settings":
            subprocess.run(["open", AUTOMATION_SETTINGS])

    def ask_for_fda(self) -> None:
        steps = [
            "To read your Photos library, Sift needs Full Disk Access. You only do this once.",
            "",
            "1. Click Open Settings.",
            "2. Turn on Sift in the list. If it isn't there, click +, "
            "choose Sift from Applications and turn it on.",
            "3. Quit Sift and open it again.",
        ]
        if self.ask("Open Full Disk Access settings?", ["Not now", "Open Settings"],
                    "Open Settings", steps) == "Open Settings":
            subprocess.run(["open", FDA_SETTINGS])


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        run_worker(sys.argv[2:])
    elif "--self-test" in sys.argv:
        sys.exit(self_test())
    else:
        App().run()
