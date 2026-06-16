from __future__ import annotations

import argparse
import os
import json
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path
from typing import Any


APP_ROOT = Path(__file__).resolve().parent
DATA_DIR = APP_ROOT / "data"
LOG_DIR = DATA_DIR / "logs"
PID_FILE = DATA_DIR / "app.pid"
PORT_FILE = DATA_DIR / "app.port"
LOG_FILE = LOG_DIR / "webapp.log"
DESKTOP_LOG_FILE = LOG_DIR / "desktop.log"
NATIVE_RECORDING_LOG_FILE = LOG_DIR / "native-recording.log"
NATIVE_RECORDINGS_DIR = DATA_DIR / "native-recordings"
DEFAULT_PORT = int(os.getenv("APP_PORT", "5055"))
APP_NAME = "Local Meeting Note Taker"
APP_IDENTIFIER = "local.meeting.note.taker"
APP_VERSION = "0.1.7"


def app_path_env() -> str:
    preferred = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    seen: set[str] = set()
    paths: list[str] = []
    for folder in preferred + os.getenv("PATH", "").split(os.pathsep):
        if folder and folder not in seen:
            seen.add(folder)
            paths.append(folder)
    return os.pathsep.join(paths)


os.environ["PATH"] = app_path_env()


def pid_is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def read_int(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except Exception:
        return None


def find_free_port(start_port: int) -> int:
    for port in range(start_port, start_port + 100):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.15)
            if sock.connect_ex(("127.0.0.1", port)) != 0:
                return port
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_ready(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1.5) as response:
            return 200 <= response.status < 500
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def server_identity(port: int) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/identity", timeout=1.5) as response:
            if not (200 <= response.status < 300):
                return None
            data = json.loads(response.read().decode("utf-8"))
    except (json.JSONDecodeError, urllib.error.URLError, TimeoutError, OSError):
        return None
    return data if isinstance(data, dict) else None


def server_matches_this_app(port: int) -> bool:
    identity = server_identity(port)
    return bool(
        identity
        and identity.get("app") == "local-meeting-note-taker"
        and identity.get("app_version") == APP_VERSION
        and identity.get("app_root") == str(APP_ROOT)
    )


def print_url(port: int) -> None:
    url = f"http://127.0.0.1:{port}"
    print(f"Local Meeting Note Taker is running at {url}")


def desktop_log(message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with DESKTOP_LOG_FILE.open("a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] {message}\n")


def configure_macos_app_identity() -> None:
    if sys.platform != "darwin":
        return
    try:
        import AppKit

        bundle = AppKit.NSBundle.mainBundle()
        info = bundle.infoDictionary()
        info["CFBundleName"] = APP_NAME
        info["CFBundleDisplayName"] = APP_NAME
        info["CFBundleIdentifier"] = APP_IDENTIFIER

        process = AppKit.NSProcessInfo.processInfo()
        if hasattr(process, "setProcessName_"):
            process.setProcessName_(APP_NAME)
    except Exception as error:
        desktop_log(f"Could not set macOS app identity: {type(error).__name__}: {error}")


def append_log(path: Path, message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with path.open("a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] {message}\n")


def app_python() -> Path:
    return APP_ROOT / ".venv" / "bin" / "python"


class NativeRecorderApi:
    def __init__(self, port: int) -> None:
        self.port = port
        self.process: subprocess.Popen[bytes] | None = None
        self.recording_path: Path | None = None
        self.started_at: float | None = None

    def _upload_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/upload"

    def _status(self, ok: bool, **payload: Any) -> dict[str, Any]:
        payload["ok"] = ok
        return payload

    def start_recording(self, settings: dict[str, Any]) -> dict[str, Any]:
        if self.process and self.process.poll() is None:
            return self._status(False, error="A native recording is already running.")
        if not settings.get("participants_notified"):
            return self._status(False, error="Confirm participant notice before recording.")
        ffmpeg_path = shutil_which("ffmpeg")
        if not ffmpeg_path:
            return self._status(False, error="ffmpeg was not found. Install it with: brew install ffmpeg")

        NATIVE_RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        self.recording_path = NATIVE_RECORDINGS_DIR / f"native-recording-{timestamp}.wav"
        self.started_at = time.time()
        device = str(settings.get("native_audio_device") or os.getenv("NATIVE_AUDIO_DEVICE", ":0"))
        command = [
            ffmpeg_path,
            "-hide_banner",
            "-y",
            "-f",
            "avfoundation",
            "-i",
            device,
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-acodec",
            "pcm_s16le",
            str(self.recording_path),
        ]
        append_log(NATIVE_RECORDING_LOG_FILE, "Starting native recorder: " + " ".join(command))
        try:
            log = NATIVE_RECORDING_LOG_FILE.open("ab")
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=log,
                stderr=subprocess.STDOUT,
                cwd=str(APP_ROOT),
            )
        except Exception as error:
            self.process = None
            self.recording_path = None
            append_log(NATIVE_RECORDING_LOG_FILE, f"Native recorder failed to start: {type(error).__name__}: {error}")
            return self._status(False, error=f"Native recorder failed to start: {type(error).__name__}: {error}")

        time.sleep(0.4)
        if self.process.poll() is not None:
            error = self._tail_log()
            self.process = None
            self.recording_path = None
            return self._status(False, error="Native recorder exited immediately. " + error)

        return self._status(True, path=str(self.recording_path))

    def stop_recording(self, settings: dict[str, Any]) -> dict[str, Any]:
        if not self.process or not self.recording_path:
            return self._status(False, error="No native recording is running.")

        process = self.process
        recording_path = self.recording_path
        append_log(NATIVE_RECORDING_LOG_FILE, f"Stopping native recorder pid={process.pid}")

        try:
            if process.stdin:
                process.stdin.write(b"q\n")
                process.stdin.flush()
        except Exception:
            process.terminate()

        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)

        self.process = None
        self.recording_path = None

        if not recording_path.exists() or recording_path.stat().st_size < 1024:
            return self._status(False, error="Native recording did not produce usable audio. " + self._tail_log())

        try:
            response = self._upload_recording(recording_path, settings)
            if settings.get("delete_source_audio", True):
                recording_path.unlink(missing_ok=True)
            return response
        except Exception as error:
            append_log(NATIVE_RECORDING_LOG_FILE, f"Native recording upload failed: {type(error).__name__}: {error}")
            return self._status(False, error=f"Native recording upload failed: {type(error).__name__}: {error}")

    def _upload_recording(self, recording_path: Path, settings: dict[str, Any]) -> dict[str, Any]:
        import requests

        form = {
            "title": str(settings.get("title", "")),
            "whisper_model": str(settings.get("whisper_model", "base.en")),
            "language": str(settings.get("language", "en")),
            "ollama_model": str(settings.get("ollama_model", "")),
            "ollama_base_url": str(settings.get("ollama_base_url", "http://127.0.0.1:11434")),
            "chunk_minutes": str(settings.get("chunk_minutes", "10")),
            "summary_chunk_chars": str(settings.get("summary_chunk_chars", "12000")),
            "participants_notified": str(bool(settings.get("participants_notified"))).lower(),
            "delete_source_audio": str(bool(settings.get("delete_source_audio", True))).lower(),
        }
        with recording_path.open("rb") as audio:
            response = requests.post(
                self._upload_url(),
                data=form,
                files={"file": (recording_path.name, audio, "audio/wav")},
                timeout=(5, 120),
            )
        data = response.json()
        if not response.ok:
            raise RuntimeError(data.get("error") or f"Upload failed with status {response.status_code}")
        return self._status(True, **data)

    def _tail_log(self) -> str:
        try:
            lines = NATIVE_RECORDING_LOG_FILE.read_text(encoding="utf-8", errors="ignore").splitlines()
        except Exception:
            return ""
        return " ".join(lines[-8:])


def shutil_which(command: str) -> str | None:
    for folder in os.getenv("PATH", "").split(os.pathsep):
        candidate = Path(folder) / command
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    for folder in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"):
        candidate = Path(folder) / command
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def start_server() -> tuple[int, int | None, bool]:
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    saved_pid = read_int(PID_FILE)
    saved_port = read_int(PORT_FILE) or DEFAULT_PORT
    if saved_pid and pid_is_running(saved_pid):
        if server_matches_this_app(saved_port):
            return saved_port, saved_pid, False
        append_log(
            LOG_FILE,
            f"Ignoring saved server pid={saved_pid} port={saved_port}; it does not match this app bundle.",
        )

    if server_matches_this_app(DEFAULT_PORT):
        PORT_FILE.write_text(str(DEFAULT_PORT), encoding="utf-8")
        return DEFAULT_PORT, None, False

    python_bin = app_python()
    if not python_bin.exists():
        raise RuntimeError("The bundled Python environment was not found. Run ./setup.sh once.")

    port = find_free_port(DEFAULT_PORT)
    env = os.environ.copy()
    env.update(
        {
            "APP_HOST": "127.0.0.1",
            "APP_PORT": str(port),
            "PATH": app_path_env(),
            "PYTHONUNBUFFERED": "1",
        }
    )

    with LOG_FILE.open("ab") as log:
        log.write(f"\n\n--- Launch {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n".encode())
        process = subprocess.Popen(
            [str(python_bin), str(APP_ROOT / "app.py")],
            cwd=str(APP_ROOT),
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    PID_FILE.write_text(str(process.pid), encoding="utf-8")
    PORT_FILE.write_text(str(port), encoding="utf-8")

    for _ in range(60):
        if process.poll() is not None:
            raise RuntimeError(f"The webapp exited during startup. See the log: {LOG_FILE}")
        if http_ready(port):
            return port, process.pid, True
        time.sleep(0.5)

    raise RuntimeError(f"The webapp did not become ready within 30 seconds. See the log: {LOG_FILE}")


def open_browser(port: int, no_open: bool) -> None:
    print_url(port)
    if not no_open:
        webbrowser.open(f"http://127.0.0.1:{port}")


def open_desktop_window(port: int) -> int:
    configure_macos_app_identity()
    try:
        import webview
    except Exception as error:
        message = f"Could not load the native app window: {type(error).__name__}: {error}"
        print(message)
        desktop_log(message)
        print("Run ./setup.sh, or launch with --browser as a fallback.")
        return 1

    url = f"http://127.0.0.1:{port}"
    print(f"Opening {APP_NAME} app window at {url}")
    desktop_log(f"Opening native app window at {url}")
    try:
        webview.create_window(
            APP_NAME,
            url,
            js_api=NativeRecorderApi(port),
            width=1260,
            height=900,
            min_size=(900, 650),
            confirm_close=False,
            text_select=True,
        )
        webview.start(debug=os.getenv("WEBVIEW_DEBUG", "") == "1")
        desktop_log("Native app window closed")
        return 0
    except Exception as error:
        message = f"Native app window failed: {type(error).__name__}: {error}"
        print(message)
        desktop_log(message)
        return 1


def start(no_open: bool = False, browser: bool = False) -> int:
    try:
        port, _pid, _owned = start_server()
    except Exception as error:
        print(error)
        return 1

    if no_open:
        print_url(port)
        return 0
    if browser:
        open_browser(port, no_open=False)
        return 0
    return open_desktop_window(port)


def stop() -> int:
    pid = read_int(PID_FILE)
    if not pid:
        print("No saved webapp process was found.")
        return 0

    if not pid_is_running(pid):
        print("Saved webapp process is no longer running.")
        PID_FILE.unlink(missing_ok=True)
        return 0

    os.kill(pid, signal.SIGTERM)
    for _ in range(20):
        if not pid_is_running(pid):
            PID_FILE.unlink(missing_ok=True)
            print("Stopped Local Meeting Note Taker.")
            return 0
        time.sleep(0.25)

    print(f"Process {pid} did not stop after SIGTERM.")
    return 1


def status() -> int:
    pid = read_int(PID_FILE)
    port = read_int(PORT_FILE) or DEFAULT_PORT
    running = bool(pid and pid_is_running(pid))
    ready = http_ready(port)
    print(f"pid={pid or 'none'} running={str(running).lower()} port={port} ready={str(ready).lower()}")
    return 0 if ready else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Launch the Local Meeting Note Taker desktop app.")
    parser.add_argument("--no-open", action="store_true", help="Start or reuse the server without opening a browser.")
    parser.add_argument("--browser", action="store_true", help="Open in the default browser instead of the app window.")
    parser.add_argument("--stop", action="store_true", help="Stop the saved webapp process.")
    parser.add_argument("--status", action="store_true", help="Print saved process status.")
    args = parser.parse_args()

    if args.stop:
        return stop()
    if args.status:
        return status()
    return start(no_open=args.no_open, browser=args.browser)


if __name__ == "__main__":
    raise SystemExit(main())
