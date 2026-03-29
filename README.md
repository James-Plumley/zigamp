# ZigAmp

`ZigAmp` is a a basic music player written in Zig, using OpenGL for UI. I develop on Windows, but using this application on Linux should be feasible after I make it agnostic to winmm.

- an OpenGL 1.1 playlist UI
- Zig-side metadata parsing for common audio formats
- sorting by title, artist, album, track number, duration, and path
- XSPF playlist import/export
- OS-backed playback via Windows MCI (`winmm`)

## Scope

This is a beginner's Zig and OpenGL project for the sake of learning.

- UI and application logic are written in Zig.
- Rendering is done directly with OpenGL.
- Playback is delegated to Windows multimedia APIs instead of a bundled decoder stack.
- Metadata parsing is implemented in Zig for `.mp3`, `.flac`, `.ogg`, `.opus`, and `.wav`.
- Playback support depends on codecs that Windows MCI exposes on the machine.

In practice, playback is most reliable for `mp3`, `wav`, and some `m4a/aac/wma` setups. `flac/ogg/opus` library entries and metadata import work, but playback depends on system codec support.

## Build

Install Zig on Windows and make sure `zig` is on `PATH`, then from this folder run:

```powershell
zig build run
```

## Controls

- `Import Audio`: multi-select audio files and add them to the current list
- `Open XSPF`: replace the current list with an XSPF playlist
- `Save XSPF`: export the current list to XSPF
- `Play/Pause`, `Stop`, `Prev`, `Next`: transport controls
- Click a column header to sort; click again to reverse sort direction
- Double-click a row or press `Enter` to play the selected track
- `Space`: play/pause
- `Left` / `Right`: previous / next
- `Esc`: stop
- Drag and drop files onto the window to import them

## Notes

- The OpenGL text renderer currently assumes ASCII-friendly display text. Metadata is preserved in UTF-8 internally, but non-ASCII characters may render as `?` in the UI.
- XSPF support focuses on the common fields used by desktop players: `location`, `title`, `creator`, `album`, `trackNum`, and `duration`.
- The current Windows build was verified against Zig `0.16.0-dev.3013+abd131e33`.
