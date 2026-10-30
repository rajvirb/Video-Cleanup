# Video Cleanup

Finds duplicate, trimmed and space-wasting videos in your Apple Photos library and
makes a report you can open in your browser. It never deletes anything: it can put
its suggestions into albums in Photos, so you can check them and delete them yourself
on your Mac or iPhone.

## Using the app

1. Download **Video Cleanup.zip** from the latest release, double-click it, and drag
   **Video Cleanup** into your **Applications** folder.
2. Open it. The first time, macOS says it can't check the app for malicious software.
   Click **Done**, then go to **System Settings › Privacy & Security**, scroll down and
   click **Open Anyway** next to Video Cleanup.
3. Click **Start scan**. The first time, the app asks for **Full Disk Access** so it can
   read your Photos library. Click **Open Settings**, turn on Video Cleanup (or click **+**
   and add it from Applications), then quit Video Cleanup and open it again.
4. When it asks to control Photos (for making albums), click **Allow**.

After installing a new version, you may need to turn Full Disk Access off and on
again for it.

The app is built for Apple Silicon Macs (M1 and later).

## Running it from Terminal

```bash
uv run video_cleanup.py
```

Your Terminal app needs Full Disk Access too.

## Building the app

On a Mac with [uv](https://docs.astral.sh/uv/) installed:

```bash
./build_app.sh
```

This makes `dist/Video Cleanup.app`, checks that it works, and zips it up as
`dist/Video Cleanup.zip`. GitHub also builds it on every push: open the run under
**Actions** and download it from **Artifacts**. To publish a release, push a tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```
