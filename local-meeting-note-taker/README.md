# Local Meeting Note Taker

This is a Mac-runnable, local-first desktop app packaged around an embedded local web UI, inspired by the Medium article:
https://medium.com/data-science-collective/i-built-an-self-hosted-ai-meeting-note-taker-that-runs-100-offline-heres-how-you-can-too-d110b7ef0b95

It uses the same core pattern from the article:

- Flask for the local app server
- pywebview for the native macOS app window
- Pydub and `ffmpeg` to split audio into chunks
- Whisper running locally for transcription
- Ollama running locally for meeting-minute summaries

The app supports uploading audio/video files and recording from the app window microphone permissions. It starts a private local server behind the scenes, opens its own native app window, and saves Markdown notes and JSON results under `data/notes` and `data/results`.

## Application Shape

This folder is the self-contained local webapp application. Keep the whole `local-meeting-note-taker` folder together; the `.app` inside it is a launcher for the bundled webapp, Python environment, data folder, logs, and scripts.

You can move the folder elsewhere on the same Mac. If you move it to another Mac, the first launch will run the installer so the Python environment and local dependencies match that machine.

For distribution, share the whole `outputs` folder or zip it. The top-level `Local Meeting Note Taker.app` launches the app, and `INSTALL - Local Meeting Note Taker.command` is an explicit installer/repair launcher.

## Requirements

- macOS
- Python 3.10 or newer
- Homebrew, recommended for `ffmpeg` and Ollama
- Enough disk space for Python packages and local AI models

On a fresh Mac, first launch can install these for the user:

- Homebrew, if missing and the user approves it
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

The launcher checks whether requirements are ready. If not, it opens a Terminal first-run installer. After installation, it starts or reuses the local app server and opens a **Local Meeting Note Taker** desktop window. It should not open Safari, Chrome, or another external browser.

To stop the saved webapp process, double-click:

- `Stop Local Meeting Note Taker.command`

Or use the terminal commands:

```bash
./run.sh
```

```bash
./stop.sh
```

Runtime logs are written to `data/logs/webapp.log`. The saved process id and selected port are kept in `data/app.pid` and `data/app.port`.

Browser fallback, only if the native app window has trouble:

```bash
.venv/bin/python launcher.py --browser
```

## Disclosed Meeting Capture

The app requires you to confirm that participants have been informed before recording or uploading. The capture panel also includes a copyable disclosure you can paste into Teams, Google Meet, Zoom, or the calendar invite.

Default disclosure:

```text
I’m recording/transcribing this meeting locally on my Mac to generate notes. The audio is processed locally, and the raw source audio will be deleted after processing unless retention is explicitly changed. Please say if you do not consent.
```

The source audio is deleted after processing by default. Uncheck **Delete source audio after processing** only when you intentionally want to keep the raw audio under `data/uploads`.

## Recording Meeting Audio On Mac

When launched as `Local Meeting Note Taker.app`, the app records through a native macOS bridge, not browser `MediaRecorder`. This avoids the embedded-WebKit limitation where the app window may report that browser recording is unsupported.

The **Mac input device** field defaults to `:0`, which means ffmpeg's first AVFoundation audio input. If the wrong input is captured, list audio devices from Terminal:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Then set **Mac input device** to the desired audio index, such as `:1` or `:2`.

For an in-person meeting, use your Mac microphone input. For Teams, Google Meet, Zoom, or system audio, route meeting audio into a virtual input such as BlackHole, Loopback, or an Aggregate Device, then set **Mac input device** to that audio input's AVFoundation index.

### BlackHole Setup

BlackHole is the free route. Loopback or Audio Hijack are easier if you want a polished paid tool.

1. Install BlackHole:

```bash
brew install --cask blackhole-2ch
```

2. Open **Audio MIDI Setup** on macOS.
3. Create a **Multi-Output Device** containing your normal speakers/headphones and BlackHole.
4. Set Teams/Meet/Zoom output, or macOS system output, to that Multi-Output Device.
5. In the app, set **Mac input device** to the BlackHole audio device index, then click **Start recording**.
6. If you also need your own microphone captured, create an **Aggregate Device** or use Loopback to mix your mic plus meeting audio into one virtual input.

Uploading an existing native Teams/Meet/Zoom recording is still the most reliable workflow, and those platforms provide their own participant recording notices.

### Input Notes

If recording captures the wrong input:

- Run the `ffmpeg -f avfoundation -list_devices true -i ""` command above and try the correct `:N` audio index.
- macOS: check **System Settings > Privacy & Security > Microphone** for Local Meeting Note Taker, Terminal, Python, or ffmpeg permission prompts.
- Teams/Meet/Zoom: confirm the meeting audio is actually routed to the virtual device.

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

- Markdown meeting notes in `data/notes`
- JSON with transcript segments and settings in `data/results`
- Uploaded source files in `data/uploads` only when source-audio deletion is disabled

If Ollama is not running, the app still transcribes audio and writes fallback notes with the transcript.

## Privacy Notes

This app does not send your recordings to cloud transcription or summarization services. The first setup and model downloads use the internet through `pip`, Whisper model download, Homebrew, and Ollama model pulls. Once dependencies and models are installed, the transcription and summarization path is local.
