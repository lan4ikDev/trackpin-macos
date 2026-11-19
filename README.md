# TrackPin

<img src="Assets/TrackPin.png" alt="TrackPin icon" width="112">

A native macOS desktop widget for the Spotify desktop app. The widget lives on the desktop
like any other WidgetKit widget (macOS 14 Sonoma or later): you drag it around, resize it from
the widget gallery and edit it with a right click. It shows the album cover, the track and its
progress, and has playback buttons that work right on the desktop.

## What is inside

- **Spotify widget** in three sizes. Small: cover, track, progress and three buttons. Medium:
  cover, track, progress and up to five buttons. Large: a big cover with everything below it.
- **Cover widget** (small and large): the album cover edge to edge with a play/pause button.
- **Interactive buttons** built with App Intents: previous, play/pause, next, and rewind / fast
  forward by 5, 10, 15 or 30 seconds. The same actions are available in the Shortcuts app.
- **Settings window** with a live preview:
  - 9 themes: colors sampled from the current cover, blurred cover, system light/dark,
    graphite, plum, forest, ocean, sunset and paper;
  - cover shape (rounded, square, record), header, artist, progress bar and time on or off;
  - button set and seek step;
  - per widget overrides of the theme and buttons (right click on the widget → Edit Widget);
  - open at login, menu bar icon, what a click on the widget opens, whether play starts Spotify,
    how often Spotify is polled;
  - Spotify and widget status, Automation permission shortcut, help for adding the widget.
- **Mini player**: a click on the widget opens a vertical card that grows out of the click
  point. Most of it is the album cover, below it the track, a seek bar, playback buttons,
  shuffle, repeat and volume. Space, arrows and Esc work while it is open. Size, background
  (blurred cover, widget theme or glass), cover shape, placement and the opening animation
  are configurable. ⌃⌥P toggles it from anywhere; the menu bar icon opens it with a left click.
- **Global shortcuts**: ⌃⌥Space play/pause, ⌃⌥→ next, ⌃⌥← previous (can be turned off).
- **Sleep timer**: pause after 15–90 minutes (the volume fades out first) or at the end of the
  track, from the mini player's moon button or the menu bar menu.
- **Track change notification** with the cover, off in the settings if you don't want it.
- **Menu bar**: optional track title next to the icon, right click for the menu.

## How it works

WidgetKit extensions are sandboxed and cannot send Apple Events, and widgets are not redrawn
in real time. So the TrackPin app does the work and the widget only displays it:

1. The app reads Spotify through in-process AppleScript (`NSAppleScript`, compiled once). It
   reads right away when Spotify posts `PlaybackStateChanged` (play, pause, next track) and
   polls only while a TrackPin window is visible (every 1, 2 or 5 seconds) or, in the
   background, every 30 s or 2 min while a track plays (configurable, can be off). Nothing is
   polled while Spotify is paused or closed. It downloads the cover, samples its colors and
   asks WidgetKit to reload the widgets when something visible changes.
2. The widget asks the app for the current snapshot over a loopback TCP connection guarded by
   a per checkout token (`scripts/configure.sh`). No App Group is needed, so the app also works
   with an ad hoc signature.
3. A widget button runs an App Intent inside the extension. The intent forwards the command to
   the app, the app runs it in Spotify and answers with the new state, and WidgetKit redraws.
4. Between reloads the progress bar and the elapsed time advance on their own.

The app must keep running in the background for the widget to stay current. Turn on
"Open at login" in the settings.

## Build

Requires macOS 14 or later, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
./bootstrap.sh            # generates TrackPin.xcodeproj
open TrackPin.xcodeproj   # choose your team in Signing & Capabilities, then Run
```

Or from the command line:

```bash
TRACKPIN_TEAM=ABCDE12345 ./build.sh
mv build/TrackPin.app /Applications/ && open /Applications/TrackPin.app
```

Any Apple ID works as a team (Xcode → Settings → Accounts). With an ad hoc signature the app
runs, but macOS may not list the widget in the gallery. After the first launch, right click the
desktop, choose Edit Widgets and find TrackPin. If the widget does not appear, quit TrackPin,
run `killall chronod NotificationCenter` and open the app again.

TrackPin is an independent project and is not affiliated with Spotify.
