Local Meeting Note Taker
========================

For app installs, download LocalMeetingNoteTaker-redistributable.zip from the GitHub release assets.
If you downloaded GitHub's Source code zip instead, that is source material, not the packaged app.

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

If the app needs repair, run it again from /Applications. The app-local installer lives inside the app bundle.
