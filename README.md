# Video Cleanup

Finds duplicate, trimmed and space-wasting videos, or duplicate and similar photos, in
your Apple Photos library and makes a report you can open in your browser. It never
deletes anything: it can put its suggestions into albums in Photos, so you can check
them and delete them yourself on your Mac or iPhone.

When it starts, it asks:

1. **Videos or photos?**
2. **Which folders and albums?** Your whole library, just the ones you tick, or (for
   videos) just your largest videos, as many as you choose.
3. **How strict?**
   - **Strict:** only copies.
   - **Balanced:** copies plus very similar shots, such as bursts and retakes within
     10 minutes.
   - **Loose:** copies plus look-alikes taken within an hour.

A photo is only marked **Delete** when it's clearly a copy: the identical file, or the
same picture taken at the same moment. Similar shots are only ever marked **Review**.

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

To skip the questions, give the answers, for example:

```bash
uv run video_cleanup.py --media photos --album "Holidays" --album "Kids" --strictness balanced
```

Use `--largest 50` to scan just your 50 biggest videos.

Smaller copies of videos are made in `~/Movies/Video Cleanup/Compressed`. Once Photos has
imported one into its library, the copy and the original next to it are deleted, because Photos
keeps its own copy. Copies Photos didn't import are kept. Add `--keep-copies` to keep them all.

Your Terminal app needs Full Disk Access too.

## Testing changes

To try a change without building or downloading the app, run it straight from the code:

```bash
git fetch && git checkout BRANCH-NAME && git pull
uv run app.py
```

This opens the same window as the app. It runs as your Terminal app, so it uses
Terminal's Full Disk Access and Photos permissions. Go back to the main version with
`git checkout main && git pull`.

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
