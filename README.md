# Denote

Denote is a small native macOS menu-bar notes app for focused working notes: summon one note window from anywhere, keep it pinned or compact while you work, capture ideas with local voice transcription, and export cleanly to Markdown or HTML.

Notes are saved in:

```text
~/Documents/Denote
```

App window state is saved in:

```text
~/Library/Application Support/Denote/state.json
```

## Features

### Work from the notch

- Denote places a compact black island at the top of every connected display.
- Hover over the central notch body to reveal a horizontally scrollable tray of recent-note cards; the side buttons remain independent.
- Click any card to open it in the note window; the tray closes automatically.
- When the current note is open, its card becomes a large minimise control that returns the window to the notch.
- Click the current-note icon on the left side of the notch to show or hide it.
- Click the new-note icon on the right side to create and open a note.
- Right-click the island for Settings, the configured shortcut, and Quit.
- Press `Option-Space` to show or hide the current note from anywhere.
- Double-click the note title in the window toolbar to rename it.
- Change the global shortcut from Denote Settings.
- Work with one note window at a time; selecting or creating a note swaps the document in that window.

### Stay visible

- Pin the note window above other windows with the always-hover toggle.
- Toggle the window between standard and small modes.
- Restore the active note and window position when Denote relaunches.
- Use the same notch interaction on notchless and external displays through a narrower synthetic top-centre island.

### Capture quickly

- Dictate notes with high-quality local voice transcription.
- Autosave every open note as you work.
- Use random readable note names and double-click the title to rename.

### Edit without fighting paste

- Rich-text editing backed by ProseMirror.
- Better paste handling than native Notes for tables, merged cells, lists, images, and browser-rendered formatting.
- Formatting shortcuts: `Cmd-B`, `Cmd-I`, `Cmd-1`, `Cmd-2`, `Cmd-3`, and `Cmd-0`.
- Backslash heading triggers: `\ `, `\\ `, and `\\\ ` for heading levels 1-3.

### Export cleanly

- Fast export to Markdown, plain text, or HTML.
- Notes are stored locally as `.note.json` files with document structure, rendered HTML, and plain text fallback.

## Requirements

- macOS 14 or later.
- Xcode command line tools with Swift.
- Node.js and npm.

Install the Xcode command line tools if needed:

```sh
xcode-select --install
```

## Install

Clone the repository, install dependencies, build the editor bundle, build the macOS app, and copy it into `/Applications` or `~/Applications`:

```sh
cd ~/Downloads
git clone https://github.com/olliepumphrey7/denote.git
cd denote
npm install
npm run build:editor
./scripts/install-app.sh
```

Open the installed app:

```sh
open -a "Denote"
```

If macOS warns that the app is from an unidentified developer, open System Settings, go to Privacy & Security, and allow the app to open. This project currently builds a local unsigned app.

## Update

Pull the latest code, rebuild, and reinstall:

```sh
cd ~/Downloads/denote
git pull
npm install
npm run build:editor
./scripts/install-app.sh
```

Quit and reopen Denote after updating.

## Development

Build and run from the repository:

```sh
npm install
npm run build:editor
swift build
swift run DenoteChecks
npm run test:editor
./scripts/build-app.sh
open "dist/Denote.app"
```

## Notes Format

Each note is stored as a `.note.json` file in `~/Documents/Denote`. The file contains the editor document model, rendered HTML, and plain text fallback. These files are local and are not synced by the app itself.
