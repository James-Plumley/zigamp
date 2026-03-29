# AGENTS.md

## Project

`ZigAmp` is a Windows-first audio player written in Zig. It uses a raw Win32 window plus OpenGL 1.1 for the UI, Windows MCI for playback, Zig-side metadata parsing for common audio formats, playlist sorting, and XSPF import/export.

This is intentionally an audio-only VLC-style scaffold, not a full media framework.

## Build And Run

- Preferred command: `zig build`
- Run command: `zig build run`
- Target: Windows desktop
- Current build setup links `user32`, `gdi32`, `opengl32`, `comdlg32`, `shell32`, and `winmm`

If `zig` is not on `PATH`, use the local toolchain under the ignored `zig-x86_64-windows-*` folder rather than changing tracked files.

## File Map

- `build.zig`: executable definition, system library links, install step, run step, Windows GUI subsystem
- `src/main.zig`: Win32 window creation, OpenGL render loop, input handling, file dialogs, drag-and-drop, playback notifications
- `src/app.zig`: app state, playlist management, sorting, playback coordination, import/export orchestration
- `src/playback.zig`: thin Windows MCI wrapper used for open/play/pause/stop/probe operations
- `src/metadata.zig`: metadata readers for `mp3`, `flac`, `ogg`, `opus`, and `wav`, plus duration probing fallback
- `src/xspf.zig`: XSPF parsing and writing
- `src/platform.zig`: Win32 imports and UTF/XML/URI helper functions
- `README.md`: user-facing project overview and controls

## Behavior Notes

- The executable should be built as a Windows GUI app, not a console app.
- UI coordinates are rendered in top-left origin screen space; if click targets drift from visuals, inspect client-size refresh and Win32 message handling in `src/main.zig`.
- Playback support depends on codecs exposed through Windows MCI. Metadata import is broader than guaranteed playback support.
- Display text rendering is currently ASCII-oriented even though metadata is stored as UTF-8.

## Commit And Push Instructions

- Do not commit build outputs, caches, the local Zig toolchain folder, or local scratch notes.
- Before committing, run `zig build` and fix build failures instead of committing broken source.
- Keep commits small and use short imperative messages such as `Add XSPF export support`.
- Do not amend commits, rewrite history, or force-push unless the user explicitly asks.
- Prefer pushing the current branch with upstream tracking: `git push -u origin main`
- If push or auth fails, stop and report the exact command failure rather than guessing.
- Never revert unrelated user changes in this workspace.
