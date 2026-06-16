Local Meeting Note Taker
========================

Double-click:

  Local Meeting Note Taker.app

You may drag Local Meeting Note Taker.app into /Applications first. The app contains its own local app resources and will install its Python environment inside the app bundle on first launch.

If first-run setup is needed, the app opens a Terminal installer. That installer prepares:

  - Homebrew, if missing and approved
  - ffmpeg
  - Ollama
  - Python 3.10+ when needed
  - the app's local Python environment
  - a local Ollama summary model
  - the default Whisper speech model

If the app needs repair, double-click:

  INSTALL - Local Meeting Note Taker.command

The sidecar local-meeting-note-taker folder is included for manual repair/source use, but the top-level app does not need it after being dragged to /Applications.
