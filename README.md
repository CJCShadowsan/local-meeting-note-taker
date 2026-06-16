# Local Meeting Note Taker

A local-first macOS meeting note taker packaged as a native desktop app around an embedded web UI.

It records disclosed meetings from a selected macOS audio input, transcribes locally with Whisper, summarizes locally with Ollama, and saves Markdown/JSON notes on disk.

## Features

- Native macOS app launcher with embedded WebKit window
- Cassette-style macOS app icon for Finder, Installer, and Dock
- Drag-to-Applications app bundle with bundled local app resources
- Installer-time setup for required local dependencies
- Local Whisper transcription
- Local Ollama meeting summaries
- Native macOS audio recording via `ffmpeg`/AVFoundation
- Upload existing audio/video recordings
- Participant-disclosure gate before capture
- Source-audio deletion enabled by default
- History view for downloading Markdown notes and deleting saved conversations
- Redistributable installer package and zip packaging scripts

## Quick Start

From the GitHub release page, download **`LocalMeetingNoteTaker-installer.pkg`** for the easiest install. Double-click the package and follow macOS Installer; it installs **Local Meeting Note Taker.app** into `/Applications`, prepares all required local runtime components inside the installed app resource directory, sets app/helper script executable permissions, and removes quarantine from the installed app path.

The release also includes **`LocalMeetingNoteTaker-redistributable.zip`** for manual installs. A zip cannot auto-install when double-clicked on macOS; Archive Utility only extracts it. If using the zip, unzip it, then drag:

```text
Local Meeting Note Taker.app
```

into `/Applications` and double-click it. The app bundle contains the local webapp resources under `Contents/Resources/local-meeting-note-taker`, so it does not need to stay beside the extracted release folder.

During package installation, setup can take several minutes on a fresh Mac because it prepares:

- Homebrew, if missing
- `ffmpeg`
- Ollama
- Python 3.10+ when needed
- the app's local Python environment
- an Ollama summary model
- the default Whisper speech model

Installer setup details are written to `Contents/Resources/local-meeting-note-taker/data/logs/pkg-install.log` inside the installed app. After installation, the app opens its own **Local Meeting Note Taker** window and identifies itself that way in the macOS app menu. The app requests macOS microphone permission at startup, then uses the native recording bridge instead of WebKit browser microphone capture. It should not require Safari, Chrome, Terminal, or another browser.

## Manual Install

```bash
cd local-meeting-note-taker
./install_requirements.sh
./run.sh
```

## Recording Teams, Meet, Zoom, Or System Audio

For live meeting audio, route the meeting output into a macOS input device using BlackHole, Loopback, Audio Hijack, or an Aggregate Device.

The app's **Mac input device** field defaults to `:0`, meaning ffmpeg's first AVFoundation audio input. To list audio devices:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Then set **Mac input device** to the desired audio index, such as `:1` or `:2`.

## Privacy And Disclosure

The app requires confirmation that participants have been informed before recording or uploading. It also includes a copyable disclosure message:

```text
I’m recording/transcribing this meeting locally on my Mac to generate notes. The audio is processed locally, and the raw source audio will be deleted after processing unless retention is explicitly changed. Please say if you do not consent.
```

Raw source audio is deleted after processing by default.

## Build Redistributable Artifacts

From the repo root:

```bash
./package_redistributable.sh
./package_installer.sh
```

The generated zip contains a single self-contained `Local Meeting Note Taker.app`. The generated pkg installs that app into `/Applications`, makes `Contents/Resources/local-meeting-note-taker` writable for the logged-in user, runs dependency/model setup during installation, and removes quarantine from the installed app. Both artifacts exclude local `.venv`, logs, notes, uploads, recordings, and machine-specific PID/port files.

## Release Automation

GitHub Actions builds the redistributable pkg and zip only when a GitHub Release is published. Normal pushes and pull requests do not build artifacts.

To publish a release:

```bash
git tag v0.1.10
git push origin v0.1.10
gh release create v0.1.10 --title "Local Meeting Note Taker v0.1.10" --notes "Release notes"
```

The release workflow builds `LocalMeetingNoteTaker-installer.pkg` and `LocalMeetingNoteTaker-redistributable.zip`, then attaches both to that release.

## Project Layout

```text
.
├── Local Meeting Note Taker.app
├── INSTALL - Local Meeting Note Taker.command
├── OPEN ME - Local Meeting Note Taker.command
├── macos/
│   ├── LocalMeetingNoteTaker.icns
│   ├── LocalMeetingNoteTakerIcon.svg
│   ├── LocalMeetingNoteTakerBootstrap.swift
│   └── pkg-scripts/
├── local-meeting-note-taker/
│   ├── app.py
│   ├── launcher.py
│   ├── install_requirements.sh
│   ├── launch_app.sh
│   ├── static/
│   ├── templates/
│   └── requirements.txt
├── package_installer.sh
└── package_redistributable.sh
```

## Notes

This app is not currently Apple-signed or notarized. The installer package removes quarantine from the installed app, but the package itself may still require right-click **Open** on stricter macOS Gatekeeper setups until the project is signed and notarized with an Apple Developer ID.

If the app window still says **Recent notes** instead of **History**, it is showing an older local server process. Current releases verify the running server belongs to the same app bundle before reusing it; older releases may need to be quit or replaced.
