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
Video Cleanup — find duplicate and space-wasting videos in your Photos library.

It only READS your library. It never deletes anything. It writes an HTML report
and, if you agree, adds suggested videos to review albums in Photos so you can
check them and delete them yourself (on your Mac or iPhone).

What it finds
  * Identical copies          same file size and length
  * Same video, different file re-encoded / compressed / re-saved copies
  * Trimmed copies            a shorter clip whose frames all appear in a longer one
  * Look-alikes               videos that look very similar (needs your judgement)
  * Biggest videos, very short (accidental) clips, screen recordings
  * Videos that could be made smaller by re-saving them as HEVC, and optionally
    makes the smaller copies and imports them into Photos with the same date,
    place, favourite status and albums (your originals are never changed)

Usage
  uv run video_cleanup.py                 # scan your Photos library
  uv run video_cleanup.py --folder DIR    # scan a folder of video files instead
  options: --download-missing / --no-download, --make-albums / --no-albums,
           --out DIR, --library PATH
"""
from __future__ import annotations

try:
    import numpy, PIL, imageio_ffmpeg  # noqa: F401
except ImportError:
    import os, shutil, sys
    uv = shutil.which("uv") or os.path.expanduser("~/.local/bin/uv")
    if os.environ.get("VIDEO_CLEANUP_VIA_UV") or not os.path.exists(uv):
        sys.exit("Missing packages. Install uv (https://docs.astral.sh/uv/) "
                 "and run:  uv run video_cleanup.py")
    os.environ["VIDEO_CLEANUP_VIA_UV"] = "1"
    os.execv(uv, [uv, "run", "--script", os.path.abspath(__file__), *sys.argv[1:]])

import argparse
import concurrent.futures as cf
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import webbrowser
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------- settings
DENSE_RATE = 4.0         # frames hashed per second of video…
DENSE_MAX = 160          # …up to this many per video
MAX_FRAMES = 24          # frames of each video looked up in the others
FRAME_MATCH_BITS = 8     # two frames "match" if their 64-bit hashes differ by <= this
COVER_THRESHOLD = 0.8    # share of a video's frames that must appear in the other
MIN_INFORMATIVE = 3      # need this many non-blank frames to compare by content
POSTER_MATCH_BITS = 6    # poster-frame match for videos we can't open (iCloud-only)
SHORT_CLIP_SECS = 3.0
BIGGEST_COUNT = 40
ALBUM_DELETE = "Video Cleanup – Suggested to delete"
ALBUM_REVIEW = "Video Cleanup – Look-alikes to review"
ALBUM_BIG = "Video Cleanup – Biggest videos"
ALBUM_COMPARE = "Video Cleanup – Originals and smaller copies"
ALBUM_ORIGINALS = "Video Cleanup – Originals that now have a smaller copy"
ALBUM_DUPES = "Video Cleanup - Reviewable Photos"
COMPRESS_DIR = Path.home() / "Movies" / "Video Cleanup" / "Compressed"
VIDEO_EXTS = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".3gp", ".mts", ".webm"}
CACHE_FILE = Path.home() / ".cache" / "video-cleanup" / "hashes.json"
# Set by the Mac app (app.py): questions and progress are sent to the app's window
# as "@@{json}" lines on stdout, and the answers come back on stdin.
GUI = os.environ.get("VIDEO_CLEANUP_GUI") == "1"


# ---------------------------------------------------------------- model
@dataclass
class Video:
    id: str
    filename: str
    date: dt.datetime | None
    size: int
    duration: float
    width: int = 0
    height: int = 0
    path: str | None = None          # local original, None if only in iCloud
    thumb_src: str | None = None     # a preview JPEG Photos already has
    favorite: bool = False
    screen_recording: bool = False
    slow_mo: bool = False
    time_lapse: bool = False
    hidden: bool = False
    frames: list[int] = field(default_factory=list)   # content hashes
    poster: int | None = None
    codec: str = ""                  # h264 / hevc / prores / …
    fps: float = 0.0
    edited: bool = False
    spatial: bool = False
    meta: dict = field(default_factory=dict)          # albums, title, location… for re-import

    @property
    def cloud_only(self) -> bool:
        return not self.path

    @property
    def pixels(self) -> int:
        return (self.width or 0) * (self.height or 0)


# ---------------------------------------------------------------- helpers
def human_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1000
    return f"{n:.1f} TB"


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def human_dur(s: float) -> str:
    s = int(round(s or 0))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def gui_send(kind: str, **data) -> None:
    print("@@" + json.dumps({"kind": kind, **data}), flush=True)


def progress(label: str, i: int, n: int) -> None:
    if GUI:
        gui_send("progress", label=label, i=i, n=n)
        return
    if not sys.stdout.isatty():
        if i == n:
            print(f"  {label}: {n}/{n}")
        return
    width = 28
    done = int(width * i / max(n, 1))
    sys.stdout.write(f"\r  {label}: [{'#' * done}{'.' * (width - done)}] {i}/{n}")
    if i >= n:
        sys.stdout.write("\n")
    sys.stdout.flush()


def ffmpeg_exe() -> str:
    found = shutil.which("ffmpeg")
    # apps opened from Finder don't have Homebrew's folders on their PATH
    for p in (found, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if p and os.path.exists(p):
            return p
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def popcount64(x: np.ndarray) -> np.ndarray:
    if hasattr(np, "bitwise_count"):
        return np.bitwise_count(x)
    b = x.view(np.uint8).reshape(*x.shape, 8)
    table = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)
    return table[b].sum(axis=-1)


def dhash_from_gray(px: np.ndarray) -> int | None:
    """px: 8 rows x 9 cols greyscale. Returns 64-bit difference hash, or None
    if the frame is too dark or flat to say anything useful."""
    px = px.astype(np.int16)
    if px.std() < 3 or px.mean() < 12:
        return None
    bits = (px[:, 1:] > px[:, :-1]).flatten()
    return int(np.packbits(bits).view(">u8")[0])


# ---------------------------------------------------------------- frame hashing
def probe_duration(ff: str, path: str) -> float:
    r = subprocess.run([ff, "-nostdin", "-i", path], capture_output=True, text=True)
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", r.stderr)
    if not m:
        return 0.0
    h, mi, s = m.groups()
    return int(h) * 3600 + int(mi) * 60 + float(s)


def hash_video_frames(ff: str, path: str, duration: float) -> list[int]:
    """Hash frames sampled densely through the video (up to DENSE_RATE per second,
    at most DENSE_MAX in total). Dense sampling means a trimmed or re-encoded copy
    always has frames close in time to ours, whatever its keyframes or start point."""
    rate = min(DENSE_RATE, DENSE_MAX / max(duration or 1, 1))
    vf = f"fps={rate:.5f},scale=9:8:flags=area,format=gray"
    base = [ff, "-nostdin", "-v", "error"]
    attempts = []
    if sys.platform == "darwin":
        attempts.append(base + ["-hwaccel", "videotoolbox"])   # Apple's hardware decoder
    attempts.append(base)
    raw = b""
    for pre in attempts:
        cmd = pre + ["-i", path, "-an", "-sn", "-dn", "-vf", vf,
                     "-frames:v", str(DENSE_MAX + 4), "-f", "rawvideo", "-"]
        try:
            raw = subprocess.run(cmd, capture_output=True, timeout=900).stdout
        except subprocess.TimeoutExpired:
            raw = b""
        if len(raw) >= 72:
            break
    hashes = []
    for i in range(0, len(raw) - 71, 72):
        h = dhash_from_gray(np.frombuffer(raw[i:i + 72], np.uint8).reshape(8, 9))
        if h is not None:
            hashes.append(h)
    return hashes[:DENSE_MAX]


def query_frames(frames: list[int]) -> list[int]:
    """An evenly spread subset of a video's frames, used to look it up in others."""
    if len(frames) <= MAX_FRAMES:
        return frames
    idx = np.linspace(0, len(frames) - 1, MAX_FRAMES).round().astype(int)
    return [frames[i] for i in idx]


def poster_from_image(img_path: str) -> int | None:
    from PIL import Image
    try:
        with Image.open(img_path) as im:
            g = im.convert("L").resize((9, 8), Image.BOX)
            return dhash_from_gray(np.asarray(g))
    except Exception:
        return None


def poster_from_video(ff: str, path: str) -> int | None:
    cmd = [ff, "-nostdin", "-v", "error", "-i", path, "-an", "-frames:v", "1",
           "-vf", "scale=9:8:flags=area,format=gray", "-f", "rawvideo", "-"]
    try:
        raw = subprocess.run(cmd, capture_output=True, timeout=60).stdout
    except subprocess.TimeoutExpired:
        return None
    if len(raw) < 72:
        return None
    return dhash_from_gray(np.frombuffer(raw[:72], np.uint8).reshape(8, 9))


# ---------------------------------------------------------------- cache
def load_cache() -> dict:
    try:
        return json.loads(CACHE_FILE.read_text())
    except Exception:
        return {}


def save_cache(cache: dict) -> None:
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(cache))
    except Exception:
        pass


def cache_key(v: Video) -> str:
    return f"{v.id}|{v.size}"


# ---------------------------------------------------------------- loading
def load_from_photos(library: str | None) -> list[Video]:
    import osxphotos
    print("Reading your Photos library (read-only)…")
    db = osxphotos.PhotosDB(dbfile=library) if library else osxphotos.PhotosDB()
    videos = []
    for p in db.photos(images=False, movies=True):
        # Shared-album and "Shared with You" items don't use your iCloud storage.
        if getattr(p, "shared", False):
            continue
        if getattr(p, "syndicated", False) and not getattr(p, "saved_to_library", True):
            continue
        # Skip files whose name contains "(", ")" or "smaller".
        name = (p.original_filename or p.filename or "").lower()
        if "smaller" in name:
            continue
        exif = getattr(p, "exif_info", None)
        duration = float(getattr(exif, "duration", None) or 0)
        path = p.path if (p.path and os.path.exists(p.path)) else None
        thumbs = [t for t in (getattr(p, "path_derivatives", None) or [])
                  if t.lower().endswith((".jpg", ".jpeg")) and os.path.exists(t)]
        videos.append(Video(
            id=p.uuid,
            filename=p.original_filename or p.filename or p.uuid,
            date=p.date,
            size=int(getattr(p, "original_filesize", 0) or (os.path.getsize(path) if path else 0)),
            duration=duration,
            width=int(p.width or 0),
            height=int(p.height or 0),
            path=path,
            thumb_src=thumbs[0] if thumbs else None,
            favorite=bool(p.favorite),
            screen_recording=bool(getattr(p, "screen_recording", False)),
            slow_mo=bool(getattr(p, "slow_mo", False)),
            time_lapse=bool(getattr(p, "time_lapse", False)),
            hidden=bool(getattr(p, "hidden", False)),
            codec=norm_codec(getattr(exif, "codec", None)),
            fps=float(getattr(exif, "fps", None) or 0),
            edited=bool(getattr(p, "hasadjustments", False)),
            spatial=bool(getattr(p, "spatial", False)),
            meta={
                "albums": list(getattr(p, "albums", None) or []),
                "title": getattr(p, "title", None) or "",
                "description": getattr(p, "description", None) or "",
                "keywords": list(getattr(p, "keywords", None) or []),
                "location": tuple(getattr(p, "location", None) or (None, None)),
            },
        ))
    return videos


def norm_codec(c: str | None) -> str:
    c = (c or "").lower()
    if any(k in c for k in ("hvc", "hev", "h265", "x265")):
        return "hevc"
    if any(k in c for k in ("avc", "h264", "x264")):
        return "h264"
    if any(k in c for k in ("apc", "ap4", "prores")):
        return "prores"
    if any(k in c for k in ("mp4v", "mpeg4", "xvid", "divx")):
        return "mpeg4"
    if "jpeg" in c or "mjp" in c:
        return "mjpeg"
    return c


def probe_stream(ff: str, path: str) -> dict:
    """Codec, size, frame rate, bit depth and duration of a local video file."""
    r = subprocess.run([ff, "-nostdin", "-hide_banner", "-i", path], capture_output=True, text=True)
    out = {"duration": 0.0, "codec": "", "width": 0, "height": 0, "fps": 0.0, "ten_bit": False}
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", r.stderr)
    if m:
        h, mi, sec = m.groups()
        out["duration"] = int(h) * 3600 + int(mi) * 60 + float(sec)
    m = re.search(r"Stream #\S+.*?: Video: (\w+)(.*)", r.stderr)
    if m:
        out["codec"] = norm_codec(m.group(1))
        rest = m.group(2)
        d = re.search(r"\b(\d{2,5})x(\d{2,5})\b", rest)
        if d:
            out["width"], out["height"] = int(d.group(1)), int(d.group(2))
        f = re.search(r"([\d.]+) fps", rest)
        if f:
            out["fps"] = float(f.group(1))
        out["ten_bit"] = bool(re.search(r"p10|p12|10le|12le", rest))
    if re.search(r"rotation of -?90", r.stderr):
        out["width"], out["height"] = out["height"], out["width"]
    return out


def load_from_folder(folder: str, ff: str) -> list[Video]:
    print(f"Reading videos in {folder}…")
    files = sorted(f for f in Path(folder).rglob("*")
                   if f.is_file() and f.suffix.lower() in VIDEO_EXTS)
    videos = []
    for i, f in enumerate(files, 1):
        st = f.stat()
        info = probe_stream(ff, str(f))
        videos.append(Video(
            id=hashlib.sha1(str(f.resolve()).encode()).hexdigest()[:16],
            filename=f.name,
            date=dt.datetime.fromtimestamp(st.st_mtime),
            size=st.st_size,
            duration=info["duration"],
            width=info["width"],
            height=info["height"],
            path=str(f),
            codec=info["codec"],
            fps=info["fps"],
        ))
        progress("Reading", i, len(files))
    return videos


def download_original(v: Video, tmpdir: str) -> str | None:
    """Ask Photos to export (and so download from iCloud) one original."""
    import photoscript
    try:
        out = photoscript.Photo(v.id).export(tmpdir, original=True, overwrite=True, timeout=600)
        out = [o for o in out if Path(o).suffix.lower() in VIDEO_EXTS] or out
        return out[0] if out else None
    except Exception:
        return None


def fingerprint_all(videos: list[Video], ff: str, download_missing: bool) -> None:
    cache = load_cache()
    todo = []
    for v in videos:
        c = cache.get(cache_key(v))
        if c and (c.get("frames") or not v.path and not download_missing):
            v.frames, v.poster = c.get("frames", []), c.get("poster")
            if not v.duration:
                v.duration = c.get("duration", 0)
            continue
        todo.append(v)

    # poster hashes from Photos' own previews (works for iCloud-only videos too)
    for v in todo:
        if v.thumb_src:
            v.poster = poster_from_image(v.thumb_src)

    local = [v for v in todo if v.path]
    remote = [v for v in todo if not v.path] if download_missing else []
    if len(videos) - len(todo):
        print(f"  {len(videos) - len(todo)} videos already checked on a previous run")

    def work(v: Video) -> Video:
        if not v.duration:
            v.duration = probe_duration(ff, v.path)
        v.frames = hash_video_frames(ff, v.path, v.duration)
        if v.poster is None:
            v.poster = poster_from_video(ff, v.path)
        return v

    if local:
        print(f"Comparing the content of {len(local)} videos stored on this Mac…")
        with cf.ThreadPoolExecutor(max_workers=max(2, (os.cpu_count() or 4) // 2)) as ex:
            for i, _ in enumerate(ex.map(work, local), 1):
                progress("Analysing", i, len(local))
                if i % 50 == 0:
                    _store(cache, local[:i])

    if remote:
        print(f"Downloading {len(remote)} iCloud-only videos one at a time to check them…")
        print(f"  (each is deleted again straight after; press {'Stop' if GUI else 'Ctrl-C'} to stop and use what's done)")
        try:
            for i, v in enumerate(remote, 1):
                with tempfile.TemporaryDirectory() as td:
                    p = download_original(v, td)
                    if p:
                        if not v.duration:
                            v.duration = probe_duration(ff, p)
                        v.frames = hash_video_frames(ff, p, v.duration)
                        if v.poster is None:
                            v.poster = poster_from_video(ff, p)
                progress("Downloading", i, len(remote))
                if i % 10 == 0:
                    _store(cache, remote[:i])
        except KeyboardInterrupt:
            print("\n  Stopped — continuing with what's been checked.")

    _store(cache, videos)


def _store(cache: dict, vids: list[Video]) -> None:
    for v in vids:
        if v.frames or v.poster is not None:
            cache[cache_key(v)] = {"frames": v.frames, "poster": v.poster, "duration": v.duration}
    save_cache(cache)


# ---------------------------------------------------------------- matching
def close_durations(a: float, b: float, tol: float = 0.1) -> bool:
    if not a or not b:
        return False
    return abs(a - b) <= max(1.5, tol * max(a, b))


def find_matches(videos: list[Video]) -> dict[tuple[int, int], str]:
    """Return {(i, j): kind} with i < j. kind in identical/same/trimmed/similar."""
    edges: dict[tuple[int, int], str] = {}
    rank = {"similar": 0, "trimmed": 1, "same": 2, "identical": 3}

    def add(i, j, kind):
        k = (min(i, j), max(i, j))
        if k not in edges or rank[kind] > rank[edges[k]]:
            edges[k] = kind

    # 1. identical: same byte size and length
    by_sig: dict[tuple, list[int]] = {}
    for i, v in enumerate(videos):
        if v.size:
            by_sig.setdefault((v.size, round(v.duration or 0, 1)), []).append(i)
    for idx in by_sig.values():
        for a in idx[1:]:
            add(idx[0], a, "identical")

    # 2. same poster frame and near-identical length (catches re-saved copies,
    #    including videos whose originals are only in iCloud)
    pidx = [i for i, v in enumerate(videos) if v.poster is not None and v.duration]
    if len(pidx) > 1:
        P = np.array([videos[i].poster for i in pidx], dtype=np.uint64)
        D = np.array([videos[i].duration for i in pidx])
        for r in range(len(pidx)):
            d = popcount64(P[r + 1:] ^ P[r])
            tol = np.maximum(1.0, 0.03 * np.maximum(D[r + 1:], D[r]))
            hit = np.nonzero((d <= POSTER_MATCH_BITS) & (np.abs(D[r + 1:] - D[r]) <= tol))[0]
            for h in hit:
                add(pidx[r], pidx[r + 1 + h], "same")

    # 3. content: share of one video's frames that appear in the other
    fidx = [i for i, v in enumerate(videos) if len(v.frames) >= MIN_INFORMATIVE]
    if len(fidx) > 1:
        lens = [len(videos[i].frames) for i in fidx]
        A = np.array([h for i in fidx for h in videos[i].frames], dtype=np.uint64)
        starts = np.concatenate([[0], np.cumsum(lens)[:-1]])
        cover: dict[tuple[int, int], float] = {}
        for a, i in enumerate(fidx):
            H = np.array(query_frames(videos[i].frames), dtype=np.uint64)
            m = popcount64(H[:, None] ^ A[None, :]) <= FRAME_MATCH_BITS
            per_video = np.logical_or.reduceat(m, starts, axis=1)   # (k, n)
            counts = per_video.sum(axis=0)
            frac = counts / len(H)
            frac[a] = 0
            for b in np.nonzero((frac >= COVER_THRESHOLD) & (counts >= MIN_INFORMATIVE))[0]:
                cover[(i, fidx[b])] = float(frac[b])
            progress("Comparing", a + 1, len(fidx))
        for (i, j), f in cover.items():
            vi, vj = videos[i], videos[j]
            back = cover.get((j, i), 0.0)
            if back >= COVER_THRESHOLD and close_durations(vi.duration, vj.duration):
                add(i, j, "same")
            elif vi.duration and vj.duration and vi.duration < 0.9 * vj.duration:
                add(i, j, "trimmed")      # i is a shorter piece of j
            else:
                add(i, j, "similar")
    return edges


@dataclass
class Group:
    members: list[int]
    keeper: int
    action: dict[int, tuple[str, str]]     # idx -> ("delete"|"review", reason)

    def saving(self, videos):
        return sum(videos[i].size for i, (a, _) in self.action.items() if a == "delete")


REASONS = {
    "identical": "Identical copy of the one marked Keep",
    "same": "Same video as the one marked Keep, saved as a separate file",
    "trimmed": "Shorter clip — everything in it is also in the one marked Keep",
    "similar": "Looks very similar to another video here — check before deleting",
}


def build_groups(videos: list[Video], edges) -> list[Group]:
    parent = list(range(len(videos)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i, j in edges:
        parent[find(i)] = find(j)
    clusters: dict[int, list[int]] = {}
    for i, j in edges:
        for x in (i, j):
            clusters.setdefault(find(x), [])
            if x not in clusters[find(x)]:
                clusters[find(x)].append(x)

    groups = []
    for members in clusters.values():
        # keep the most complete, best quality copy; favourites win ties
        keeper = max(members, key=lambda k: (
            round(videos[k].duration or 0), videos[k].pixels, videos[k].favorite,
            not videos[k].cloud_only, videos[k].size))
        action = {}
        for m in members:
            if m == keeper:
                continue
            kind = edges.get((min(m, keeper), max(m, keeper)))
            if kind == "trimmed" and videos[m].duration > videos[keeper].duration:
                kind = "similar"
            if kind in ("identical", "same", "trimmed") and not videos[m].favorite:
                action[m] = ("delete", REASONS[kind])
            elif kind in ("identical", "same", "trimmed"):
                action[m] = ("review", REASONS[kind] + " (but it's a favourite)")
            else:
                action[m] = ("review", REASONS["similar"])
        groups.append(Group(members, keeper, action))
    groups.sort(key=lambda g: (-g.saving(videos), -len(g.members)))
    return groups


# ---------------------------------------------------------------- report
def make_thumb(v: Video, ff: str, out_dir: Path) -> str | None:
    from PIL import Image
    dest = out_dir / "thumbs" / f"{v.id}.jpg"
    if dest.exists():
        return f"thumbs/{dest.name}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        if v.thumb_src:
            with Image.open(v.thumb_src) as im:
                im = im.convert("RGB")
                im.thumbnail((360, 360))
                im.save(dest, quality=80)
            return f"thumbs/{dest.name}"
        if v.path:
            t = min(1.0, (v.duration or 0) / 2)
            subprocess.run([ff, "-nostdin", "-v", "error", "-ss", f"{t:.2f}", "-i", v.path,
                            "-frames:v", "1", "-vf", "scale=360:-2", "-y", str(dest)],
                           capture_output=True, timeout=60)
            if dest.exists():
                return f"thumbs/{dest.name}"
    except Exception:
        pass
    return None


def card(v: Video, thumb: str | None, badge: str = "", note: str = "") -> str:
    e = html.escape
    img = (f'<img src="{e(thumb)}" alt="" loading="lazy">' if thumb
           else '<div class="noimg">No preview</div>')
    tags = []
    if v.favorite:
        tags.append('<span class="tag fav">★ Favourite</span>')
    if v.cloud_only:
        tags.append('<span class="tag">iCloud only</span>')
    if v.screen_recording:
        tags.append('<span class="tag">Screen recording</span>')
    if v.slow_mo:
        tags.append('<span class="tag">Slo-mo</span>')
    if v.time_lapse:
        tags.append('<span class="tag">Time-lapse</span>')
    if v.hidden:
        tags.append('<span class="tag">Hidden</span>')
    when = v.date.strftime("%-d %b %Y, %H:%M") if v.date else "Unknown date"
    res = f"{min(v.width, v.height)}p" if v.width and v.height else ""
    badge_html = f'<span class="badge {badge.lower()}">{e(badge)}</span>' if badge else ""
    return f"""<div class="card {badge.lower()}">
  <div class="thumb">{img}{badge_html}<span class="dur">{human_dur(v.duration)}</span></div>
  <div class="meta">
    <div class="size">{human_size(v.size)}</div>
    <div class="when">{e(when)}</div>
    <div class="fn">{e(v.filename)}{' · ' + res if res else ''}</div>
    {'<div class="tags">' + ''.join(tags) + '</div>' if tags else ''}
    {f'<div class="note">{e(note)}</div>' if note else ''}
  </div>
</div>"""


def write_report(videos: list[Video], groups: list[Group], ff: str, out_dir: Path,
                 source_label: str, albums_made: bool, from_photos: bool = True,
                 cands: list | None = None, comp_result: dict | None = None) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    needed = set()
    for g in groups:
        needed.update(g.members)
    biggest = sorted(range(len(videos)), key=lambda i: -videos[i].size)[:BIGGEST_COUNT]
    short = sorted([i for i, v in enumerate(videos)
                    if v.duration and v.duration < SHORT_CLIP_SECS and not v.favorite],
                   key=lambda i: -videos[i].size)
    screen = sorted([i for i, v in enumerate(videos) if v.screen_recording],
                    key=lambda i: -videos[i].size)
    cands = cands or []
    cands = sorted(cands, key=lambda c: -max((c[1] or c[2]).saving(videos[c[0]]),
                                              (c[2] or c[1]).saving(videos[c[0]])))
    needed.update(biggest, short, screen, (c[0] for c in cands))
    thumbs = {}
    needed = sorted(needed)
    for n, i in enumerate(needed, 1):
        thumbs[i] = make_thumb(videos[i], ff, out_dir)
        progress("Previews", n, len(needed))

    total = sum(v.size for v in videos)
    saving = sum(g.saving(videos) for g in groups)
    n_delete = sum(1 for g in groups for a, _ in g.action.values() if a == "delete")
    n_review = sum(1 for g in groups for a, _ in g.action.values() if a == "review")
    checked = sum(1 for v in videos if len(v.frames) >= MIN_INFORMATIVE)
    cloud_unchecked = sum(1 for v in videos if v.cloud_only and len(v.frames) < MIN_INFORMATIVE)
    short_size = sum(videos[i].size for i in short)
    screen_size = sum(videos[i].size for i in screen)

    comp_same = sum(p.saving(videos[i]) for i, p, _ in cands if p)
    comp_hd = sum(p.saving(videos[i]) for i, _, p in cands if p)
    comp_cards = []
    for i, ps, ph in cands:
        v = videos[i]
        lines = []
        if ps:
            lines.append(f"Same resolution ({ps.label}): about {human_size(ps.est_size)}, saves {human_size(ps.saving(v))}")
        if ph and (not ps or ph.short_side != ps.short_side):
            lines.append(f"At 1080p ({ph.label}): about {human_size(ph.est_size)}, saves {human_size(ph.saving(v))}")
        comp_cards.append(card(v, thumbs.get(i), "", " · ".join(lines)))
    if comp_result:
        cr = comp_result
        comp_status = (f"""<div class="callout"><b>{cr['done']} smaller copies made</b>, saving
          {human_size(cr['saved'])}. Each one is next to a copy of its original in
          <i>{html.escape(cr['dir'])}</i>, named “… - smaller” and “… - original”, so you can compare them.""" +
          (f""" {cr['imported']} were imported into Photos with their dates, places, favourites and albums.
          The album <i>{html.escape(ALBUM_COMPARE)}</i> has each original right next to its smaller copy,
          so you can compare them. When you're happy, open <i>{html.escape(ALBUM_ORIGINALS)}</i>,
          select all and delete the originals, then empty Recently Deleted. Photos may list each pair
          under Duplicates. Don't press Merge there, because it keeps the larger original.""" if cr['imported'] else
           " Drag them into Photos if you want them in your library.") + "</div>")
    else:
        comp_status = ""

    group_html = []
    for n, g in enumerate(groups, 1):
        order = [g.keeper] + sorted((m for m in g.members if m != g.keeper),
                                    key=lambda m: (g.action[m][0] != "delete", -videos[m].size))
        cards = []
        for m in order:
            if m == g.keeper:
                cards.append(card(videos[m], thumbs.get(m), "Keep", "Best copy: longest and highest quality"))
            else:
                act, why = g.action[m]
                cards.append(card(videos[m], thumbs.get(m), "Delete" if act == "delete" else "Review", why))
        sv = g.saving(videos)
        head = f"Frees {human_size(sv)}" if sv else "Check these"
        group_html.append(f'<section class="group"><h3><span>Set {n}</span> · {len(g.members)} videos · <b>{head}</b></h3>'
                          f'<div class="row">{"".join(cards)}</div></section>')

    def grid(idx, note_fn=None):
        if not idx:
            return '<p class="empty">Nothing here.</p>'
        return '<div class="grid">' + "".join(
            card(videos[i], thumbs.get(i), "", note_fn(videos[i]) if note_fn else "") for i in idx) + "</div>"

    def per_min(v: Video) -> str:
        if not v.duration:
            return ""
        return f"{human_size(v.size / (v.duration / 60))} per minute"

    albums_note = (f"""<div class="callout"><b>Albums added in Photos.</b> Look for
      <i>{html.escape(ALBUM_DELETE)}</i>, <i>{html.escape(ALBUM_REVIEW)}</i> and
      <i>{html.escape(ALBUM_BIG)}</i> under Albums on your Mac or iPhone. Open one, check the
      videos, then select them and choose <b>Delete</b> (not “Remove from Album”).
      Then empty <b>Recently Deleted</b> to free the iCloud space.</div>""" if albums_made else
                   """<div class="callout">Tip: run the tool again and answer <b>yes</b> to
      “create review albums” to get these videos collected in albums you can open on your iPhone.</div>""" if from_photos else "")

    now = dt.datetime.now().strftime("%-d %b %Y, %H:%M")
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Video Cleanup</title>
<style>
:root {{ --bg:#f6f5f2; --panel:#fff; --ink:#1d1d1f; --mute:#6e6e73; --line:#e3e1dc;
  --keep:#1f7a4d; --del:#c2410c; --rev:#a16207; --accent:#2f5bea; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#141416; --panel:#1f1f22; --ink:#f2f2f4;
  --mute:#a1a1a8; --line:#33333a; --keep:#4ade80; --del:#fb923c; --rev:#facc15; --accent:#7c9cff; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink);
  font:15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }}
main {{ max-width:1180px; margin:0 auto; padding:32px 20px 80px; }}
h1 {{ font-size:30px; letter-spacing:-.02em; margin:0 0 4px; }}
.sub {{ color:var(--mute); margin:0 0 24px; }}
.stats {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:12px; margin-bottom:20px; }}
.stat {{ background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:14px 16px; }}
.stat .n {{ font-size:26px; font-weight:650; letter-spacing:-.02em; }}
.stat .l {{ color:var(--mute); font-size:13px; }}
.stat.hi .n {{ color:var(--del); }}
.callout {{ background:var(--panel); border:1px solid var(--line); border-left:4px solid var(--accent);
  border-radius:10px; padding:12px 16px; margin:0 0 28px; }}
nav {{ display:flex; gap:8px; flex-wrap:wrap; margin-bottom:28px; position:sticky; top:0; padding:10px 0;
  background:var(--bg); z-index:2; }}
nav a {{ color:var(--ink); text-decoration:none; border:1px solid var(--line); background:var(--panel);
  padding:6px 12px; border-radius:999px; font-size:14px; }}
nav a:hover {{ border-color:var(--accent); }}
h2 {{ font-size:21px; margin:36px 0 4px; letter-spacing:-.01em; }}
.lead {{ color:var(--mute); margin:0 0 16px; max-width:760px; }}
.group {{ background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:14px; margin-bottom:14px; }}
.group h3 {{ margin:0 0 10px; font-size:14px; font-weight:500; color:var(--mute); }}
.group h3 span {{ color:var(--ink); font-weight:600; }}
.group h3 b {{ color:var(--del); }}
.row {{ display:flex; gap:12px; overflow-x:auto; padding-bottom:4px; }}
.row .card {{ flex:0 0 210px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(190px,1fr)); gap:12px; }}
.card {{ background:var(--panel); border:1px solid var(--line); border-radius:12px; overflow:hidden; }}
.card.keep {{ border-color:var(--keep); }}
.card.delete {{ border-color:var(--del); }}
.thumb {{ position:relative; aspect-ratio:4/3; background:#000; }}
.thumb img {{ width:100%; height:100%; object-fit:cover; display:block; }}
.noimg {{ color:#999; display:grid; place-items:center; height:100%; font-size:13px; }}
.dur {{ position:absolute; right:6px; bottom:6px; background:rgba(0,0,0,.65); color:#fff;
  font-size:12px; padding:1px 6px; border-radius:6px; font-variant-numeric:tabular-nums; }}
.badge {{ position:absolute; left:6px; top:6px; color:#fff; font-size:12px; font-weight:650;
  padding:2px 8px; border-radius:6px; }}
.badge.keep {{ background:#1f7a4d; }} .badge.delete {{ background:#c2410c; }} .badge.review {{ background:#a16207; }}
.meta {{ padding:8px 10px 10px; }}
.size {{ font-weight:650; font-variant-numeric:tabular-nums; }}
.when, .fn {{ color:var(--mute); font-size:12.5px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }}
.tags {{ margin-top:6px; display:flex; gap:4px; flex-wrap:wrap; }}
.tag {{ font-size:11px; border:1px solid var(--line); border-radius:999px; padding:0 7px; color:var(--mute); }}
.tag.fav {{ color:var(--rev); border-color:var(--rev); }}
.note {{ font-size:12.5px; margin-top:6px; }}
.empty {{ color:var(--mute); }}
footer {{ color:var(--mute); font-size:13px; margin-top:48px; }}
</style></head><body><main>
<h1>Video Cleanup</h1>
<p class="sub">{html.escape(source_label)} · scanned {now} · nothing has been deleted</p>
<div class="stats">
  <div class="stat"><div class="n">{len(videos)}</div><div class="l">videos · {human_size(total)}</div></div>
  <div class="stat hi"><div class="n">{human_size(saving)}</div><div class="l">could be freed by {n_delete} duplicate{'s' if n_delete != 1 else ''}</div></div>
  <div class="stat"><div class="n">{human_size(comp_same)}</div><div class="l">could be saved by compressing {plural(len([c for c in cands if c[1]]), "video")}</div></div>
  <div class="stat"><div class="n">{n_review}</div><div class="l">look-alikes to check</div></div>
  <div class="stat"><div class="n">{human_size(short_size)}</div><div class="l">in {len(short)} clip{'s' if len(short) != 1 else ''} under {SHORT_CLIP_SECS:.0f} seconds</div></div>
</div>
{albums_note}
<nav><a href="#dupes">Duplicates ({len(groups)} sets)</a><a href="#big">Biggest</a>
<a href="#smaller">Could be smaller</a><a href="#short">Very short</a><a href="#screen">Screen recordings</a><a href="#about">How this works</a></nav>

<h2 id="dupes">Duplicates and trimmed copies</h2>
<p class="lead">Each set is a group of videos with the same content. <b>Keep</b> is the most complete,
highest-quality copy. <b>Delete</b> marks copies whose content is all in the kept one. <b>Review</b>
marks videos that look alike but might be different moments, so you decide.</p>
{''.join(group_html) or '<p class="empty">No duplicates found.</p>'}

<h2 id="big">Biggest videos</h2>
<p class="lead">Your {len(biggest)} largest videos. Long or 4K clips take the most space, so
these are worth a look even if they're not duplicates.</p>
{grid(biggest, per_min)}

<h2 id="smaller">Could be made smaller</h2>
<p class="lead">Videos stored in an older, less efficient format, or at a higher bitrate than they need.
Re-saving them as HEVC (the format iPhones use now) at the same resolution would save about
<b>{human_size(comp_same)}</b> with no visible difference. Capping them at 1080p as well would save about
<b>{human_size(comp_hd)}</b>, but 4K videos would look a little less sharp on a big TV. Slo-mo, edited,
spatial and high-frame-rate videos are left out, because re-saving would lose those effects.
Run the tool again to make the smaller copies; your originals are never changed.</p>
{comp_status}
{('<div class="grid">' + ''.join(comp_cards) + '</div>') if comp_cards else '<p class="empty">Nothing here. Your videos are already efficiently stored.</p>'}

<h2 id="short">Very short clips</h2>
<p class="lead">Videos under {SHORT_CLIP_SECS:.0f} seconds are often taken by accident. Favourites are left out.
Together they use {human_size(short_size)}.</p>
{grid(short)}

<h2 id="screen">Screen recordings</h2>
<p class="lead">{len(screen)} screen recordings using {human_size(screen_size)}.</p>
{grid(screen)}

<h2 id="about">How this works</h2>
<p class="lead">The tool takes fingerprints of frames throughout each video (several per second)
and looks for them in every other video. That finds copies even when they've been compressed, re-saved or trimmed.
{checked} of {len(videos)} videos were checked this way.
{f"{cloud_unchecked} videos are stored only in iCloud, so they were compared using Photos' preview image, length and size instead, which catches exact and re-saved copies but not trimmed ones." if cloud_unchecked else ""}
Deleting a video moves it to Recently Deleted. The iCloud space is only freed once it leaves there,
either after 30 days or when you empty it.</p>
<footer>Video Cleanup only reads your library. Thumbnails are stored next to this page.</footer>
</main></body></html>"""
    out = out_dir / "index.html"
    out.write_text(page, encoding="utf-8")
    return out


# ---------------------------------------------------------------- compression
AUDIO_KBPS = 256
MIN_SAVING = 15_000_000          # don't bother for less than 15 MB


def target_kbps(short_side: int, fps: float) -> int:
    """Roughly the bitrate an iPhone uses for HEVC at this size and frame rate
    (e.g. 1080p30 ≈ 60 MB/min, 4K30 ≈ 170 MB/min, 4K60 ≈ 400 MB/min)."""
    hi = (fps or 30) > 40
    if short_side <= 540:
        return 3500 if hi else 2500
    if short_side <= 720:
        return 7000 if hi else 5000
    if short_side <= 1080:
        return 12000 if hi else 8000
    if short_side <= 1440:
        return 24000 if hi else 14000
    return 45000 if hi else 23000


@dataclass
class Plan:
    mode: str          # "same" or "1080p"
    short_side: int    # output's shorter dimension
    kbps: int
    est_size: int
    label: str

    def saving(self, v: "Video") -> int:
        return max(0, v.size - self.est_size)


def plan_compression(v: Video, mode: str) -> Plan | None:
    if not (v.duration and v.size and v.width and v.height):
        return None
    if v.slow_mo or v.edited or v.spatial or (v.fps and v.fps > 65):
        return None          # re-encoding would lose slo-mo, edits, 3D or high frame rate
    short = min(v.width, v.height)
    new_short = min(short, 1080) if mode == "1080p" else short
    kbps = target_kbps(new_short, v.fps)
    est = int((kbps + AUDIO_KBPS) * 1000 / 8 * v.duration)
    current_kbps = v.size * 8 / v.duration / 1000
    if current_kbps < 1.5 * (kbps + AUDIO_KBPS) or v.size - est < MIN_SAVING:
        return None
    parts = []
    if new_short < short:
        parts.append(f"{res_label(short)} → {res_label(new_short)}")
    codec = {"h264": "H.264", "hevc": "HEVC", "prores": "ProRes", "mpeg4": "MPEG-4",
             "mjpeg": "Motion JPEG"}.get(v.codec, v.codec.upper() or "Older format")
    if v.codec != "hevc":
        parts.append(f"{codec} → HEVC")
    elif not parts:
        parts.append("HEVC at a standard bitrate")
    return Plan(mode, new_short, kbps, est, ", ".join(parts))


def res_label(short: int) -> str:
    return "4K" if short >= 2000 else f"{short}p"


def pick_encoder(ff: str) -> str | None:
    """Prefer the Mac's hardware HEVC encoder; fall back to x265 (slower)."""
    r = subprocess.run([ff, "-hide_banner", "-encoders"], capture_output=True, text=True)
    for enc in ("hevc_videotoolbox", "libx265"):
        if enc not in r.stdout:
            continue
        test = subprocess.run([ff, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                               "testsrc2=s=320x240:d=0.5", "-c:v", enc, "-f", "null", "-"],
                              capture_output=True)
        if test.returncode == 0:
            return enc
    return None


def encode_hevc(ff: str, encoder: str, src: str, dst: str, plan: Plan) -> tuple[bool, str]:
    """Encode to a temporary name and only rename it to dst once it's complete and
    checked, so stopping part-way never leaves a half-written copy that a later
    run would take for a finished one."""
    part = dst + ".partial"
    try:
        ok, why = _encode_hevc(ff, encoder, src, part, plan)
        if ok:
            os.replace(part, dst)
        return ok, why
    finally:
        if os.path.exists(part):
            os.remove(part)


def _encode_hevc(ff: str, encoder: str, src: str, dst: str, plan: Plan) -> tuple[bool, str]:
    info = probe_stream(ff, src)
    short = min(info["width"], info["height"]) or plan.short_side
    vf = []
    if plan.short_side < short:
        s_ = plan.short_side
        vf.append(f"scale='if(gte(iw,ih),-2,{s_})':'if(gte(iw,ih),{s_},-2)'")
    if encoder == "hevc_videotoolbox":
        vcodec = ["-c:v", encoder, "-b:v", f"{plan.kbps}k", "-allow_sw", "1"]
        vcodec += (["-profile:v", "main10", "-pix_fmt", "p010le"] if info["ten_bit"]
                   else ["-profile:v", "main", "-pix_fmt", "yuv420p"])
    else:
        vcodec = ["-c:v", "libx265", "-crf", "23", "-preset", "medium",
                  "-x265-params", "log-level=error",
                  "-pix_fmt", "yuv420p10le" if info["ten_bit"] else "yuv420p"]
    pre = [ff, "-nostdin", "-v", "error", "-y"]
    if sys.platform == "darwin":
        pre += ["-hwaccel", "videotoolbox"]
    common = (["-vf", ",".join(vf)] if vf else []) + vcodec + [
        "-tag:v", "hvc1", "-map_metadata", "0",
        "-movflags", "+use_metadata_tags+faststart", "-f", "mov", dst]
    # audio: copy every track; if that fails (e.g. spatial audio), keep just the
    # main track; as a last resort re-encode it as AAC
    for audio in (["-map", "0:a?", "-c:a", "copy"],
                  ["-map", "0:a:0?", "-c:a", "copy"],
                  ["-map", "0:a:0?", "-c:a", "aac", "-b:a", "192k"]):
        cmd = pre + ["-i", src, "-map", "0:v:0"] + audio + common
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0 and os.path.exists(dst):
            break
    else:
        return False, (r.stderr.strip().splitlines() or ["encoding failed"])[-1]

    # check the result before trusting it
    out = probe_stream(ff, dst)
    if abs(out["duration"] - info["duration"]) > max(0.6, 0.01 * info["duration"]):
        os.remove(dst)
        return False, "the compressed copy came out a different length"
    if os.path.getsize(dst) > 0.85 * os.path.getsize(src):
        os.remove(dst)
        return False, "it wouldn't have got much smaller"
    try:
        st = os.stat(src)
        os.utime(dst, (st.st_atime, st.st_mtime))
    except OSError:
        pass
    return True, ""


def copy_original(src: str, dst: Path, move: bool) -> None:
    """Put the original next to its smaller copy. A file downloaded from iCloud
    just gets moved there; one already on this Mac is cloned (instant, and on
    APFS it takes no extra space until one of them changes)."""
    if dst.exists():
        return
    if move:
        shutil.move(src, dst)
        return
    if sys.platform == "darwin":
        r = subprocess.run(["cp", "-c", "-p", src, str(dst)], capture_output=True)
        if r.returncode == 0:
            return
    shutil.copy2(src, dst)


def compress_videos(videos: list[Video], items: list[tuple[int, Plan]], ff: str,
                    out_dir: Path) -> list[tuple[int, str]]:
    encoder = pick_encoder(ff)
    if not encoder:
        print("  No HEVC encoder available. Install ffmpeg with Homebrew (brew install ffmpeg) and try again.")
        return []
    print(f"  Using {'your Mac’s hardware encoder' if encoder == 'hevc_videotoolbox' else 'the x265 encoder (slower)'}.")
    out_dir.mkdir(parents=True, exist_ok=True)
    # each smaller copy sits next to a copy of its original (an APFS clone of
    # files already on this Mac, so those take almost no extra space)
    need = sum(p.est_size + (videos[i].size if videos[i].cloud_only else 0) for i, p in items)
    free = shutil.disk_usage(out_dir).free
    if free < need * 1.2 + 2e9:
        print(f"  Not enough free disk space: need about {human_size(need * 1.2 + 2e9)}, "
              f"have {human_size(free)}. Free some space or compress fewer videos.")
        return []
    done: list[tuple[int, str]] = []
    failed = 0
    t0 = time.time()
    try:
        for n, (i, plan) in enumerate(items, 1):
            v = videos[i]
            base = f"{Path(v.filename).stem} ({v.id[:6]})"
            dst = out_dir / f"{base} - smaller.mov"
            orig_name = f"{base} - original{Path(v.filename).suffix or '.mov'}"
            if dst.exists() and dst.stat().st_size > 0 and (out_dir / orig_name).exists():
                done.append((i, str(dst)))       # made on an earlier run
            else:
                with tempfile.TemporaryDirectory() as td:
                    src = v.path or download_original(v, td)
                    if not src:
                        failed += 1
                        print(f"\n  Skipped {v.filename}: couldn't download it from iCloud")
                    else:
                        if not dst.exists():
                            ok, why = encode_hevc(ff, encoder, src, str(dst), plan)
                        else:
                            ok, why = True, ""
                        if ok:
                            orig = out_dir / (Path(orig_name).stem + Path(src).suffix)
                            copy_original(src, orig, move=not v.path)
                            done.append((i, str(dst)))
                        else:
                            failed += 1
                            print(f"\n  Skipped {v.filename}: {why}")
            progress("Compressing", n, len(items))
    except KeyboardInterrupt:
        print("\n  Stopped — keeping the copies already made.")
    saved = sum(videos[i].size - os.path.getsize(d) for i, d in done)
    print(f"  Made {len(done)} smaller copies in {time.time() - t0:.0f}s, "
          f"saving {human_size(saved)}.")
    print(f"  Each one is next to its original in {out_dir}")
    if failed:
        print(f"  {failed} videos were skipped and left as they are.")
    return done


def import_copies(videos: list[Video], done: list[tuple[int, str]]) -> int:
    """Import the smaller copies into Photos and give each the original's details."""
    import photoscript
    lib = photoscript.PhotosLibrary()
    # one album with each original right next to its smaller copy, for comparing;
    # and one with just the originals, so they can be deleted with Select All
    compare_album = lib.album(ALBUM_COMPARE) or lib.create_album(ALBUM_COMPARE)
    old_album = lib.album(ALBUM_ORIGINALS) or lib.create_album(ALBUM_ORIGINALS)
    album_cache: dict[str, object] = {}
    count = 0
    for n, (i, path) in enumerate(done, 1):
        v = videos[i]
        try:
            imported = lib.import_photos([path], skip_duplicate_check=True)
            if not imported:
                continue
            new = imported[0]
            original = photoscript.Photo(v.id)
            compare_album.add([original])     # added as a pair, so they sit together
            compare_album.add([new])
            old_album.add([original])
            if v.favorite:
                new.favorite = True
            m = v.meta
            if m.get("title"):
                new.title = m["title"]
            if m.get("description"):
                new.description = m["description"]
            if m.get("keywords"):
                new.keywords = m["keywords"]
            lat, lon = (m.get("location") or (None, None))[:2]
            if lat is not None and lon is not None:
                try:
                    cur = new.location
                except Exception:
                    cur = (None, None)
                if not cur or cur[0] is None:
                    new.location = (float(lat), float(lon))
            if v.date:
                want = v.date.astimezone().replace(tzinfo=None) if v.date.tzinfo else v.date
                try:
                    if abs((new.date - want).total_seconds()) > 60:
                        new.date = want
                except Exception:
                    pass
            for name in m.get("albums", []):
                if name not in album_cache:
                    album_cache[name] = lib.album(name)
                if album_cache[name]:
                    album_cache[name].add([new])
            count += 1
        except Exception as exc:
            print(f"\n  Couldn't import {Path(path).name}: {exc}")
        progress("Importing", n, len(done))
    return count


# ---------------------------------------------------------------- albums
def make_albums(videos: list[Video], groups: list[Group]) -> bool:
    import photoscript
    delete = [videos[i].id for g in groups for i, (a, _) in g.action.items() if a == "delete"]
    review = [videos[i].id for g in groups for i, (a, _) in g.action.items() if a == "review"]
    big = [videos[i].id for i in sorted(range(len(videos)), key=lambda i: -videos[i].size)[:BIGGEST_COUNT]]
    # every video in the "Duplicates and trimmed copies" section, set by set,
    # in the same order as the report (Keep first, then Delete, then Review)
    dupes = []
    for g in groups:
        order = [g.keeper] + sorted((m for m in g.members if m != g.keeper),
                                    key=lambda m: (g.action[m][0] != "delete", -videos[m].size))
        dupes.extend(videos[m].id for m in order)
    lib = photoscript.PhotosLibrary()
    for name, ids in ((ALBUM_DUPES, dupes), (ALBUM_DELETE, delete),
                      (ALBUM_REVIEW, review), (ALBUM_BIG, big)):
        if not ids:
            continue
        album = lib.album(name) or lib.create_album(name)
        for k in range(0, len(ids), 50):
            album.add([photoscript.Photo(u) for u in ids[k:k + 50]])
        print(f"  Album “{name}”: {len(ids)} videos")
    return True

# ---------------------------------------------------------------- main
def ask_choice(question: str, options: tuple[str, ...], default: str,
               labels: tuple[str, ...] | None = None) -> str:
    """Ask for one of options. labels are the button names the Mac app shows."""
    if GUI:
        labels = labels or options
        gui_send("ask", question=question, buttons=list(labels),
                 default=labels[options.index(default)])
        ans = sys.stdin.readline().strip()
        return options[labels.index(ans)] if ans in labels else default
    if not sys.stdin.isatty():
        return default
    while True:
        try:
            ans = input(f"{question} [{default}] ").strip().lower()[:1] or default
        except EOFError:
            return default
        if ans in options:
            return ans


def ask(question: str, default: bool = False) -> bool:
    if GUI:
        gui_send("ask", question=question, buttons=["Yes", "No"], default="Yes" if default else "No")
        ans = sys.stdin.readline().strip()
        return default if not ans else ans == "Yes"
    if not sys.stdin.isatty():
        return default
    hint = "[Y/n]" if default else "[y/N]"
    try:
        ans = input(f"{question} {hint} ").strip().lower()
    except EOFError:
        return default
    return default if not ans else ans.startswith("y")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--folder", help="scan a folder of video files instead of the Photos library")
    ap.add_argument("--library", help="path to a .photoslibrary (default: your system library)")
    ap.add_argument("--out", default=str(Path.home() / "Desktop" / "Video Cleanup Report"))
    dl = ap.add_mutually_exclusive_group()
    dl.add_argument("--download-missing", action="store_true", default=None,
                    help="temporarily download iCloud-only videos for a full check")
    dl.add_argument("--no-download", dest="download_missing", action="store_false")
    al = ap.add_mutually_exclusive_group()
    al.add_argument("--make-albums", action="store_true", default=None)
    al.add_argument("--no-albums", dest="make_albums", action="store_false")
    ap.add_argument("--compress", choices=["no", "same", "1080p"],
                    help="make smaller HEVC copies: at the same resolution, or capped at 1080p")
    im = ap.add_mutually_exclusive_group()
    im.add_argument("--import", dest="do_import", action="store_true", default=None,
                    help="import the smaller copies into Photos")
    im.add_argument("--no-import", dest="do_import", action="store_false")
    ap.add_argument("--compress-dir", default=str(COMPRESS_DIR))
    ap.add_argument("--no-open", action="store_true", help="don't open the report when done")
    args = ap.parse_args()

    t0 = time.time()
    ff = ffmpeg_exe()
    use_photos = not args.folder
    if use_photos and sys.platform != "darwin":
        sys.exit("Reading the Photos library only works on a Mac. Use --folder to scan a folder.")

    if use_photos:
        try:
            videos = load_from_photos(args.library)
        except Exception as exc:
            msg = str(exc)
            print(f"\nCouldn't read the Photos library: {msg}")
            # without Full Disk Access, osxphotos usually fails copying Photos.sqlite
            if any(k in msg.lower() for k in ("permission", "operation not permitted",
                                               "authoriz", "error copying")):
                if GUI:
                    gui_send("full_disk_access")
                else:
                    print("Give Terminal 'Full Disk Access' in System Settings › Privacy & Security, "
                          "then quit and reopen Terminal and try again.")
            sys.exit(1)
        source = "Photos library"
    # else:
    #     videos = load_from_folder(args.folder, ff)
    #     source = f"Folder {args.folder}"

    if not videos:
        sys.exit("No videos found.")
    total = sum(v.size for v in videos)
    cloud = [v for v in videos if v.cloud_only]
    print(f"Found {len(videos)} videos using {human_size(total)}.")

    download = args.download_missing
    if use_photos and cloud and download is None:
        print(f"\n{len(cloud)} of them ({human_size(sum(v.size for v in cloud))}) are only in iCloud, not on this Mac.")
        print("They'll still be checked for exact and re-saved copies using their previews.")
        print("For a full check (including trimmed copies) they need downloading, which can take a long time.")
        download = ask("Download them temporarily for a full check?", False)


    fingerprint_all(videos, ff, bool(download))

    print("Looking for matches…")
    edges = find_matches(videos)
    groups = build_groups(videos, edges)
    saving = sum(g.saving(videos) for g in groups)
    n_delete = sum(1 for g in groups for a, _ in g.action.values() if a == "delete")
    print(f"\nFound {len(groups)} sets of duplicates. "
          f"Deleting {n_delete} suggested copies would free {human_size(saving)}.")

    albums_made = False
    if use_photos and groups:
        want = args.make_albums
        if want is None:
            want = ask("Create review albums in Photos so you can check and delete these on your iPhone?", True)
        if want:
            print("Adding albums in Photos (Photos will open; allow "
                  f"{'Video Cleanup' if GUI else 'Terminal'} to control it if asked)…")
            try:
                albums_made = make_albums(videos, groups)
            except Exception as exc:
                print(f"  Couldn't create albums: {exc}")


    # ---- compression

    to_delete = {i for g in groups for i, (a, _) in g.action.items() if a == "delete"}
    cands = []
    for i, v in enumerate(videos):
        if i in to_delete:
            continue          # no point shrinking a video you're about to delete
        ps, ph = plan_compression(v, "same"), plan_compression(v, "1080p")
        if ps or ph:
            cands.append((i, ps, ph))
    comp_result = None
    if cands:
        same = sorted([(i, p) for i, p, _ in cands if p], key=lambda x: -x[1].saving(videos[x[0]]))
        hd = sorted([(i, p) for i, _, p in cands if p], key=lambda x: -x[1].saving(videos[x[0]]))
        s_same = sum(p.saving(videos[i]) for i, p in same)
        s_hd = sum(p.saving(videos[i]) for i, p in hd)
        print("\nVideos that could be made smaller:")
        if same:
            print(f"  {'' if GUI else '[s] '}{plural(len(same), 'video')} re-saved in the newer HEVC format at the same resolution: "
                  f"saves about {human_size(s_same)}, with no visible difference.")
        if hd:
            print(f"  {'' if GUI else '[h] '}{plural(len(hd), 'video')} re-saved as HEVC and capped at 1080p: saves about {human_size(s_hd)}. "
                  "Fine on a phone or laptop, a little less sharp on a big 4K TV.")
        choice = args.compress
        if choice is None:
            choice = ask_choice("Make smaller copies?" if GUI else
                                "Make smaller copies? Type s, h, or n for no", ("s", "h", "n"), "n",
                                ("Same resolution", "Cap at 1080p", "No thanks"))
            choice = {"s": "same", "h": "1080p", "n": "no"}[choice]
        items = same if choice == "same" else hd if choice == "1080p" else []
        if items:
            n_cloud = sum(1 for i, _ in items if videos[i].cloud_only)
            print(f"Making {len(items)} smaller copies (the originals aren't touched)…")
            if n_cloud:
                print(f"  {n_cloud} of them are only in iCloud and will be downloaded one at a time first.")
            done = compress_videos(videos, items, ff, Path(args.compress_dir).expanduser())
            imported = 0
            if done and use_photos:
                want = args.do_import
                if want is None:
                    want = ask("Import the smaller copies into Photos, with the same dates, places, "
                               "favourites and albums?", True)
                if want:
                    try:
                        imported = import_copies(videos, done)
                    except Exception as exc:
                        print(f"  Couldn't import into Photos: {exc}")
            comp_result = {
                "mode": choice, "done": len(done), "imported": imported,
                "saved": sum(videos[i].size - os.path.getsize(d) for i, d in done),
                "dir": str(Path(args.compress_dir).expanduser()),
            }

    out = write_report(videos, groups, ff, Path(args.out).expanduser(), source, albums_made, use_photos,
                       cands, comp_result)
    print(f"\nReport: {out}")
    print(f"Done in {time.time() - t0:.0f}s. Nothing was deleted.")
    if not args.no_open:
        webbrowser.open(out.as_uri())


if __name__ == "__main__":
    main()
