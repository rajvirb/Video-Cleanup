# Sift for Mac (native app)

The native version of Sift, written in Swift with SwiftUI, for the Mac App Store. It uses
Apple's Photos framework (PhotoKit), so it asks for access to your photos the normal way.
It doesn't need Full Disk Access, AppleScript or Terminal.

The sidebar on the left lists where your photos are, and what Sift can do with each:

- **Apple Photos:** your Photos library, all of it or just the albums and folders you tick.
- **Folders on this Mac:** any folders you add, such as an external drive, a Google Takeout
  export, or a synced Google Drive or Dropbox folder. Anything deleted goes to the Bin.
- **Google Photos:** sign in with Google, pick photos in Google's window, and Sift finds the
  duplicates among them. Google doesn't let apps delete from Google Photos, so Sift copies a
  list of the ones you marked and opens Google Photos for you to delete them there.
  (Photos only, up to 2,000 per pick. See [Google Photos](#google-photos) to turn it on.)
- **Support Sift**, at the bottom: a way to give, if Sift has helped.

The tools:

- **Find Duplicate Photos:** copies and similar shots, to review, compare side by side in full
  quality, and delete.
- **Find Duplicate Videos:** identical copies, re-saved versions and trimmed clips of the same
  video (and, unless you choose Strict, videos that look alike), to review, play side by side,
  and delete.
- **Make Videos Smaller:** finds videos stored in older, bulkier formats and makes smaller
  HEVC copies of the ones you choose, sorted however you like. Each copy is named after its
  original, like `IMG_1234 - sift compression.MOV`, and keeps its date, place, camera and lens.
  Copies can go into Photos (with the original's favourite status and albums), and/or into a
  folder you choose, each next to a copy of its original, for comparing in the Finder.

**Saving to an album:** in the results, mark items and click **Save…** (or **Save Set…**, or
right-click a photo) to add them to an album in Photos, made for you if it doesn't exist,
optionally inside a Photos folder, and/or copy the originals to a folder on your Mac. Items
from folders or Google Photos are imported into Photos.

**Nothing is ever deleted without asking you twice.** First Sift shows its own summary of
exactly what will be deleted: how many, how much space, favourites, edited photos, Live Photos,
and sets where nothing would be kept. Then macOS itself asks you to confirm. Deleted items stay
in Photos' **Recently Deleted** album for 30 days.

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

## Google Photos

Google Photos needs a free **OAuth client ID** from Google, made once:

1. Go to [console.cloud.google.com](https://console.cloud.google.com), sign in, and create a
   project called **Sift**.
2. In **APIs & Services › Library**, search for **Google Photos Picker API** and click **Enable**.
3. In **APIs & Services › OAuth consent screen** (or **Google Auth Platform**), choose
   **External**, give the app the name **Sift** and your email, and save. Under **Audience**
   (or **Test users**), add your own Google account, and anyone else who'll try Sift.
   Under **Data access** (or **Scopes**), add
   `https://www.googleapis.com/auth/photospicker.mediaitems.readonly`.
4. In **APIs & Services › Credentials**, click **Create credentials › OAuth client ID**, choose
   **iOS** as the application type (it's the type for Mac apps too), and enter the bundle ID
   `com.rajvirb.siftapp`. Click **Create** and copy the **Client ID** (it ends in
   `.apps.googleusercontent.com`).
5. Open `mac/Local.xcconfig` (made by `./mac/open.sh`) in any text editor and put the ID after
   `GOOGLE_CLIENT_ID =`. Run `./mac/open.sh` again, then **⌘R**.

While the consent screen is in **Testing**, only the test users can sign in. Before releasing
Sift to everyone, publish the consent screen; Google will ask for a short review of how Sift
uses the photos scope.

## Support Sift and the donate link

The **Support Sift** page reads its title, message, button and link from
[`support/sift.json`](../support/sift.json) on the `main` branch each time Sift opens (and
remembers the last one when offline). To change the link, edit that file on GitHub; everyone's
copy picks it up without updating the app. Until `url` is filled in, the button is hidden.

The **App Store** version (the **AppStore** build configuration, used when archiving) never
shows that link, because Apple requires tips there to go through in-app purchase. It shows a
tip jar instead: three tips, `com.rajvirb.siftapp.tip.small`, `.medium` and `.large`, which you
create as **Consumable** in-app purchases in App Store Connect. To try the tip jar before then,
run from Xcode: it uses `mac/Sift.storekit`, so nothing is charged.

## How it's put together

- `SiftCore/` is a Swift package with Sift's logic: fingerprints, the matching rules (copies
  vs bursts and retakes), strictness, choosing the copy to keep, and the reasons shown for
  each photo. It's the same logic as `sift.py`, with unit tests. Run them with
  `swift test --package-path mac/SiftCore`.
- `Sift/MediaProvider.swift` is what every source provides (thumbnails, full images, video,
  deleting); `FolderLibrary.swift` and `GoogleLibrary.swift` are the folder and Google Photos
  sources, `SaveSheet.swift` saves to albums, and `Support.swift` is the support page.
- `Sift/PhotoLibrary.swift` talks to Photos: permission, photo details, albums and folders,
  thumbnails, full-quality images (downloading from iCloud when needed), and deleting.
- `Sift/AppModel.swift` holds the app's state and runs the scan.
- `Sift/VideoCompressor.swift` makes the smaller video copies with AVFoundation (the Mac's
  hardware HEVC encoder) and saves them to Photos.
- `Sift/*View.swift` are the screens: what to do, progress, the results, the compare view, the
  videos to shrink, and the summary before deleting.
- `project.yml` describes the Xcode project. `Sift.xcodeproj` is made from it and isn't kept in git.

GitHub builds the app and runs the tests on every push (the **Native app** job under
**Actions**).

## The road to the App Store

1. **Photos** (done): duplicates and similar shots, review, compare, delete.
2. **Making videos smaller** (done): hardware HEVC copies saved back to Photos with each video's
   date, place, camera and lens.
3. **Duplicate videos** (done): copies and trimmed clips, using AVFoundation to read frames.
4. **App Store preparation**, which needs the **Apple Developer Program** ($99 a year):
   - your team in `project.yml`, and an App Store Connect record for Sift;
   - a privacy manifest (Sift collects no data) and the App Privacy answers;
   - screenshots, a description, keywords and a support page;
   - a TestFlight build to try on your Mac, then submission for review.

Already done for the App Store: the app runs in the **App Sandbox**, with only the Photos
entitlement, access to folders you choose yourself and outgoing network connections (for
Google Photos and the support page), and bundles no GPL code. One thing to settle before submitting: photo file sizes
come from an undocumented PhotoKit property (`fileSize`). Many App Store apps use it, but if
App Review objects, sizes can be estimated another way.
