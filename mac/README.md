# Sift for Mac (native app)

The native version of Sift, written in Swift with SwiftUI, for the Mac App Store. It uses
Apple's Photos framework (PhotoKit), so it asks for access to your photos the normal way.
It doesn't need Full Disk Access, AppleScript or Terminal, and it can delete photos directly
(macOS asks you to confirm, and they go to Recently Deleted).

This first version finds **duplicate photos and similar shots**. Videos and compression come next.

## Running it on your Mac

You need **Xcode** (free, from the Mac App Store) and **Homebrew** (from [brew.sh](https://brew.sh)).

1. Get the latest code. In Terminal:

   ```bash
   cd ~/Github/video-cleanup && git fetch && git checkout native-app && git pull
   ```

2. Make the Xcode project and open it:

   ```bash
   ./mac/open.sh
   ```

   The first time, this installs XcodeGen, the tool that makes the Xcode project from
   `mac/project.yml`. Xcode then opens with **Sift**.

3. In Xcode, check that the toolbar at the top says **Sift › My Mac**, then press **▶ Run**
   (or **⌘R**). The first build takes a minute or two.

4. Sift opens and asks to access your photos. Click **Allow Full Access**.

Each time you get new code (`git pull`), run `./mac/open.sh` again if any files were added,
then press **⌘R**.

### Using your Apple ID (optional for now)

The project starts out as **Sign to Run Locally**, which runs on your Mac with no account.
To sign with your Apple ID instead (needed later for TestFlight and the App Store):

1. In Xcode, choose **Xcode › Settings › Accounts**, click **+**, and add your Apple ID.
2. In the left sidebar, click the blue **Sift** project, select the **Sift** target, and
   open **Signing & Capabilities**.
3. Under **Team**, choose your name (Personal Team).

If you change the team, `./mac/open.sh` will reset it, because the project is remade from
`project.yml`. Once you're in the Apple Developer Program, we'll put your team's ID in
`project.yml` so it sticks.

## How it's put together

- `SiftCore/` is a Swift package with Sift's logic: fingerprints, the matching rules (copies
  vs bursts and retakes), strictness, choosing the copy to keep, and the reasons shown for
  each photo. It's the same logic as `sift.py`, with unit tests. Run them with
  `swift test --package-path mac/SiftCore`.
- `Sift/PhotoLibrary.swift` talks to Photos: permission, photo details, albums and folders,
  thumbnails, full-quality images (downloading from iCloud when needed), and deleting.
- `Sift/AppModel.swift` holds the app's state and runs the scan.
- `Sift/*View.swift` are the screens: what to scan, progress, the results, and the compare view.
- `project.yml` describes the Xcode project. `Sift.xcodeproj` is made from it and isn't kept in git.

GitHub builds the app and runs the tests on every push (the **Native app** job under
**Actions**).

## The road to the App Store

1. **Photos** (this version): duplicates and similar shots, review, compare, delete.
2. **Videos:** duplicates and trimmed copies, using AVFoundation to read frames.
3. **Making videos smaller:** AVFoundation's hardware HEVC export, saved back to Photos with
   each video's date, place, camera and lens.
4. **App Store preparation**, which needs the **Apple Developer Program** ($99 a year):
   - your team in `project.yml`, and an App Store Connect record for Sift;
   - a privacy manifest (Sift collects no data) and the App Privacy answers;
   - screenshots, a description, keywords and a support page;
   - a TestFlight build to try on your Mac, then submission for review.

Already done for the App Store: the app runs in the **App Sandbox** with only the Photos
entitlement, and bundles no GPL code. One thing to settle before submitting: photo file sizes
come from an undocumented PhotoKit property (`fileSize`). Many App Store apps use it, but if
App Review objects, sizes can be estimated another way.
