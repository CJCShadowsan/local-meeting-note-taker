# Local Meeting Note Taker

A local-first macOS meeting note taker packaged as a native desktop app around an embedded web UI.

It records disclosed meetings from a selected macOS audio input, transcribes locally with Whisper, summarizes locally with Ollama, and saves Markdown/JSON notes on disk.

## Features

- Native macOS app launcher with embedded WebKit window
- Drag-to-Applications app bundle with bundled local app resources
- First-run installer for required local dependencies
- Local Whisper transcription
- Local Ollama meeting summaries
- Native macOS audio recording via `ffmpeg`/AVFoundation
- Upload existing audio/video recordings
- Participant-disclosure gate before capture
- Source-audio deletion enabled by default
- History view for downloading Markdown notes and deleting saved conversations
- Redistributable zip packaging script

## Quick Start

Download the release zip, unzip it, then drag:

```text
Local Meeting Note Taker.app
```

into `/Applications` and double-click it. The app bundle contains the local webapp resources under `Contents/Resources/local-meeting-note-taker`, so it does not need to stay beside the extracted release folder.

On first launch, the app opens a Terminal installer if requirements are missing. It installs the app-local Python environment and runtime files inside the app bundle's resource directory. It can prepare:

- Homebrew, if missing and approved
- `ffmpeg`
- Ollama
- Python 3.10+ when needed
- the app's local Python environment
- an Ollama summary model
- the default Whisper speech model

After setup, the app opens its own **Local Meeting Note Taker** window. It should not require Safari, Chrome, or another browser.

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

## Build A Redistributable Zip

From the repo root:

```bash
./package_redistributable.sh
```

The generated zip excludes local `.venv`, logs, notes, uploads, recordings, and machine-specific PID/port files.

## Release Automation

GitHub Actions builds the redistributable zip only when a GitHub Release is published. Normal pushes and pull requests do not build artifacts.

To publish a release:

```bash
git tag v0.1.1
git push origin v0.1.1
gh release create v0.1.1 --title "Local Meeting Note Taker v0.1.1" --notes "Release notes"
```

The release workflow builds `LocalMeetingNoteTaker-redistributable.zip` and attaches it to that release.

## Project Layout

```text
.
├── Local Meeting Note Taker.app
├── INSTALL - Local Meeting Note Taker.command
├── OPEN ME - Local Meeting Note Taker.command
├── local-meeting-note-taker/
│   ├── app.py
│   ├── launcher.py
│   ├── install_requirements.sh
│   ├── launch_app.sh
│   ├── static/
│   ├── templates/
│   └── requirements.txt
└── package_redistributable.sh
```

## Notes

This app is not currently Apple-signed or notarized. On a new Mac, users may need to right-click the app and choose **Open** the first time.
