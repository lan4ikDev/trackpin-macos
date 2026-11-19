# TrackPin

<img src="Assets/TrackPin.png" alt="TrackPin icon" width="112">

A native macOS desktop widget for Spotify, Apple Music and Yandex Music. The widget lives on the desktop
like any other WidgetKit widget (macOS 14 Sonoma or later): you drag it around, resize it from
the widget gallery and edit it with a right click. It shows the album cover, the track and its
progress, and has playback buttons that work right on the desktop.

## What is inside

- **Player widget** in three sizes. Small: cover, track, progress and three buttons. Medium:
  cover, track, progress and up to five buttons. Large: a big cover with everything below it.
- **Cover widget** (small and large): the album cover edge to edge with a play/pause button.
- **Interactive buttons** built with App Intents: previous, play/pause, next, and rewind / fast
  forward by 5, 10, 15 or 30 seconds. The same actions are available in the Shortcuts app.
- **Settings window** with a live preview:
  - 10 themes: colors sampled from the current cover, blurred cover, system light/dark,
    graphite, plum, forest, ocean, sunset, paper and a custom one;
  - theme editor for the custom theme (two background colors and an accent, or the colors
    of the current cover), export to and import from a JSON file:
    `{"format": "trackpin-theme", "version": 1, "name": "Ночь", "top": "#1E2A38", "bottom": "#0B1220", "accent": "#8CE6FF"}`;
  - cover shape (rounded, square, record), header, artist, progress bar and time on or off;
  - button set and seek step;
  - per widget overrides of the theme and buttons (right click on the widget → Edit Widget);
  - open at login, menu bar icon, what a click on the widget opens, whether play starts Spotify,
    how often Spotify is polled;
  - the music source (automatic or a fixed player);
  - player and widget status, permission shortcuts, help for adding the widget.
- **Mini player**: a click on the widget opens a vertical card that grows out of the click
  point. Most of it is the album cover, below it the track, a seek bar, playback buttons,
  shuffle, repeat and volume. Space, arrows and Esc work while it is open. Size, background
  (blurred cover, widget theme or glass), cover shape, placement and the opening animation
  are configurable. With the record cover the disc spins while a track plays, and an
  equalizer (next to the title or under the cover) moves with the music. Both animate only
  while the mini player is open, on screen and playing. ⌃⌥P toggles it from anywhere; the menu bar icon opens it with a left click.
- **Global shortcuts**: ⌃⌥Space play/pause, ⌃⌥→ next, ⌃⌥← previous (can be turned off).
- **Sleep timer**: pause after 15–90 minutes (the volume fades out first) or at the end of the
  track, from the mini player's moon button or the menu bar menu.
- **Track change notification** with the cover, off in the settings if you don't want it.
- **Lyrics** in the mini player: synced lyrics from [LRCLIB](https://lrclib.net) (free, no
  account) scroll along with the track, the current line is highlighted and a click on a line
  seeks to it. Falls back to plain text when there are no timestamps. Lyrics are cached in
  `~/Library/Caches`; the quote button in the mini player or the settings turn them off.
- **Play history**: the clock button in the mini player (or H) lists the tracks TrackPin saw
  playing, newest first, with covers. A click plays a track again (no Premium needed), the
  context menu copies its link or removes it. The last 100 tracks are kept in
  `~/Library/Application Support/TrackPin/history.json`; recording can be turned off and the
  list cleared in the settings.
- **Menu bar**: optional track title next to the icon, right click for the menu.

## Players

| Player | How TrackPin reads it | Permission |
| --- | --- | --- |
| Spotify | AppleScript, `com.spotify.client.PlaybackStateChanged` | Automation → Spotify |
| Apple Music | AppleScript, `com.apple.Music.playerInfo`; the cover is read as data once per track | Automation → Music |
| Yandex Music app | Accessibility API: the player bar's buttons, links, timecodes and sliders | Accessibility |
| Yandex Music in a browser | AppleScript `execute javascript` in the music.yandex.ru tab (`externalAPI`, then Media Session and `<audio>`) | Automation → the browser, plus "Allow JavaScript from Apple Events" |

Since macOS 15.4 the system Now Playing information (MediaRemote) is closed to other apps, and
Yandex Music has no AppleScript support, hence the two routes above. Both depend on how the
Yandex player bar is built and may need an update after a Yandex redesign. Supported browsers:
Safari, Chrome, Yandex Browser, Arc, Edge, Brave, Vivaldi and Chromium.

In automatic mode TrackPin follows whichever player is playing: Spotify and Music announce it
themselves; the Yandex app (and browser tabs, if that option is on) is checked at most every
5 seconds while nothing else plays.

## How it works

WidgetKit extensions are sandboxed and cannot send Apple Events, and widgets are not redrawn
in real time. So the TrackPin app does the work and the widget only displays it:

1. The app reads the player through in-process AppleScript (`NSAppleScript`, compiled once) or
   the Accessibility API. It reads right away when the player posts a notification (play, pause, next track) and
   polls only while a TrackPin window is visible (every 1, 2 or 5 seconds) or, in the
   background, every 30 s or 2 min while a track plays (configurable, can be off). Nothing is
   polled while the player is paused or closed (Yandex Music, which posts nothing, is the
   exception), and the app reads once more right when a track should end. It downloads the cover, samples its colors and
   asks WidgetKit to reload the widgets when something visible changes.
2. The widget asks the app for the current snapshot over a loopback TCP connection guarded by
   a per checkout token (`scripts/configure.sh`). No App Group is needed, so the app also works
   with an ad hoc signature.
3. A widget button runs an App Intent inside the extension. The intent forwards the command to
   the app, the app runs it in the player and answers with the new state, and WidgetKit redraws.
4. Between reloads the progress bar and the elapsed time advance on their own.

The app must keep running in the background for the widget to stay current. Turn on
"Open at login" in the settings.

## Build

Requires macOS 14 or later and Xcode 16 or later. XcodeGen is downloaded on first use if it
is not installed.

```bash
./build.sh --install        # builds, replaces /Applications/TrackPin.app and restarts it
./scripts/make-dmg.sh       # builds build/TrackPin-<version>.dmg
```

`build.sh` signs with the first Apple Development certificate in the keychain (any Apple ID
works as a team: Xcode → Settings → Accounts), or with `TRACKPIN_TEAM=ABCDE12345`. With an ad
hoc signature the app runs, but macOS may not list the widget in the gallery. After the first
launch, right click the desktop, choose Edit Widgets and find TrackPin.

The interface is in Russian and English (Settings → General → Language). Strings live in
`Shared/Localizable.xcstrings`; the widget follows the system language.

TrackPin is an independent project and is not affiliated with Spotify, Apple or Yandex.
