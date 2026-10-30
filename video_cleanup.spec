# PyInstaller recipe for "Video Cleanup.app". Build it with ./build_app.sh
from PyInstaller.utils.hooks import collect_all

datas, binaries, hiddenimports = [], [], ["video_cleanup"]
# osxphotos and photoscript load parts of themselves (and their AppleScript
# files) at run time; imageio_ffmpeg carries the ffmpeg program as a data file
for pkg in ("osxphotos", "photoscript", "imageio_ffmpeg"):
    d, b, h = collect_all(pkg)
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
