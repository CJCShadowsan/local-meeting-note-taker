# Local Meeting Note Taker

This is a Mac-runnable, local-first desktop app packaged around an embedded local web UI, inspired by the Medium article:
https://medium.com/data-science-collective/i-built-an-self-hosted-ai-meeting-note-taker-that-runs-100-offline-heres-how-you-can-too-d110b7ef0b95

It uses the same core pattern from the article:

- Flask for the local app server
- Swift `WKWebView` for the native macOS app window
- Pydub and `ffmpeg` to split audio into chunks
- Whisper running locally for transcription
- Ollama running locally for meeting-minute summaries

The app supports uploading audio/video files and recording microphone plus application audio from the packaged macOS app. It starts a private local server behind the scenes, opens its own native app window, and saves Markdown notes and JSON results under `~/Library/Application Support/Local Meeting Note Taker`.

## Application Shape

This folder is the self-contained local webapp application. For source/manual runs, keep the whole `local-meeting-note-taker` folder together; the `.app` inside it is a launcher for the bundled webapp, Python environment, data folder, logs, and scripts.

You can move the folder elsewhere on the same Mac. If you move it to another Mac manually, the first launch can run repair setup so the Python environment and local dependencies match that machine.

For distribution, use `LocalMeetingNoteTaker-installer.pkg` from the GitHub release assets for the normal install path. It installs `Local Meeting Note Taker.app` into `/Applications`, prepares all required local runtime components inside the installed app resource directory, sets executable permissions, removes quarantine from the installed app path, and ad-hoc signs the final installed app so macOS privacy permissions have a stable app identity. The release also includes `LocalMeetingNoteTaker-redistributable.zip` for manual drag-to-Applications installs; GitHub's automatic source-code archive is not an app download.

## Requirements

- macOS
- Python 3.10 or newer
- Homebrew, recommended for `ffmpeg` and Ollama
- Enough disk space for Python packages and local AI models

On a fresh Mac, the package installer prepares these for the user:

- Homebrew, if missing
- `ffmpeg`
- Ollama
- Python 3.10+ when the system Python is missing or too old
- the app's Python environment from `requirements.txt`
- an Ollama summary model
- the default Whisper speech model

Manual equivalent:

```bash
./install_requirements.sh
```

If you already have an Ollama model installed, the app will auto-select the first local model unless you set `OLLAMA_MODEL` yourself. After the Python packages and AI models are installed, processing happens locally.

## Setup

From this folder, to repair/reinstall requirements manually:

```bash
./setup.sh
```

## Run As An App

Double-click either:

- `Local Meeting Note Taker.app`
- `Start Local Meeting Note Taker.command`

The launcher checks whether requirements are ready. A package install should already have completed setup, so launching from `/Applications` starts or reuses the local app server and opens a **Local Meeting Note Taker** desktop window. If a manual zip install or damaged install is missing requirements, the app can still open a repair setup window. The app uses the native Swift recording bridge for live capture, and macOS may ask for Microphone and System Audio Recording access the first time recording starts. It should not open Safari, Chrome, Terminal, or another external browser for the normal app path.

To stop the saved webapp process, double-click:

- `Stop Local Meeting Note Taker.command`

Or use the terminal commands:

```bash
./run.sh
```

```bash
./stop.sh
```

Runtime logs are written to `~/Library/Application Support/Local Meeting Note Taker/logs/webapp.log`. Package install logs are written to `Contents/Resources/local-meeting-note-taker/data/logs/pkg-install.log` inside the installed app, and repair setup-window logs are written to `~/Library/Application Support/Local Meeting Note Taker/logs/setup-window.log`. The saved process id and selected port are kept in `~/Library/Application Support/Local Meeting Note Taker/app.pid` and `app.port`.

Browser fallback for source/manual runs:

```bash
.venv/bin/python launcher.py --browser
```

## Disclosed Meeting Capture

The app requires you to confirm that participants have been informed before recording or uploading. The capture panel also includes a copyable disclosure you can paste into Teams, Google Meet, Zoom, or the calendar invite.

Default disclosure:

```text
I’m recording/transcribing this meeting locally on my Mac to generate notes. The audio is processed locally, and the raw source audio will be deleted after processing unless retention is explicitly changed. Please say if you do not consent.
```

The source audio is deleted after processing by default. Uncheck **Delete source audio after processing** only when you intentionally want to keep the raw audio under `~/Library/Application Support/Local Meeting Note Taker/uploads`.

## Recording Meeting Audio On Mac

When launched as `Local Meeting Note Taker.app` on macOS 14.2 or newer, the app records through a native macOS bridge, not browser `MediaRecorder`. It captures your default microphone and application audio together, so in-person meetings, Teams, Google Meet, Zoom, browsers, and other apps can be transcribed from one recording.

The first recording may trigger macOS privacy prompts for:

- **Microphone** access for your local voice.
- **System Audio Recording** access for application audio.

If macOS asks for System Audio Recording access, allow it for Local Meeting Note Taker. Once Microphone and System Audio Recording access are granted, future recordings should start without repeated prompts.

Uploading an existing native Teams/Meet/Zoom recording is still the most reliable workflow, and those platforms provide their own participant recording notices.

### Input Notes

If recording captures the wrong input:

- macOS: check **System Settings > Privacy & Security > Microphone** and **System Audio Recording** for Local Meeting Note Taker.
- Teams/Meet/Zoom: confirm the meeting audio is playing through your Mac during capture.

## Model Settings

Defaults:

```bash
WHISPER_MODEL=base.en
OLLAMA_MODEL=first installed Ollama model, otherwise llama3.2:3b
APP_PORT=5055
```

Examples:

```bash
WHISPER_MODEL=small.en ./run.sh
OLLAMA_MODEL=phi4:latest ./run.sh
APP_PORT=6060 ./run.sh
```

Whisper model tradeoffs:

- `tiny.en`: fastest, least accurate
- `base.en`: good default for quick notes
- `small.en`: better accuracy, slower
- `medium.en` or `large-v3`: much slower and heavier, better for difficult audio

## Outputs

Each completed run creates:

- Markdown meeting notes in `~/Library/Application Support/Local Meeting Note Taker/notes`
- JSON with transcript segments and settings in `~/Library/Application Support/Local Meeting Note Taker/results`
- Uploaded source files in `~/Library/Application Support/Local Meeting Note Taker/uploads` only when source-audio deletion is disabled

The app's **History** section lists saved notes and older JSON-only transcript results. Use **Markdown** to download a saved `.md` note or generated Markdown transcript, or **Delete** then **Confirm delete** to remove the note, JSON result, uploaded source copy, and retained native recording when those artifacts are available.

If Ollama is not running, the app still transcribes audio and writes fallback notes with the transcript.

## Privacy Notes

This app does not send your recordings to cloud transcription or summarization services. The first setup and model downloads use the internet through `pip`, Whisper model download, Homebrew, and Ollama model pulls. Once dependencies and models are installed, the transcription and summarization path is local.
