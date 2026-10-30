# PyInstaller recipe for "Video Cleanup.app". Build it with ./build_app.sh
from importlib.metadata import PackageNotFoundError, distribution, packages_distributions

from packaging.requirements import Requirement
from PyInstaller.utils.hooks import collect_all


def with_dependencies(*names: str) -> set[str]:
    """These distributions and everything they depend on, by name."""
    seen: set[str] = set()
    todo = list(names)
    while todo:
        name = todo.pop().lower().replace("_", "-")
        if name in seen:
            continue
        try:
            dist = distribution(name)
        except PackageNotFoundError:
            continue
        seen.add(name)
        for spec in dist.requires or []:
            req = Requirement(spec)
            if req.marker is None or req.marker.evaluate({"extra": ""}):
                todo.append(req.name)
    return seen


# osxphotos and many of the packages it uses load parts of themselves (and data
# files) at run time, out of sight of PyInstaller, so include them all in full.
# imageio_ffmpeg carries the ffmpeg program as a data file.
wanted = with_dependencies("osxphotos", "imageio-ffmpeg")
modules = sorted({mod for mod, dists in packages_distributions().items()
                  if any(d.lower().replace("_", "-") in wanted for d in dists)
                  and mod.isidentifier()})

datas, binaries, hiddenimports = [], [], ["video_cleanup"]
for mod in modules:
    d, b, h = collect_all(mod)
    datas += d
    binaries += b
    hiddenimports += h

a = Analysis(["app.py"], datas=datas, binaries=binaries, hiddenimports=hiddenimports)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="Video Cleanup", console=False)
coll = COLLECT(exe, a.binaries, a.datas, name="Video Cleanup")
app = BUNDLE(
    coll,
    name="Video Cleanup.app",
    bundle_identifier="com.rajvirb.videocleanup",
    info_plist={
        "CFBundleShortVersionString": "1.0.0",
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
        # shown when macOS asks to let the app control Photos
        "NSAppleEventsUsageDescription": "Video Cleanup uses Photos to make review albums, "
                                         "download videos stored in iCloud and import smaller copies.",
    },
)
