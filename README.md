# Sift

Sift finds duplicate and space-wasting videos and photos in your Apple Photos library,
and helps you get rid of them.

- **Videos:** identical copies, re-saved copies, trimmed clips, your biggest videos, very
  short clips and screen recordings. It can also make smaller copies of videos stored in
  older, bulkier formats.
- **Photos:** identical copies, re-saved or resized copies, and similar shots such as
  bursts and retakes, plus your biggest photos and screenshots.

You go through what it finds on a review page in your browser, comparing copies side by
side in full quality, and choose what to delete.

**Sift never deletes anything itself.** Apple doesn't let other apps delete from your
library, so Sift puts what you choose into an album in Photos and you delete them there.
Deleted items stay in Photos' **Recently Deleted** album for 30 days, so mistakes can be
undone.

## What you need

- A Mac with Apple Silicon (M1 or later), running macOS 12 Monterey or later
- Your photos and videos in the Photos app
- About 10 minutes for the first-time setup

## Setting up Sift for the first time

### 1. Download it

1. Go to the [latest release](https://github.com/rajvirb/Video-Cleanup/releases/latest).
2. Under **Assets**, click **Sift.zip** to download it.
3. Open your **Downloads** folder and double-click **Sift.zip** to unzip it.
4. Drag **Sift** into your **Applications** folder.

### 2. Open it for the first time

Sift isn't sold through the App Store, so the first time you open it, macOS asks you to
confirm that you trust it. You only do this once for each version.

**On macOS 15 Sequoia or later:**

1. In **Applications**, double-click **Sift**. A message says *Apple could not verify
   “Sift” is free of malware*. Click **Done**. Don't click **Move to Bin**.
2. Open **System Settings** and click **Privacy & Security**.
3. Scroll down to **Security**. Next to the message about Sift, click **Open Anyway**.
   (The button only stays there for about an hour. If it's gone, double-click Sift again.)
4. Enter your Mac's password or use Touch ID.
5. Click **Open Anyway** once more. Sift opens.

**On macOS 14 Sonoma or earlier:** in **Applications**, hold **Control** and click **Sift**
(or right-click it), choose **Open**, then click **Open**.

### 3. Let Sift read your Photos library

macOS keeps your Photos library private, so Sift needs **Full Disk Access** to read it.
It only reads the library. It never changes your photos.

1. In Sift, click **Start scan** and choose **Videos** or **Photos**.
2. Sift says it needs Full Disk Access. Click **Open Settings**.
   (Or open **System Settings › Privacy & Security › Full Disk Access** yourself.)
3. If **Sift** is in the list, turn it on. If it isn't, click **+**, choose **Sift** from
   **Applications**, click **Open**, and make sure it's turned on.
4. Enter your password or use Touch ID if asked.
5. **Quit Sift** (⌘Q) and open it again. Full Disk Access only works after a restart.

### 4. Let Sift make albums in Photos

The first time Sift makes an album, macOS asks: *“Sift” wants access to control “Photos”*.
Click **OK** (or **Allow**). Sift needs this to make the albums you review, to put what you
choose to delete into the **Sift - To Delete** album, and to import smaller copies of videos.

If you clicked **Don't Allow** by mistake, see
[Sift can't make albums](#sift-cant-make-albums-or-import-videos).

That's it. Setup is done.

## Using Sift

### Scanning

Click **Start scan**. Sift asks four things:

1. **Videos or photos?**
2. **What to scan.** Your whole library, only the albums and folders you tick, or (for
   videos) only your largest videos, as many as you choose.
3. **How strict to be:**
   - **Strict:** only copies.
   - **Balanced:** copies, plus very similar videos, or similar photos taken within
     10 minutes (bursts and retakes). This is a good place to start.
   - **Loose:** copies, plus look-alikes taken within an hour. More to go through.
4. **Videos only: whether to download videos stored only in iCloud** for a full check.
   Without downloading, they're still checked for copies using their previews.

The first scan of a big library can take a while (the progress bar shows how long is
left). Later scans are much quicker, because Sift remembers what it has already checked.

### Reviewing what Sift found

When the scan finishes, the **review page** opens in your browser. Each **set** is a group
of videos or photos that look alike.

- **★ Best** is the copy Sift suggests keeping: the longest, highest-quality one.
  Favourites win ties.
- Copies Sift is sure about (identical files, and the same picture or video saved again)
  are labelled with why, such as *Identical copy of the one marked Keep*.
- **Review** marks ones that only look alike, such as burst shots or a photo saved from
  a message. Sift never selects these for you: you decide.

To choose what to delete:

- **Click** a photo or video to switch it between **KEEP** (green) and **DELETE** (red).
- **Select suggested on this page** marks every copy Sift is sure about on this page.
  **Select suggested in all sets** does it for every page (you're asked to confirm twice).
- **⤢ Expand & compare** shows a set full-screen, side by side:
  - Photos are shown in full quality. Click a photo, or use **2×** and **4×**, to zoom:
    all the photos zoom together and follow your pointer, so you can compare sharpness.
  - Videos can be played side by side. **▶ Play all** starts them together.
  - **Keep only this** marks every other copy for deletion.
  - Keyboard: **←/→** previous or next set, **1–9** keep or delete that one, **Z** zoom,
    **⌫** move the marked ones to the album, **Esc** close.
- Click **Move N to delete album** to send the ones marked DELETE to the album
  **Sift - To Delete** in Photos. They disappear from the review page.

You can come back to the review page later: in Sift, click **Review & choose**. Things
you've already sent to the album stay hidden.

### Deleting them in Photos

1. Open **Photos** and go to **Albums › Sift - To Delete**.
2. Press **⌘A** to select everything in the album.
3. Press **⌘⌫** (Command and Delete) and confirm **Delete**.
   Pressing Delete on its own only removes them from the album.
4. They move to **Recently Deleted**, where they stay for 30 days. The space is only freed
   once they leave there, so to free it straight away, open **Recently Deleted** and
   choose **Delete All**.

### The full report

Sift also saves a report you can open with **Open report**. It lists the duplicate sets,
your biggest videos or photos, very short clips, screen recordings or screenshots, and
videos that could be made smaller. Reports are saved on your Desktop, in
**Sift Report (Videos)** and **Sift Report (Photos)**.

### Making videos smaller (optional)

When scanning videos, Sift may offer to make smaller copies of videos stored in older,
bulkier formats, at the same resolution or capped at 1080p. Your originals are never
changed. If you say yes:

1. Sift makes the smaller copies, keeping each video's date, place, camera and lens.
2. It offers to import them into Photos, with the same favourites and albums.
3. In Photos, check them in **Sift - Original & Compressed Comparison**, where each original
   sits next to its smaller copy.
4. When you're happy, open **Sift - Original Videos**, select all, and press **⌘⌫** to
   delete the originals.

Photos may list each original and smaller copy under **Duplicates**. Don't press **Merge**
there: it keeps the larger original.

### Albums Sift makes

| Album | What's in it |
|---|---|
| Sift - To Delete | What you chose to delete on the review page |
| Sift - Duplicated & Trimmed Videos | Every video in a duplicate set, set by set |
| Sift - Duplicate & Similar Photos | Every photo in a duplicate or similar set, set by set |
| Sift - Original Videos | Originals that now have a smaller copy |
| Sift - Compressed Versions | The smaller copies |
| Sift - Original & Compressed Comparison | Each original next to its smaller copy |

Deleting an album never deletes what's in it.

## Updating to a new version

1. Download the new **Sift.zip** from the [latest release](https://github.com/rajvirb/Video-Cleanup/releases/latest).
2. Quit Sift, then drag the new **Sift** into **Applications** and choose **Replace**.
3. Open it as in [step 2 of the setup](#2-open-it-for-the-first-time): macOS asks again for each new version.
4. macOS treats the new version as a different app, so give it Full Disk Access again:
   in **System Settings › Privacy & Security › Full Disk Access**, select the old **Sift**,
   click **−** to remove it, then click **+** and add the new one. Quit and reopen Sift.

## Troubleshooting

### “Apple could not verify Sift is free of malware”

This is expected the first time you open each version. Follow
[step 2 of the setup](#2-open-it-for-the-first-time).

### “Sift needs Full Disk Access”, or “Couldn't read the Photos library”

Follow [step 3 of the setup](#3-let-sift-read-your-photos-library). Remember to quit and
reopen Sift afterwards. After an update, remove the old Sift from the list and add the
new one.

### Sift can't make albums or import videos

macOS isn't letting Sift control Photos. Sift shows a message with an **Open Settings** button.

1. Open **System Settings › Privacy & Security › Automation**.
2. Under **Sift**, turn on **Photos**.

If Sift isn't in the list, macOS needs to ask again. Open the **Terminal** app (in
Applications › Utilities), paste this line and press Return, then scan again and click
**OK** when asked:

```bash
tccutil reset AppleEvents com.rajvirb.sift
```

### The review page didn't open

Click **Review & choose** in Sift. The page runs on your Mac, at an address like
`http://localhost:8765`, and only while Sift is open.

### A photo says “Preview only” in the compare view

Sift couldn't get the full-quality version, usually because the photo is only in iCloud and
your Mac is offline. Don't judge sharpness from those: try again when you're online.

## Privacy

Everything happens on your Mac. Sift doesn't upload anything or connect to any service.
It reads your Photos library without changing it. The only changes it makes in Photos are
the albums you ask for and the smaller copies you choose to import.

---

## For developers

### Running it from the code

With [uv](https://docs.astral.sh/uv/) installed (`brew install uv`), from this folder:

```bash
uv run --managed-python app.py
```

This opens the same window as the app. It runs as your Terminal app, so it uses
Terminal's Full Disk Access and Photos permissions. Or, to answer the questions in Terminal:

```bash
uv run sift.py
```

To skip the questions, give the answers, for example:

```bash
uv run sift.py --media photos --album "Holidays" --album "Kids" --strictness balanced
```

Other options: `--largest 50` (only your 50 biggest videos), `--compress no|same|1080p`,
`--import` / `--no-import`, `--keep-copies` (keep smaller copies in
`~/Movies/Sift/Compressed` even once they're in Photos), and `--no-open`. To open the
review page for an earlier scan:

```bash
uv run sift.py --review "$HOME/Desktop/Sift Report (Photos)"
```

### Testing a branch

```bash
git fetch && git checkout BRANCH-NAME && git pull
```

```bash
uv run --managed-python app.py
```

### Building the app

```bash
./build_app.sh
```

This makes `dist/Sift.app`, checks that it works, and zips it as `dist/Sift.zip`. Apps you
build yourself open without the "could not verify" message. GitHub also builds the app on
every push (see the run's **Artifacts** under **Actions**). To publish a release that people
can download, push a tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

### How it's put together

- `sift.py`: the scan: reading Photos, fingerprinting, matching, reports, compressing
- `review.py`: the review page and its server
- `app.py`: the Mac app's window, which runs `sift.py` and shows its questions as dialogs
- `sift.spec`, `build_app.sh`: building `Sift.app` with PyInstaller
- `tools/make_icon.py`: draws the icon
