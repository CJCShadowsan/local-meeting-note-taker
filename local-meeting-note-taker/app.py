from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests
from flask import Flask, Response, jsonify, render_template, request, send_file
from werkzeug.utils import secure_filename


BASE_DIR = Path(__file__).resolve().parent


def configured_data_dir() -> Path:
    value = os.getenv("LMNT_DATA_DIR", "").strip()
    if value:
        return Path(value).expanduser()
    return BASE_DIR / "data"


DATA_DIR = configured_data_dir()
UPLOAD_DIR = DATA_DIR / "uploads"
RESULTS_DIR = DATA_DIR / "results"
NOTES_DIR = DATA_DIR / "notes"
NATIVE_RECORDINGS_DIR = DATA_DIR / "native-recordings"
LOG_DIR = DATA_DIR / "logs"
NATIVE_RECORDING_LOG_FILE = LOG_DIR / "native-recording.log"
APP_VERSION = "0.1.16"


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

for folder in (UPLOAD_DIR, RESULTS_DIR, NOTES_DIR, NATIVE_RECORDINGS_DIR, LOG_DIR):
    folder.mkdir(parents=True, exist_ok=True)


def migrate_legacy_data() -> None:
    legacy_dir = BASE_DIR / "data"
    try:
        same_location = DATA_DIR.resolve() == legacy_dir.resolve()
    except OSError:
        same_location = False
    if same_location or not legacy_dir.exists():
        return

    for child in ("uploads", "results", "notes", "native-recordings"):
        source_dir = legacy_dir / child
        target_dir = DATA_DIR / child
        if not source_dir.exists():
            continue
        target_dir.mkdir(parents=True, exist_ok=True)
        for source in source_dir.iterdir():
            target = target_dir / source.name
            if source.is_file() and not target.exists():
                try:
                    shutil.copy2(source, target)
                except OSError:
                    continue


migrate_legacy_data()


ALLOWED_EXTENSIONS = {
    "aac",
    "aiff",
    "flac",
    "m4a",
    "m4v",
    "mp3",
    "mp4",
    "ogg",
    "wav",
    "webm",
}


app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = int(os.getenv("MAX_UPLOAD_MB", "2048")) * 1024 * 1024

JOBS: dict[str, dict[str, Any]] = {}
JOBS_LOCK = threading.Lock()
WHISPER_MODELS: dict[str, Any] = {}
WHISPER_LOCK = threading.Lock()
NATIVE_RECORDER_LOCK = threading.Lock()
NATIVE_RECORDER_PROCESS: subprocess.Popen[bytes] | None = None
NATIVE_RECORDER_PATH: Path | None = None


def env_default(name: str, fallback: str) -> str:
    value = os.getenv(name, "").strip()
    return value or fallback


def detect_ollama_model(base_url: str, fallback: str) -> str:
    configured = os.getenv("OLLAMA_MODEL", "").strip()
    if configured:
        return configured
    try:
        response = requests.get(base_url.rstrip("/") + "/api/tags", timeout=0.75)
        response.raise_for_status()
        for item in response.json().get("models", []):
            name = item.get("name")
            if name:
                return str(name)
    except Exception:
        pass
    return fallback


DEFAULT_OLLAMA_BASE_URL = env_default("OLLAMA_BASE_URL", "http://127.0.0.1:11434")

DEFAULTS = {
    "whisper_model": env_default("WHISPER_MODEL", "base.en"),
    "language": env_default("WHISPER_LANGUAGE", "en"),
    "ollama_base_url": DEFAULT_OLLAMA_BASE_URL,
    "ollama_model": detect_ollama_model(DEFAULT_OLLAMA_BASE_URL, "llama3.2:3b"),
    "chunk_minutes": env_default("CHUNK_MINUTES", "10"),
    "summary_chunk_chars": env_default("SUMMARY_CHUNK_CHARS", "12000"),
}


def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def allowed_file(filename: str) -> bool:
    suffix = Path(filename).suffix.lower().lstrip(".")
    return suffix in ALLOWED_EXTENSIONS


def clean_whitespace(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def slugify(value: str, fallback: str = "meeting") -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value).strip("-").lower()
    return slug[:72] or fallback


def format_seconds(seconds: float) -> str:
    seconds = max(0, int(seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def update_job(job_id: str, **updates: Any) -> None:
    with JOBS_LOCK:
        job = JOBS.setdefault(job_id, {})
        job.update(updates)
        job["updated_at"] = now_iso()


def get_job(job_id: str) -> dict[str, Any] | None:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        return dict(job) if job else None


def parse_float(value: str, fallback: float, minimum: float, maximum: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return fallback
    return min(max(parsed, minimum), maximum)


def parse_int(value: str, fallback: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return fallback
    return min(max(parsed, minimum), maximum)


def parse_bool(value: Any | None, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def settings_from_values(values: Any) -> dict[str, Any]:
    chunk_default = parse_float(DEFAULTS["chunk_minutes"], 10, 1, 30)
    summary_default = parse_int(DEFAULTS["summary_chunk_chars"], 12000, 4000, 50000)

    def value(name: str, fallback: str = "") -> str:
        raw = values.get(name, fallback)
        if raw is None:
            raw = fallback
        return str(raw).strip()

    return {
        "whisper_model": value("whisper_model", DEFAULTS["whisper_model"]) or DEFAULTS["whisper_model"],
        "language": value("language", DEFAULTS["language"]),
        "ollama_base_url": value("ollama_base_url", DEFAULTS["ollama_base_url"]) or DEFAULTS["ollama_base_url"],
        "ollama_model": value("ollama_model", DEFAULTS["ollama_model"]) or DEFAULTS["ollama_model"],
        "chunk_minutes": parse_float(
            value("chunk_minutes", str(chunk_default)), chunk_default, 1, 30
        ),
        "summary_chunk_chars": parse_int(
            value("summary_chunk_chars", str(summary_default)),
            summary_default,
            4000,
            50000,
        ),
        "participants_notified": parse_bool(values.get("participants_notified")),
        "delete_source_audio": parse_bool(values.get("delete_source_audio"), True),
    }


def form_settings() -> dict[str, Any]:
    return settings_from_values(request.form)


def append_native_log(message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with NATIVE_RECORDING_LOG_FILE.open("a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] {message}\n")


def tail_native_log() -> str:
    try:
        lines = NATIVE_RECORDING_LOG_FILE.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return ""
    return " ".join(lines[-8:])


def get_whisper_model(model_name: str) -> Any:
    with WHISPER_LOCK:
        if model_name not in WHISPER_MODELS:
            import whisper

            kwargs: dict[str, Any] = {}
            device = os.getenv("WHISPER_DEVICE", "").strip()
            if device:
                kwargs["device"] = device
            WHISPER_MODELS[model_name] = whisper.load_model(model_name, **kwargs)
        return WHISPER_MODELS[model_name]


def split_audio(audio_path: Path, temp_dir: Path, segment_minutes: float) -> tuple[list[dict[str, Any]], int]:
    from pydub import AudioSegment

    audio = AudioSegment.from_file(audio_path)
    audio = audio.set_channels(1).set_frame_rate(16000)
    segment_ms = int(segment_minutes * 60 * 1000)
    total_ms = len(audio)
    segments: list[dict[str, Any]] = []

    for index, start_ms in enumerate(range(0, total_ms, segment_ms), start=1):
        end_ms = min(start_ms + segment_ms, total_ms)
        segment = audio[start_ms:end_ms]
        output_path = temp_dir / f"segment_{index:04d}.wav"
        segment.export(output_path, format="wav")
        segments.append(
            {
                "path": output_path,
                "index": index,
                "start_seconds": start_ms / 1000,
                "end_seconds": end_ms / 1000,
            }
        )

    return segments, total_ms


def transcribe_segment(segment_path: Path, offset_seconds: float, settings: dict[str, Any]) -> list[dict[str, Any]]:
    model = get_whisper_model(settings["whisper_model"])
    kwargs: dict[str, Any] = {
        "fp16": os.getenv("WHISPER_FP16", "").lower() in {"1", "true", "yes"},
    }
    if settings["language"]:
        kwargs["language"] = settings["language"]

    result = model.transcribe(str(segment_path), **kwargs)
    raw_segments = result.get("segments") or []
    if raw_segments:
        return [
            {
                "start": offset_seconds + float(item.get("start", 0)),
                "end": offset_seconds + float(item.get("end", 0)),
                "text": clean_whitespace(item.get("text", "")),
            }
            for item in raw_segments
            if clean_whitespace(item.get("text", ""))
        ]

    text = clean_whitespace(result.get("text", ""))
    return [{"start": offset_seconds, "end": offset_seconds, "text": text}] if text else []


def transcript_from_segments(segments: list[dict[str, Any]]) -> str:
    lines = []
    for segment in segments:
        start = format_seconds(segment["start"])
        end = format_seconds(segment["end"])
        lines.append(f"[{start} - {end}] {segment['text']}")
    return "\n".join(lines)


def chunk_text(text: str, max_chars: int) -> list[str]:
    paragraphs = [line.strip() for line in text.splitlines() if line.strip()]
    chunks: list[str] = []
    current = ""
    for paragraph in paragraphs:
        candidate = f"{current}\n{paragraph}".strip()
        if len(candidate) <= max_chars:
            current = candidate
            continue
        if current:
            chunks.append(current)
        if len(paragraph) <= max_chars:
            current = paragraph
        else:
            for start in range(0, len(paragraph), max_chars):
                chunks.append(paragraph[start : start + max_chars])
            current = ""
    if current:
        chunks.append(current)
    return chunks or [text[:max_chars]]


def query_ollama(prompt: str, settings: dict[str, Any]) -> str:
    url = settings["ollama_base_url"].rstrip("/") + "/api/generate"
    payload = {
        "model": settings["ollama_model"],
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.2},
    }
    response = requests.post(url, json=payload, timeout=(5, 900))
    response.raise_for_status()
    data = response.json()
    if data.get("error"):
        raise RuntimeError(data["error"])
    return str(data.get("response", "")).strip()


def minutes_prompt(title: str, transcript: str) -> str:
    return f"""You are a careful meeting note taker. Produce concise professional meeting minutes in Markdown.

Meeting title: {title or "Untitled meeting"}

Return exactly these sections:
# Meeting Minutes
## Overview
## Decisions
## Action Items
Use a Markdown table with columns Owner, Task, Due Date. Use "Unassigned" or "Not stated" when needed.
## Risks And Follow-ups
## Key Details

Transcript:
---
{transcript}
"""


def section_prompt(title: str, section_number: int, section_count: int, transcript: str) -> str:
    return f"""Summarize section {section_number} of {section_count} from this meeting transcript.
Capture decisions, action items with owners/due dates, risks, follow-ups, and important details.
Return compact Markdown bullets only.

Meeting title: {title or "Untitled meeting"}

Transcript section:
---
{transcript}
"""


def final_minutes_prompt(title: str, partial_summaries: list[str]) -> str:
    summaries = "\n\n---\n\n".join(partial_summaries)
    return f"""Combine these section summaries into final professional meeting minutes in Markdown.

Meeting title: {title or "Untitled meeting"}

Return exactly these sections:
# Meeting Minutes
## Overview
## Decisions
## Action Items
Use a Markdown table with columns Owner, Task, Due Date. Merge duplicates.
## Risks And Follow-ups
## Key Details

Section summaries:
---
{summaries}
"""


def fallback_minutes(title: str, transcript: str, error: Exception) -> str:
    sentences = re.split(r"(?<=[.!?])\s+", clean_whitespace(transcript))
    keywords = ("action", "todo", "follow up", "owner", "deadline", "decide", "decision", "risk", "next")
    notable = [sentence for sentence in sentences if any(word in sentence.lower() for word in keywords)]
    notable = notable[:12]
    excerpt = "\n".join(transcript.splitlines()[:18])

    notable_block = "\n".join(f"- {item}" for item in notable) or "- No obvious action-oriented lines were detected."
    return f"""# Meeting Minutes

## Overview
Ollama summarization was unavailable, so this fallback note was generated from the transcript.

## Decisions
- Not detected by the fallback summarizer.

## Action Items
| Owner | Task | Due Date |
| --- | --- | --- |
| Unassigned | Review transcript manually for actions. | Not stated |

## Risks And Follow-ups
{notable_block}

## Key Details
Meeting title: {title or "Untitled meeting"}

Ollama error: `{type(error).__name__}: {error}`

Transcript excerpt:

```text
{excerpt}
```
"""


def summarize_transcript(job_id: str, title: str, transcript: str, settings: dict[str, Any]) -> tuple[str, str]:
    if not transcript.strip():
        return "# Meeting Minutes\n\nNo speech was detected in the audio.", "skipped"

    chunks = chunk_text(transcript, int(settings["summary_chunk_chars"]))
    try:
        if len(chunks) == 1:
            update_job(job_id, phase="Summarizing transcript with Ollama", progress=92)
            return query_ollama(minutes_prompt(title, transcript), settings), "ollama"

        partial_summaries = []
        for index, chunk in enumerate(chunks, start=1):
            progress = 82 + int((index / len(chunks)) * 10)
            update_job(
                job_id,
                phase=f"Summarizing transcript section {index}/{len(chunks)}",
                progress=progress,
            )
            partial_summaries.append(query_ollama(section_prompt(title, index, len(chunks), chunk), settings))
        update_job(job_id, phase="Combining section summaries", progress=94)
        return query_ollama(final_minutes_prompt(title, partial_summaries), settings), "ollama"
    except Exception as error:
        return fallback_minutes(title, transcript, error), "fallback"


def save_outputs(
    job_id: str,
    title: str,
    source_filename: str,
    duration_seconds: float,
    transcript: str,
    segments: list[dict[str, Any]],
    minutes: str,
    summary_mode: str,
    settings: dict[str, Any],
) -> tuple[Path, Path]:
    created = datetime.now().strftime("%Y%m%d-%H%M%S")
    note_slug = slugify(title or Path(source_filename).stem)
    basename = f"{created}-{note_slug}-{job_id[:8]}"
    json_path = RESULTS_DIR / f"{basename}.json"
    markdown_path = NOTES_DIR / f"{basename}.md"

    result = {
        "job_id": job_id,
        "title": title,
        "source_filename": source_filename,
        "created_at": now_iso(),
        "duration_seconds": duration_seconds,
        "summary_mode": summary_mode,
        "participants_notified": settings["participants_notified"],
        "delete_source_audio": settings["delete_source_audio"],
        "settings": settings,
        "minutes": minutes,
        "transcript": transcript,
        "segments": segments,
    }
    json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")

    markdown = f"""---
title: {title or Path(source_filename).stem}
source: {source_filename}
created: {result["created_at"]}
duration: {format_seconds(duration_seconds)}
summary_mode: {summary_mode}
participants_notified: {str(settings["participants_notified"]).lower()}
delete_source_audio: {str(settings["delete_source_audio"]).lower()}
---

{minutes}

---

# Full Transcript

```text
{transcript}
```
"""
    markdown_path.write_text(markdown, encoding="utf-8")
    return markdown_path, json_path


def delete_source_audio(file_path: Path) -> bool:
    try:
        file_path.unlink(missing_ok=True)
        return True
    except Exception:
        return False


def safe_history_name(name: str) -> str | None:
    path = Path(name)
    if path.name != name or path.suffix.lower() not in {".md", ".json"}:
        return None
    return name


def history_paths_from_name(name: str) -> tuple[Path, Path] | None:
    safe_name = safe_history_name(name)
    if not safe_name:
        return None
    stem = Path(safe_name).stem
    return NOTES_DIR / f"{stem}.md", RESULTS_DIR / f"{stem}.json"


def read_result_metadata(result_path: Path) -> dict[str, Any]:
    if not result_path.exists():
        return {}
    try:
        data = json.loads(result_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def history_display_name(path: Path, metadata: dict[str, Any]) -> str:
    title = str(metadata.get("title") or "").strip()
    return title or path.name


def history_payload(path: Path) -> dict[str, Any]:
    result_path = RESULTS_DIR / f"{path.stem}.json"
    metadata = read_result_metadata(result_path)
    stat = path.stat()
    encoded_name = quote(path.name, safe="")
    kind = "note" if path.suffix.lower() == ".md" else "transcript"
    source = str(metadata.get("source_filename") or "").strip()
    return {
        "name": path.name,
        "display_name": history_display_name(path, metadata),
        "description": source or path.name,
        "kind": kind,
        "size": stat.st_size,
        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
        "markdown_download": f"/history/{encoded_name}/download",
        "delete_url": f"/history/{encoded_name}/delete",
    }


def markdown_from_result(result_path: Path) -> str:
    metadata = read_result_metadata(result_path)
    title = str(metadata.get("title") or Path(metadata.get("source_filename") or result_path.stem).stem)
    source = str(metadata.get("source_filename") or "Unknown")
    created = str(metadata.get("created_at") or datetime.fromtimestamp(result_path.stat().st_mtime).isoformat())
    try:
        duration_seconds = float(metadata.get("duration_seconds") or 0)
    except (TypeError, ValueError):
        duration_seconds = 0
    duration = format_seconds(duration_seconds)
    summary_mode = str(metadata.get("summary_mode") or "unknown")
    participants_notified = str(bool(metadata.get("participants_notified"))).lower()
    delete_audio = str(bool(metadata.get("delete_source_audio"))).lower()
    minutes = str(metadata.get("minutes") or "# Meeting Minutes\n\nNo meeting minutes were saved.")
    transcript = str(metadata.get("transcript") or "")

    return f"""---
title: {title}
source: {source}
created: {created}
duration: {duration}
summary_mode: {summary_mode}
participants_notified: {participants_notified}
delete_source_audio: {delete_audio}
---

{minutes}

---

# Full Transcript

```text
{transcript}
```
"""


def valid_job_id(value: str) -> bool:
    try:
        uuid.UUID(value)
    except (TypeError, ValueError):
        return False
    return True


def related_history_artifacts(markdown_path: Path, result_path: Path) -> list[tuple[str, Path]]:
    candidates: list[tuple[str, Path]] = [("markdown", markdown_path), ("result", result_path)]
    job_id = ""
    source_filename = ""

    metadata = read_result_metadata(result_path)
    if metadata:
        job_id = str(metadata.get("job_id") or "")
        source_filename = secure_filename(str(metadata.get("source_filename") or ""))

    if valid_job_id(job_id) and source_filename:
        candidates.append(("uploaded_audio", UPLOAD_DIR / f"{job_id}-{source_filename}"))
    elif valid_job_id(job_id):
        candidates.extend(("uploaded_audio", path) for path in UPLOAD_DIR.glob(f"{job_id}-*"))

    if source_filename:
        candidates.append(("native_recording", NATIVE_RECORDINGS_DIR / source_filename))

    unique: list[tuple[str, Path]] = []
    seen: set[Path] = set()
    for label, path in candidates:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append((label, path))
    return unique


def process_audio_file(job_id: str, file_path: Path, original_filename: str, title: str, settings: dict[str, Any]) -> None:
    try:
        update_job(job_id, status="running", phase="Preparing audio", progress=5)
        with tempfile.TemporaryDirectory(prefix="local-note-taker-") as temp_name:
            temp_dir = Path(temp_name)
            audio_segments, duration_ms = split_audio(file_path, temp_dir, settings["chunk_minutes"])
            if not audio_segments:
                raise RuntimeError("No audio segments were created from the file.")

            update_job(
                job_id,
                phase=f"Loading Whisper model {settings['whisper_model']}",
                progress=12,
                segment_count=len(audio_segments),
            )
            get_whisper_model(settings["whisper_model"])

            transcript_segments: list[dict[str, Any]] = []
            for index, segment in enumerate(audio_segments, start=1):
                transcribe_progress = 15 + int((index - 1) / len(audio_segments) * 65)
                update_job(
                    job_id,
                    phase=f"Transcribing segment {index}/{len(audio_segments)}",
                    progress=transcribe_progress,
                )
                transcript_segments.extend(
                    transcribe_segment(segment["path"], float(segment["start_seconds"]), settings)
                )

        transcript = transcript_from_segments(transcript_segments)
        update_job(job_id, phase="Preparing meeting minutes", progress=82, transcript=transcript)
        minutes, summary_mode = summarize_transcript(job_id, title, transcript, settings)
        markdown_path, json_path = save_outputs(
            job_id,
            title,
            original_filename,
            duration_ms / 1000,
            transcript,
            transcript_segments,
            minutes,
            summary_mode,
            settings,
        )
        update_job(
            job_id,
            status="completed",
            phase="Completed",
            progress=100,
            minutes=minutes,
            transcript=transcript,
            summary_mode=summary_mode,
            markdown_path=str(markdown_path),
            json_path=str(json_path),
        )
    except Exception as error:
        update_job(
            job_id,
            status="failed",
            phase="Failed",
            progress=100,
            error=f"{type(error).__name__}: {error}",
        )
    finally:
        if settings.get("delete_source_audio", True):
            update_job(job_id, source_deleted=delete_source_audio(file_path))


def queue_audio_job(
    file_path: Path,
    original_filename: str,
    title: str,
    settings: dict[str, Any],
    job_id: str | None = None,
) -> dict[str, Any]:
    job_id = job_id or str(uuid.uuid4())
    with JOBS_LOCK:
        JOBS[job_id] = {
            "job_id": job_id,
            "status": "queued",
            "phase": "Queued",
            "progress": 0,
            "source_filename": original_filename,
            "title": title,
            "settings": settings,
            "created_at": now_iso(),
            "updated_at": now_iso(),
        }

    worker = threading.Thread(
        target=process_audio_file,
        args=(job_id, file_path, original_filename, title, settings),
        daemon=True,
    )
    worker.start()
    return {"job_id": job_id, "status": "queued"}


def ollama_status(base_url: str) -> dict[str, Any]:
    try:
        response = requests.get(base_url.rstrip("/") + "/api/tags", timeout=2)
        response.raise_for_status()
        models = [item.get("name") for item in response.json().get("models", [])]
        return {"ok": True, "models": [item for item in models if item]}
    except Exception as error:
        return {"ok": False, "error": f"{type(error).__name__}: {error}"}


def import_status(module_name: str) -> dict[str, Any]:
    try:
        __import__(module_name)
        return {"ok": True}
    except Exception as error:
        return {"ok": False, "error": f"{type(error).__name__}: {error}"}


@app.get("/")
def index() -> str:
    return render_template("index.html", defaults=DEFAULTS)


@app.get("/identity")
def identity() -> Any:
    return jsonify(
        {
            "app": "local-meeting-note-taker",
            "app_version": APP_VERSION,
            "app_root": str(BASE_DIR),
        }
    )


@app.get("/health")
def health() -> Any:
    whisper_check = import_status("whisper")
    pydub_check = import_status("pydub")
    return jsonify(
        {
            "defaults": DEFAULTS,
            "checks": {
                "ffmpeg": bool(shutil.which("ffmpeg")),
                "whisper_package": whisper_check["ok"],
                "whisper_error": whisper_check.get("error"),
                "pydub_package": pydub_check["ok"],
                "pydub_error": pydub_check.get("error"),
            },
            "ollama": ollama_status(DEFAULTS["ollama_base_url"]),
        }
    )


@app.get("/notes")
def list_notes() -> Any:
    notes = []
    noted_stems = set()
    for path in NOTES_DIR.glob("*.md"):
        notes.append(history_payload(path))
        noted_stems.add(path.stem)
    for path in RESULTS_DIR.glob("*.json"):
        if path.stem not in noted_stems:
            notes.append(history_payload(path))
    notes.sort(key=lambda item: str(item["modified"]), reverse=True)
    return jsonify({"notes": notes, "count": len(notes)})


@app.get("/history/<path:name>/download")
def download_history_markdown(name: str) -> Any:
    paths = history_paths_from_name(name)
    if not paths:
        return jsonify({"error": "Saved transcript was not found."}), 404

    markdown_path, result_path = paths
    if markdown_path.exists():
        return send_file(markdown_path, as_attachment=True, download_name=markdown_path.name)
    if result_path.exists():
        response = Response(markdown_from_result(result_path), mimetype="text/markdown")
        response.headers.set("Content-Disposition", "attachment", filename=f"{result_path.stem}.md")
        return response
    return jsonify({"error": "Saved transcript was not found."}), 404


@app.get("/notes/<path:name>/download")
def download_note(name: str) -> Any:
    return download_history_markdown(name)


def delete_history_item(name: str) -> Any:
    paths = history_paths_from_name(name)
    if not paths:
        return jsonify({"error": "Saved transcript was not found."}), 404

    markdown_path, result_path = paths
    if not markdown_path.exists() and not result_path.exists():
        return jsonify({"error": "Saved transcript was not found."}), 404

    deleted = []
    failed = []
    for label, artifact_path in related_history_artifacts(markdown_path, result_path):
        if not artifact_path.exists():
            continue
        try:
            artifact_path.unlink()
            deleted.append({"kind": label, "name": artifact_path.name})
        except Exception as error:
            failed.append(
                {
                    "kind": label,
                    "name": artifact_path.name,
                    "error": f"{type(error).__name__}: {error}",
                }
            )

    status_code = 500 if failed else 200
    return jsonify({"deleted": deleted, "failed": failed}), status_code


@app.post("/history/<path:name>/delete")
def post_delete_history(name: str) -> Any:
    return delete_history_item(name)


@app.delete("/history/<path:name>")
def delete_history(name: str) -> Any:
    return delete_history_item(name)


@app.delete("/notes/<path:name>")
def delete_note(name: str) -> Any:
    return delete_history_item(name)


@app.post("/upload")
def upload_file() -> Any:
    if "file" not in request.files:
        return jsonify({"error": "No file was uploaded."}), 400

    file = request.files["file"]
    if not file or not file.filename:
        return jsonify({"error": "Choose an audio file first."}), 400

    if not allowed_file(file.filename):
        return jsonify({"error": f"Unsupported file type: {Path(file.filename).suffix}"}), 400

    settings = form_settings()
    if not settings["participants_notified"]:
        return jsonify({"error": "Confirm participant notice before recording or uploading."}), 400

    original_filename = secure_filename(file.filename)
    job_id = str(uuid.uuid4())
    saved_filename = f"{job_id}-{original_filename}"
    file_path = UPLOAD_DIR / saved_filename
    file.save(file_path)

    title = request.form.get("title", "").strip()
    return jsonify(queue_audio_job(file_path, original_filename, title, settings, job_id=job_id))


@app.post("/native/start")
def start_native_recording() -> Any:
    global NATIVE_RECORDER_PATH, NATIVE_RECORDER_PROCESS

    payload = request.get_json(silent=True) or {}
    settings = settings_from_values(payload)
    if not settings["participants_notified"]:
        return jsonify({"ok": False, "error": "Confirm participant notice before recording."}), 400

    ffmpeg_path = shutil.which("ffmpeg")
    if not ffmpeg_path:
        return jsonify({"ok": False, "error": "ffmpeg was not found. Install it with: brew install ffmpeg"}), 500

    with NATIVE_RECORDER_LOCK:
        if NATIVE_RECORDER_PROCESS and NATIVE_RECORDER_PROCESS.poll() is None:
            return jsonify({"ok": False, "error": "A native recording is already running."}), 409

        NATIVE_RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        recording_path = NATIVE_RECORDINGS_DIR / f"native-recording-{timestamp}.wav"
        device = str(payload.get("native_audio_device") or os.getenv("NATIVE_AUDIO_DEVICE", ":0"))
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
            str(recording_path),
        ]
        append_native_log("Starting native recorder: " + " ".join(command))

        try:
            log = NATIVE_RECORDING_LOG_FILE.open("ab")
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=log,
                stderr=subprocess.STDOUT,
                cwd=str(BASE_DIR),
            )
        except Exception as error:
            append_native_log(f"Native recorder failed to start: {type(error).__name__}: {error}")
            return jsonify({"ok": False, "error": f"Native recorder failed to start: {type(error).__name__}: {error}"}), 500

        time.sleep(0.4)
        if process.poll() is not None:
            return jsonify({"ok": False, "error": "Native recorder exited immediately. " + tail_native_log()}), 500

        NATIVE_RECORDER_PROCESS = process
        NATIVE_RECORDER_PATH = recording_path
        return jsonify({"ok": True, "path": str(recording_path)})


@app.post("/native/stop")
def stop_native_recording() -> Any:
    global NATIVE_RECORDER_PATH, NATIVE_RECORDER_PROCESS

    payload = request.get_json(silent=True) or {}
    settings = settings_from_values(payload)

    with NATIVE_RECORDER_LOCK:
        process = NATIVE_RECORDER_PROCESS
        recording_path = NATIVE_RECORDER_PATH
        NATIVE_RECORDER_PROCESS = None
        NATIVE_RECORDER_PATH = None

    if not process or not recording_path:
        return jsonify({"ok": False, "error": "No native recording is running."}), 400

    append_native_log(f"Stopping native recorder pid={process.pid}")
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

    if not recording_path.exists() or recording_path.stat().st_size < 1024:
        return jsonify({"ok": False, "error": "Native recording did not produce usable audio. " + tail_native_log()}), 500

    title = str(payload.get("title") or "").strip()
    queued = queue_audio_job(recording_path, recording_path.name, title, settings)
    return jsonify({"ok": True, **queued})


@app.get("/status/<job_id>")
def status(job_id: str) -> Any:
    job = get_job(job_id)
    if not job:
        return jsonify({"error": "Unknown job."}), 404
    if job.get("markdown_path"):
        job["markdown_download"] = f"/download/{job_id}/markdown"
    if job.get("json_path"):
        job["json_download"] = f"/download/{job_id}/json"
    return jsonify(job)


@app.get("/download/<job_id>/<kind>")
def download(job_id: str, kind: str) -> Any:
    job = get_job(job_id)
    if not job:
        return jsonify({"error": "Unknown job."}), 404
    key = "markdown_path" if kind == "markdown" else "json_path" if kind == "json" else ""
    if not key or not job.get(key):
        return jsonify({"error": "Result is not ready."}), 404
    path = Path(str(job[key]))
    if not path.exists():
        return jsonify({"error": "Saved result was not found."}), 404
    return send_file(path, as_attachment=True)


if __name__ == "__main__":
    host = os.getenv("APP_HOST", "127.0.0.1")
    port = int(os.getenv("APP_PORT", "5055"))
    print(f"Local Meeting Note Taker: http://{host}:{port}")
    app.run(host=host, port=port, debug=os.getenv("FLASK_DEBUG", "") == "1")
