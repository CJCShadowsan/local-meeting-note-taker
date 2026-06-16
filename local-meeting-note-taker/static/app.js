const elements = {
  healthChips: document.querySelector("#healthChips"),
  refreshHealth: document.querySelector("#refreshHealth"),
  meetingTitle: document.querySelector("#meetingTitle"),
  disclosureText: document.querySelector("#disclosureText"),
  copyDisclosure: document.querySelector("#copyDisclosure"),
  participantsNotified: document.querySelector("#participantsNotified"),
  deleteSourceAudio: document.querySelector("#deleteSourceAudio"),
  fileInput: document.querySelector("#fileInput"),
  chooseButton: document.querySelector("#chooseButton"),
  dropZone: document.querySelector("#dropZone"),
  fileName: document.querySelector("#fileName"),
  uploadButton: document.querySelector("#uploadButton"),
  recordButton: document.querySelector("#recordButton"),
  stopButton: document.querySelector("#stopButton"),
  recordingState: document.querySelector("#recordingState"),
  recordTimer: document.querySelector("#recordTimer"),
  whisperModel: document.querySelector("#whisperModel"),
  language: document.querySelector("#language"),
  ollamaModel: document.querySelector("#ollamaModel"),
  ollamaBaseUrl: document.querySelector("#ollamaBaseUrl"),
  chunkMinutes: document.querySelector("#chunkMinutes"),
  summaryChunkChars: document.querySelector("#summaryChunkChars"),
  nativeAudioDevice: document.querySelector("#nativeAudioDevice"),
  progressFill: document.querySelector("#progressFill"),
  statusText: document.querySelector("#statusText"),
  jobId: document.querySelector("#jobId"),
  resultPanel: document.querySelector("#resultPanel"),
  resultContent: document.querySelector("#resultContent"),
  copyButton: document.querySelector("#copyButton"),
  markdownDownload: document.querySelector("#markdownDownload"),
  jsonDownload: document.querySelector("#jsonDownload"),
  tabs: [...document.querySelectorAll(".tab")],
  refreshNotes: document.querySelector("#refreshNotes"),
  notesList: document.querySelector("#notesList"),
};

const urlParams = new URLSearchParams(window.location.search);
const nativeBridgeExpected = urlParams.get("native") === "1";

const state = {
  selectedFile: null,
  activeJobId: null,
  latestJob: null,
  currentTab: "minutes",
  recorder: null,
  recordChunks: [],
  recordStartedAt: 0,
  timerId: null,
  isBusy: false,
  pendingDelete: null,
  nativeRecording: false,
  nativeStarting: false,
  nativeApiReady: false,
  nativeBridgeExpected,
};

function setStatus(message, progress = null) {
  elements.statusText.textContent = message;
  if (progress !== null) {
    elements.progressFill.style.width = `${Math.max(0, Math.min(100, progress))}%`;
  }
}

function disclosureConfirmed() {
  return elements.participantsNotified.checked;
}

function updateCaptureControls() {
  const ready = disclosureConfirmed();
  const recorderReady = !state.nativeBridgeExpected || state.nativeApiReady;
  elements.uploadButton.disabled = state.isBusy || !state.selectedFile || !ready;
  elements.recordButton.disabled =
    state.isBusy || Boolean(state.recorder) || state.nativeRecording || state.nativeStarting || !ready || !recorderReady;
}

function setBusy(isBusy) {
  state.isBusy = isBusy;
  updateCaptureControls();
}

function fileSize(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${(bytes / 1024 ** index).toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

function setSelectedFile(file) {
  state.selectedFile = file;
  elements.fileName.textContent = file ? `${file.name} (${fileSize(file.size)})` : "No file selected";
  updateCaptureControls();
}

function buildFormData(file) {
  const form = new FormData();
  form.append("file", file, file.name);
  form.append("title", elements.meetingTitle.value.trim());
  form.append("whisper_model", elements.whisperModel.value.trim());
  form.append("language", elements.language.value.trim());
  form.append("ollama_model", elements.ollamaModel.value.trim());
  form.append("ollama_base_url", elements.ollamaBaseUrl.value.trim());
  form.append("chunk_minutes", elements.chunkMinutes.value);
  form.append("summary_chunk_chars", elements.summaryChunkChars.value);
  form.append("participants_notified", String(elements.participantsNotified.checked));
  form.append("delete_source_audio", String(elements.deleteSourceAudio.checked));
  return form;
}

function buildSettingsPayload() {
  return {
    title: elements.meetingTitle.value.trim(),
    whisper_model: elements.whisperModel.value.trim(),
    language: elements.language.value.trim(),
    ollama_model: elements.ollamaModel.value.trim(),
    ollama_base_url: elements.ollamaBaseUrl.value.trim(),
    chunk_minutes: elements.chunkMinutes.value,
    summary_chunk_chars: elements.summaryChunkChars.value,
    native_audio_device: elements.nativeAudioDevice.value.trim() || ":0",
    participants_notified: elements.participantsNotified.checked,
    delete_source_audio: elements.deleteSourceAudio.checked,
  };
}

function nativeApiAvailable() {
  return (
    Boolean(window.localMeetingRecorder?.start && window.localMeetingRecorder?.stop) ||
    state.nativeBridgeExpected ||
    Boolean(window.pywebview?.api?.start_recording && window.pywebview?.api?.stop_recording)
  );
}

async function callNativeRecorder(action, settings) {
  if (window.localMeetingRecorder?.[action]) {
    return window.localMeetingRecorder[action](settings);
  }

  const pywebviewApi = window.pywebview?.api;
  if (pywebviewApi?.[`${action}_recording`]) {
    return pywebviewApi[`${action}_recording`](settings);
  }

  const response = await fetch(`/native/${action}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(settings),
  });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.error || `Native recording ${action} failed.`);
  }
  return data;
}

async function uploadFile(file) {
  if (!disclosureConfirmed()) {
    setStatus("Confirm participant notice before recording or uploading.", 0);
    updateCaptureControls();
    return;
  }

  setBusy(true);
  elements.resultPanel.hidden = true;
  elements.jobId.textContent = "Uploading";
  setStatus("Uploading audio", 4);

  try {
    const response = await fetch("/upload", {
      method: "POST",
      body: buildFormData(file),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "Upload failed");
    state.activeJobId = data.job_id;
    elements.jobId.textContent = data.job_id.slice(0, 8);
    pollStatus(data.job_id);
  } catch (error) {
    setBusy(false);
    elements.jobId.textContent = "Failed";
    setStatus(error.message, 100);
  }
}

async function pollStatus(jobId) {
  if (state.activeJobId !== jobId) return;

  try {
    const response = await fetch(`/status/${jobId}`);
    const job = await response.json();
    if (!response.ok) throw new Error(job.error || "Status check failed");
    state.latestJob = job;
    elements.jobId.textContent = job.job_id.slice(0, 8);
    setStatus(job.error || job.phase || job.status, job.progress ?? 0);

    if (job.status === "completed") {
      showResult(job);
      setBusy(false);
      loadNotes();
      return;
    }

    if (job.status === "failed") {
      setBusy(false);
      return;
    }

    window.setTimeout(() => pollStatus(jobId), 2400);
  } catch (error) {
    setBusy(false);
    setStatus(error.message, 100);
  }
}

function showResult(job) {
  elements.resultPanel.hidden = false;
  if (job.markdown_download) {
    elements.markdownDownload.hidden = false;
    elements.markdownDownload.href = job.markdown_download;
  }
  if (job.json_download) {
    elements.jsonDownload.hidden = false;
    elements.jsonDownload.href = job.json_download;
  }
  renderCurrentTab();
}

function renderCurrentTab() {
  const job = state.latestJob || {};
  const content = state.currentTab === "transcript" ? job.transcript : job.minutes;
  elements.resultContent.textContent = content || "";
  elements.tabs.forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.tab === state.currentTab);
  });
}

async function copyResult() {
  const text = elements.resultContent.textContent;
  if (!text) return;
  elements.copyButton.textContent = "Copying";
  const copied = await copyText(text);
  elements.copyButton.textContent = copied ? "Copied" : "Copy unavailable";
  window.setTimeout(() => {
    elements.copyButton.textContent = "Copy";
  }, 1400);
}

function fallbackCopy(text, sourceElement = null) {
  const temp = document.createElement("textarea");
  temp.value = text;
  temp.setAttribute("readonly", "");
  temp.style.position = "fixed";
  temp.style.left = "-9999px";
  temp.style.top = "0";
  document.body.appendChild(temp);
  temp.select();

  let copied = false;
  try {
    copied = document.execCommand("copy");
  } catch {
    copied = false;
  }
  temp.remove();

  if (!copied && sourceElement?.select) {
    sourceElement.focus();
    sourceElement.select();
  }
  return copied;
}

async function copyText(text, sourceElement = null) {
  try {
    if (!navigator.clipboard?.writeText) throw new Error("Clipboard API unavailable");
    await Promise.race([
      navigator.clipboard.writeText(text),
      new Promise((_, reject) => {
        window.setTimeout(() => reject(new Error("Clipboard write timed out")), 600);
      }),
    ]);
    return true;
  } catch {
    return fallbackCopy(text, sourceElement);
  }
}

async function copyDisclosure() {
  elements.copyDisclosure.textContent = "Copying";
  const copied = await copyText(elements.disclosureText.value, elements.disclosureText);
  elements.copyDisclosure.textContent = copied ? "Copied" : "Text selected";
  window.setTimeout(() => {
    elements.copyDisclosure.textContent = "Copy disclosure";
  }, 1400);
}

async function deleteNote(note, button) {
  if (state.pendingDelete !== note.name) {
    state.pendingDelete = note.name;
    button.textContent = "Confirm delete";
    window.setTimeout(() => {
      if (state.pendingDelete === note.name) {
        state.pendingDelete = null;
        button.textContent = "Delete";
      }
    }, 4500);
    return;
  }

  try {
    button.disabled = true;
    button.textContent = "Deleting";
    const response = await fetch(note.delete_url || `/history/${encodeURIComponent(note.name)}/delete`, {
      method: "POST",
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "Delete failed");
    state.pendingDelete = null;
    await loadNotes();
    setStatus(`Deleted ${note.display_name || note.name}`, null);
  } catch (error) {
    button.disabled = false;
    button.textContent = "Delete";
    state.pendingDelete = null;
    setStatus(error.message || "Could not delete transcript.", null);
  }
}

async function loadHealth() {
  elements.healthChips.innerHTML = "";
  try {
    const response = await fetch("/health");
    const data = await response.json();
    const installedModels = data.ollama.models || [];
    const modelReady = data.ollama.ok && installedModels.includes(data.defaults.ollama_model);
    const chips = [
      ["ffmpeg", data.checks.ffmpeg],
      ["Whisper", data.checks.whisper_package],
      ["Pydub", data.checks.pydub_package],
      ["Ollama", data.ollama.ok],
      [data.defaults.ollama_model, modelReady],
    ];
    chips.forEach(([label, ok]) => {
      const chip = document.createElement("span");
      chip.className = `chip ${ok ? "ok" : "warn"}`;
      chip.textContent = `${label}: ${ok ? "ready" : "missing"}`;
      elements.healthChips.appendChild(chip);
    });
  } catch {
    const chip = document.createElement("span");
    chip.className = "chip warn";
    chip.textContent = "checks unavailable";
    elements.healthChips.appendChild(chip);
  }
}

async function loadNotes() {
  elements.notesList.innerHTML = "";
  try {
    const response = await fetch("/notes");
    const data = await response.json();
    if (!data.notes.length) {
      const empty = document.createElement("li");
      empty.textContent = "No saved notes yet.";
      elements.notesList.appendChild(empty);
      return;
    }
    data.notes.forEach((note) => {
      const item = document.createElement("li");
      const info = document.createElement("div");
      const actions = document.createElement("div");
      const name = document.createElement("strong");
      const meta = document.createElement("span");
      const download = document.createElement("a");
      const deleteButton = document.createElement("button");

      info.className = "note-info";
      actions.className = "note-actions";
      name.textContent = note.display_name || note.name;
      meta.textContent = `${note.kind || "note"} - ${fileSize(note.size)} - ${note.modified || "saved"}`;
      if (note.description && note.description !== note.name && note.description !== note.display_name) {
        meta.textContent = `${meta.textContent} - ${note.description}`;
      }

      download.className = "download-link secondary note-action";
      download.href = note.markdown_download || `/notes/${encodeURIComponent(note.name)}/download`;
      download.textContent = "Markdown";

      deleteButton.className = "secondary danger note-action";
      deleteButton.type = "button";
      deleteButton.textContent = "Delete";
      deleteButton.addEventListener("click", () => deleteNote(note, deleteButton));

      info.append(name, meta);
      actions.append(download, deleteButton);
      item.append(info, actions);
      elements.notesList.appendChild(item);
    });
  } catch {
    const item = document.createElement("li");
    item.textContent = "Recent notes unavailable.";
    elements.notesList.appendChild(item);
  }
}

function recorderMimeType() {
  if (!window.MediaRecorder) return "";
  const choices = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"];
  return choices.find((type) => MediaRecorder.isTypeSupported(type)) || "";
}

function updateRecordTimer() {
  const elapsed = Math.floor((Date.now() - state.recordStartedAt) / 1000);
  const minutes = String(Math.floor(elapsed / 60)).padStart(2, "0");
  const seconds = String(elapsed % 60).padStart(2, "0");
  elements.recordTimer.textContent = `${minutes}:${seconds}`;
}

function beginTimer() {
  state.recordStartedAt = Date.now();
  state.timerId = window.setInterval(updateRecordTimer, 500);
  updateRecordTimer();
}

function stopTimer() {
  if (state.timerId) {
    window.clearInterval(state.timerId);
    state.timerId = null;
  }
}

async function startNativeRecording() {
  state.nativeStarting = true;
  elements.recordingState.textContent = "Starting recorder";
  updateCaptureControls();

  try {
    const result = await callNativeRecorder("start", buildSettingsPayload());
    if (!result.ok) throw new Error(result.error || "Native recording could not start.");

    state.nativeStarting = false;
    state.nativeRecording = true;
    beginTimer();
    elements.recordingState.textContent = "Recording mic + app audio";
    elements.stopButton.disabled = false;
    updateCaptureControls();
    setStatus("Recording microphone and application audio", 0);
  } catch (error) {
    state.nativeStarting = false;
    state.nativeRecording = false;
    stopTimer();
    elements.stopButton.disabled = true;
    updateCaptureControls();
    setStatus(error.message || "Native recording could not start.", 0);
  }
}

async function stopNativeRecording() {
  if (!state.nativeRecording) return;

  state.nativeRecording = false;
  elements.stopButton.disabled = true;
  elements.recordingState.textContent = "Finishing recording";
  stopTimer();
  setBusy(true);
  setStatus("Saving native recording", 4);

  try {
    const result = await callNativeRecorder("stop", buildSettingsPayload());
    if (!result.ok) throw new Error(result.error || "Native recording upload failed.");
    state.activeJobId = result.job_id;
    elements.jobId.textContent = result.job_id.slice(0, 8);
    elements.recordingState.textContent = "Recording saved";
    pollStatus(result.job_id);
  } catch (error) {
    setBusy(false);
    elements.jobId.textContent = "Failed";
    setStatus(error.message || "Native recording could not be saved.", 100);
  }
}

async function startRecording() {
  if (!disclosureConfirmed()) {
    setStatus("Confirm participant notice before recording or uploading.", 0);
    updateCaptureControls();
    return;
  }

  if (nativeApiAvailable()) {
    await startNativeRecording();
    return;
  }

  if (state.nativeBridgeExpected) {
    setStatus("Native recording is still starting. Try again in a moment.", 0);
    updateCaptureControls();
    return;
  }

  if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
    setStatus("This browser does not support local audio recording.", 0);
    return;
  }

  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
      },
      video: false,
    });
    const mimeType = recorderMimeType();
    state.recordChunks = [];
    state.recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    beginTimer();

    state.recorder.ondataavailable = (event) => {
      if (event.data.size > 0) state.recordChunks.push(event.data);
    };

    state.recorder.onstop = () => {
      stream.getTracks().forEach((track) => track.stop());
      stopTimer();
      elements.stopButton.disabled = true;
      elements.recordingState.textContent = "Recording saved";

      const type = state.recorder.mimeType || mimeType || "audio/webm";
      const extension = type.includes("mp4") ? "mp4" : "webm";
      const blob = new Blob(state.recordChunks, { type });
      const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
      const file = new File([blob], `browser-recording-${timestamp}.${extension}`, { type });
      state.recorder = null;
      setSelectedFile(file);
      uploadFile(file);
    };

    state.recorder.start(1000);
    elements.recordingState.textContent = "Recording";
    elements.stopButton.disabled = false;
    updateCaptureControls();
    setStatus("Recording from browser microphone", 0);
  } catch (error) {
    setStatus(error.message || "Microphone permission was not granted.", 0);
    updateCaptureControls();
  }
}

function stopRecording() {
  if (state.nativeRecording) {
    stopNativeRecording();
    return;
  }

  if (state.recorder && state.recorder.state !== "inactive") {
    elements.recordingState.textContent = "Finishing recording";
    state.recorder.stop();
  }
}

elements.chooseButton.addEventListener("click", () => elements.fileInput.click());
elements.fileInput.addEventListener("change", () => setSelectedFile(elements.fileInput.files[0] || null));
elements.uploadButton.addEventListener("click", () => {
  if (state.selectedFile) uploadFile(state.selectedFile);
});
elements.recordButton.addEventListener("click", startRecording);
elements.stopButton.addEventListener("click", stopRecording);
elements.copyButton.addEventListener("click", copyResult);
elements.copyDisclosure.addEventListener("click", copyDisclosure);
elements.participantsNotified.addEventListener("change", updateCaptureControls);
elements.refreshHealth.addEventListener("click", loadHealth);
elements.refreshNotes.addEventListener("click", loadNotes);

elements.tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    state.currentTab = tab.dataset.tab;
    renderCurrentTab();
  });
});

["dragenter", "dragover"].forEach((eventName) => {
  elements.dropZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    elements.dropZone.classList.add("dragging");
  });
});

["dragleave", "drop"].forEach((eventName) => {
  elements.dropZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    elements.dropZone.classList.remove("dragging");
  });
});

elements.dropZone.addEventListener("drop", (event) => {
  const file = event.dataTransfer.files[0];
  if (file) setSelectedFile(file);
});

elements.dropZone.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    elements.fileInput.click();
  }
});

loadHealth();
loadNotes();
if (state.nativeBridgeExpected) {
  state.nativeApiReady = nativeApiAvailable();
  elements.recordingState.textContent = "Mic + app audio ready";
  setStatus("Native app recording is ready.", 0);
}
updateCaptureControls();

window.addEventListener("localMeetingRecorderReady", () => {
  state.nativeApiReady = nativeApiAvailable();
  if (state.nativeApiReady) {
    elements.recordingState.textContent = "Mic + app audio ready";
    setStatus("Native app recording is ready.", 0);
  }
  updateCaptureControls();
});

window.addEventListener("pywebviewready", () => {
  state.nativeApiReady = nativeApiAvailable();
  if (state.nativeApiReady) {
    elements.recordingState.textContent = "Mic + app audio ready";
    setStatus("Native app recording is ready.", 0);
  }
  updateCaptureControls();
});
