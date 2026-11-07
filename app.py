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
Video Cleanup — the Mac app.

A small window around video_cleanup.py, so it can be used without Terminal.
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

APP_NAME = "Video Cleanup"
REPORT_DIR = Path.home() / "Desktop" / "Video Cleanup Report"
FDA_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
AUTOMATION_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
BUNDLE_ID = "com.rajvirb.videocleanup"         # as in video_cleanup.spec


# ---------------------------------------------------------------- worker
def worker_command(*args: str) -> list[str]:
    if getattr(sys, "frozen", False):          # inside the built .app
        return [sys.executable, "--worker", *args]
    return [sys.executable, os.path.abspath(__file__), "--worker", *args]


def run_worker(args: list[str]) -> None:
    import video_cleanup
    sys.argv = [APP_NAME, *args]
    video_cleanup.main()


def self_test() -> int:
    """Used by the build to check the finished app actually works."""
    import tempfile
    import video_cleanup as vc
    failed = False

    def report(ok: bool, what: str, warn_only: bool = False) -> None:
        nonlocal failed
        print(f"{'ok  ' if ok else 'WARN' if warn_only else 'FAIL'}  {what}")
        failed |= not ok and not warn_only

    mods = ["numpy", "PIL", "imageio_ffmpeg", "tkinter"]
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
class App:
    def __init__(self) -> None:
        import tkinter as tk
        from tkinter import font, ttk
        self.tk, self.ttk = tk, ttk
        self.root = root = tk.Tk()
        root.title(APP_NAME)
        root.geometry("640x480")
        root.minsize(520, 380)
        self.bold = font.nametofont("TkDefaultFont").copy()
        self.bold.configure(weight="bold")

        self.proc: subprocess.Popen | None = None
        self.events: queue.Queue = queue.Queue()
        self.context: list[str] = []     # recent lines, shown above each question
        self.report: str | None = None
        self.stopping = False
        self.needs_fda = False
        self.asking = False

        frame = ttk.Frame(root, padding=20)
        frame.pack(fill="both", expand=True)
        title = self.bold.copy()
        title.configure(size=20)
        ttk.Label(frame, text=APP_NAME, font=title).pack(anchor="w")
        ttk.Label(frame, wraplength=580, justify="left", text=(
            "Finds duplicate, trimmed and space-wasting videos in your Photos library and "
            "makes a report you can open in your browser. It never deletes anything: you "
            "check its suggestions and delete videos yourself in Photos.")).pack(anchor="w", pady=(4, 14))
        self.status = ttk.Label(frame, wraplength=580, justify="left", font=self.bold,
                                text=f"The report will be saved on your Desktop, in “{REPORT_DIR.name}”.")
        self.status.pack(anchor="w")
        self.bar = ttk.Progressbar(frame, mode="determinate", maximum=1)
        self.bar.pack(fill="x", pady=(8, 2))
        self.detail = ttk.Label(frame, text="")
        self.detail.pack(anchor="w")

        logbox = ttk.Frame(frame)
        logbox.pack(fill="both", expand=True, pady=(10, 0))
        self.log = tk.Text(logbox, height=10, wrap="word", state="disabled",
                           borderwidth=0, highlightthickness=0, font="TkFixedFont")
        scroll = ttk.Scrollbar(logbox, command=self.log.yview)
        self.log.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.log.pack(side="left", fill="both", expand=True)

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(14, 0))
        self.start_btn = ttk.Button(buttons, text="Start scan", command=self.start, default="active")
        self.stop_btn = ttk.Button(buttons, text="Stop", command=self.stop)
        self.report_btn = ttk.Button(buttons, text="Open report", command=self.open_report)
        self.start_btn.pack(side="right")

        root.protocol("WM_DELETE_WINDOW", self.quit)
        root.after(50, self.poll)

    def run(self) -> None:
        self.root.mainloop()

    # ---- running the scan
    def start(self) -> None:
        self.start_btn.pack_forget()
        self.report_btn.pack_forget()
        self.stop_btn.configure(text="Stop")
        self.stop_btn.pack(side="right")
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.bar.configure(value=0)
        self.detail.configure(text="")
        self.context, self.report, self.stopping, self.needs_fda = [], None, False, False
        self.set_status("Starting…")
        env = {**os.environ, "VIDEO_CLEANUP_GUI": "1", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8"}
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
                    else:
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

    def handle_message(self, msg: dict) -> None:
        kind = msg.get("kind")
        if kind == "progress":
            n, i = max(int(msg.get("n", 1)), 1), int(msg.get("i", 0))
            self.bar.configure(maximum=n, value=i)
            self.detail.configure(text=f"{msg.get('label', '')}: {i:,} of {n:,}")
        elif kind == "ask":
            answer = self.ask(msg.get("question", ""), msg.get("buttons", ["OK"]),
                              msg.get("default"), self.context)
            self.context = []
            if self.proc and self.proc.poll() is None:
                try:
                    self.proc.stdin.write(answer + "\n")
                    self.proc.stdin.flush()
                except OSError:
                    pass
        elif kind == "choose":
            answer = self.choose(msg.get("question", ""), msg.get("items", []), int(msg.get("total", 0)))
            self.context = []
            if answer == "cancel":
                self.stopping = True
            if self.proc and self.proc.poll() is None:
                try:
                    self.proc.stdin.write(answer + "\n")
                    self.proc.stdin.flush()
                except OSError:
                    pass
        elif kind == "full_disk_access":
            self.needs_fda = True
        elif kind == "automation":
            self.ask_for_automation()

    def finished(self, code: int) -> None:
        self.proc = None
        self.stop_btn.pack_forget()
        self.start_btn.configure(text="Scan again")
        self.start_btn.pack(side="right")
        if self.report:
            self.report_btn.pack(side="right", padx=(0, 8))
            self.bar.configure(value=self.bar["maximum"])
            self.set_status("Done. The report has opened in your browser. Nothing was deleted.")
        elif self.needs_fda:
            self.set_status("Video Cleanup needs Full Disk Access to read your Photos library.")
            self.ask_for_fda()
        elif self.stopping:
            self.set_status("Stopped. Nothing was deleted.")
        else:
            self.set_status(f"Something went wrong (code {code}). The details are in the log below.")

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
            if self.ask("A scan is still running. Stop it and quit?", ["Keep scanning", "Quit"],
                        "Keep scanning") != "Quit":
                return
            self.proc.kill()
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
            webbrowser.open(Path(self.report).as_uri())

    def ask(self, question: str, buttons: list[str], default: str | None,
            context: list[str] | None = None) -> str:
        """A dialog with the recent log lines, a question and a row of buttons.
        The default button sits on the right, as on other Mac dialogs."""
        tk, ttk = self.tk, self.ttk
        default = default if default in buttons else buttons[-1]
        answer = [default]
        self.asking = True
        win = tk.Toplevel(self.root)
        win.title(APP_NAME)
        win.transient(self.root)
        win.resizable(False, False)
        body = ttk.Frame(win, padding=20)
        body.pack(fill="both", expand=True)
        if context:
            ttk.Label(body, text="\n".join(context), wraplength=480,
                      justify="left").pack(anchor="w", pady=(0, 12))
        ttk.Label(body, text=question, wraplength=480, justify="left", font=self.bold).pack(anchor="w")
        row = ttk.Frame(body)
        row.pack(fill="x", pady=(18, 0))

        def choose(b: str) -> None:
            answer[0] = b
            win.destroy()

        for b in [default] + [b for b in reversed(buttons) if b != default]:
            ttk.Button(row, text=b, command=lambda b=b: choose(b),
                       default="active" if b == default else "normal").pack(side="right", padx=(8, 0))
        win.bind("<Return>", lambda e: choose(default))
        win.bind("<Escape>", lambda e: choose(default))
        win.protocol("WM_DELETE_WINDOW", lambda: choose(default))
        self.show_modal(win)
        return answer[0]

    def choose(self, question: str, items: list[dict], total: int) -> str:
        """Pick everything, or tick folders and albums. Returns "all", "cancel",
        or a JSON list of the ticked items' ids."""
        tk, ttk = self.tk, self.ttk
        answer = ["cancel"]
        self.asking = True
        win = tk.Toplevel(self.root)
        win.title(APP_NAME)
        win.transient(self.root)
        win.geometry("520x480")
        win.minsize(420, 320)
        body = ttk.Frame(win, padding=20)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text=question, font=self.bold).pack(anchor="w")
        mode = tk.StringVar(value="all")
        ttk.Radiobutton(body, text=f"Everything in my library ({total:,} videos)", variable=mode,
                        value="all").pack(anchor="w", pady=(10, 2))
        ttk.Radiobutton(body, text="Only the folders and albums I tick:", variable=mode,
                        value="some").pack(anchor="w")

        # a scrollable list of tick boxes, indented to show what's inside each folder
        box = ttk.Frame(body)
        box.pack(fill="both", expand=True, pady=(6, 0))
        canvas = tk.Canvas(box, highlightthickness=0, borderwidth=0)
        scroll = ttk.Scrollbar(box, command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        inner = ttk.Frame(canvas)
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        win.bind("<MouseWheel>", lambda e: canvas.yview_scroll(-e.delta if abs(e.delta) < 20
                                                               else -e.delta // 120, "units"))

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
            text = f"{item.get('label', '')}  ({count:,} video{'' if count == 1 else 's'})"
            row = ttk.Frame(inner)
            row.pack(anchor="w", padx=(20 * int(item.get("depth", 0)), 0), pady=1)
            ttk.Checkbutton(row, variable=ticks[k], command=lambda k=k: toggled(k)).pack(side="left")
            ttk.Label(row, text=text, font=self.bold if item.get("folder") else None).pack(side="left")

        note = ttk.Label(body, text="")
        note.pack(anchor="w", pady=(6, 0))

        def scan() -> None:
            if mode.get() == "all":
                answer[0] = "all"
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
            "macOS isn't letting Video Cleanup control Photos, so it can't make albums, "
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
            "To read your Photos library, Video Cleanup needs Full Disk Access. You only do this once.",
            "",
            "1. Click Open Settings.",
            "2. Turn on Video Cleanup in the list. If it isn't there, click +, "
            "choose Video Cleanup from Applications and turn it on.",
            "3. Quit Video Cleanup and open it again.",
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
