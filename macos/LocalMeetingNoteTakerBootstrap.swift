import AppKit
import AVFoundation
import CoreAudio
import Foundation
import WebKit

private let appName = "Local Meeting Note Taker"
private let appVersion = "0.1.17"
private let appPathPrefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

private enum RecorderError: LocalizedError {
    case busy
    case microphoneDenied
    case noAudio
    case noActiveRecording
    case systemAudioRequired(String)
    case uploadFailed(String)
    case unsupportedSystemAudio

    var errorDescription: String? {
        switch self {
        case .busy:
            return "A recording is already running."
        case .microphoneDenied:
            return "Microphone access was not granted for Local Meeting Note Taker."
        case .noAudio:
            return "No usable audio was captured."
        case .noActiveRecording:
            return "No native recording is running."
        case .systemAudioRequired(let detail):
            return "System Audio Recording access is required for application audio. Enable it for Local Meeting Note Taker in System Settings if macOS asks, then start recording again. \(detail)"
        case .uploadFailed(let message):
            return message
        case .unsupportedSystemAudio:
            return "Application audio capture requires macOS 14.2 or newer."
        }
    }
}

private final class SystemAudioRecorder {
    private let outputURL: URL
    private let ioQueue = DispatchQueue(label: "local.meeting.note.taker.system-audio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var format: AVAudioFormat?
    private var capturedAudio = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedSystemAudio
        }

        capturedAudio = false
        try? FileManager.default.removeItem(at: outputURL)

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "\(appName) Application Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try checkAudioStatus(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            operation: "Create system audio tap"
        )
        tapID = newTapID

        do {
            let tapUID = try getTapUID(newTapID)
            var streamFormat = try getTapFormat(newTapID)
            guard let avFormat = AVAudioFormat(streamDescription: &streamFormat) else {
                throw RecorderError.noAudio
            }
            format = avFormat
            audioFile = try AVAudioFile(forWriting: outputURL, settings: avFormat.settings)

            let aggregateUID = "local.meeting.note.taker.\(UUID().uuidString)"
            let tapDictionary: [String: Any] = [
                String(kAudioSubTapUIDKey): tapUID,
                String(kAudioSubTapDriftCompensationKey): true,
            ]
            let aggregateDescription: [String: Any] = [
                String(kAudioAggregateDeviceNameKey): "\(appName) Audio Capture",
                String(kAudioAggregateDeviceUIDKey): aggregateUID,
                String(kAudioAggregateDeviceIsPrivateKey): true,
                String(kAudioAggregateDeviceTapListKey): [tapDictionary],
            ]

            var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try checkAudioStatus(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID),
                operation: "Create system audio capture device"
            )
            aggregateDeviceID = newAggregateDeviceID

            var newIOProcID: AudioDeviceIOProcID?
            try checkAudioStatus(
                AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateDeviceID, ioQueue) { [weak self] _, inputData, _, _, _ in
                    self?.writeInputData(inputData)
                },
                operation: "Create system audio input callback"
            )
            guard let newIOProcID else {
                throw RecorderError.noAudio
            }
            ioProcID = newIOProcID

            try checkAudioStatus(
                AudioDeviceStart(newAggregateDeviceID, newIOProcID),
                operation: "Start system audio capture"
            )
        } catch {
            cleanup()
            throw error
        }
    }

    func stop() -> URL? {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
        }
        cleanup()

        guard capturedAudio, NativeMeetingRecorder.usableAudioFile(outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    private func writeInputData(_ inputData: UnsafePointer<AudioBufferList>?) {
        guard let inputData, let format, let audioFile else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let byteSize = buffers.reduce(0) { max($0, Int($1.mDataByteSize)) }
        guard byteSize > 0 else {
            return
        }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            return
        }

        let frameLength = AVAudioFrameCount(byteSize / bytesPerFrame)
        guard frameLength > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData)
        else {
            return
        }
        buffer.frameLength = min(frameLength, buffer.frameCapacity)

        do {
            try audioFile.write(from: buffer)
            capturedAudio = true
        } catch {
            return
        }
    }

    private func getTapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var tapUID: Unmanaged<CFString>?
        try checkAudioStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &tapUID),
            operation: "Read system audio tap identifier"
        )
        guard let tapUID = tapUID?.takeRetainedValue() else {
            throw RecorderError.noAudio
        }
        return tapUID as String
    }

    private func getTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkAudioStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &streamDescription),
            operation: "Read system audio format"
        )
        return streamDescription
    }

    private func cleanup() {
        audioFile = nil
        format = nil
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if #available(macOS 14.2, *), tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func checkAudioStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RecorderError.systemAudioRequired("\(operation) failed with OSStatus \(formatOSStatus(status)).")
        }
    }

    private func formatOSStatus(_ status: OSStatus) -> String {
        let unsigned = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((unsigned >> 24) & 0xff),
            UInt8((unsigned >> 16) & 0xff),
            UInt8((unsigned >> 8) & 0xff),
            UInt8(unsigned & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "'\(fourCC)' (\(status))"
        }
        return "\(status)"
    }
}

private final class NativeMeetingRecorder {
    private struct RecordingSession {
        let directory: URL
        let microphoneURL: URL
        let systemURL: URL
        let mixedURL: URL
    }

    private var microphoneRecorder: AVAudioRecorder?
    private var systemRecorder: SystemAudioRecorder?
    private var activeSession: RecordingSession?

    func start(dataRoot: URL, settings: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard activeSession == nil else {
            completion(errorPayload(RecorderError.busy))
            return
        }

        requestMicrophoneAccess { [weak self] granted in
            guard let self else {
                completion(errorPayload(RecorderError.noAudio))
                return
            }
            guard granted else {
                completion(errorPayload(RecorderError.microphoneDenied))
                return
            }

            do {
                let session = try self.makeSession(dataRoot: dataRoot)
                let microphone = try self.startMicrophoneRecording(to: session.microphoneURL)
                let system = SystemAudioRecorder(outputURL: session.systemURL)

                self.activeSession = session
                self.microphoneRecorder = microphone
                self.systemRecorder = system

                Task {
                    do {
                        try system.start()
                        DispatchQueue.main.async {
                            completion([
                                "ok": true,
                                "mode": "microphone_and_application_audio",
                                "path": session.mixedURL.path,
                            ])
                        }
                    } catch {
                        microphone.stop()
                        self.microphoneRecorder = nil
                        self.systemRecorder = nil
                        self.activeSession = nil
                        self.deleteFiles([session.microphoneURL, session.systemURL, session.mixedURL])
                        let message = "Application audio capture could not start. \(error.localizedDescription)"
                        DispatchQueue.main.async {
                            completion(errorPayload(RecorderError.uploadFailed(message)))
                        }
                    }
                }
            } catch {
                completion(errorPayload(error))
            }
        }
    }

    func stopAndUpload(settings: [String: Any], serverPort: Int, completion: @escaping ([String: Any]) -> Void) {
        guard let session = activeSession else {
            completion(errorPayload(RecorderError.noActiveRecording))
            return
        }

        let microphone = microphoneRecorder
        let system = systemRecorder
        activeSession = nil
        microphoneRecorder = nil
        systemRecorder = nil
        microphone?.stop()

        Task {
            _ = system?.stop()
            do {
                let capturedFiles = [session.microphoneURL, session.systemURL].filter(Self.usableAudioFile)
                guard !capturedFiles.isEmpty else {
                    throw RecorderError.noAudio
                }

                let mixedURL = try await mixAudioFiles(capturedFiles, outputURL: session.mixedURL)
                var response = try await upload(fileURL: mixedURL, settings: settings, serverPort: serverPort)
                response["ok"] = true

                if boolValue(settings["delete_source_audio"], defaultValue: true) {
                    deleteFiles([session.microphoneURL, session.systemURL, session.mixedURL])
                }

                DispatchQueue.main.async {
                    completion(response)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(errorPayload(error))
                }
            }
        }
    }

    func cancel() {
        microphoneRecorder?.stop()
        let system = systemRecorder
        microphoneRecorder = nil
        systemRecorder = nil
        activeSession = nil
        _ = system?.stop()
    }

    static func usableAudioFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 1024
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    private func makeSession(dataRoot: URL) throws -> RecordingSession {
        let directory = dataRoot.appendingPathComponent("native-recordings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let suffix = UUID().uuidString.prefix(8)
        return RecordingSession(
            directory: directory,
            microphoneURL: directory.appendingPathComponent("microphone-\(timestamp)-\(suffix).m4a"),
            systemURL: directory.appendingPathComponent("application-audio-\(timestamp)-\(suffix).caf"),
            mixedURL: directory.appendingPathComponent("combined-recording-\(timestamp)-\(suffix).m4a")
        )
    }

    private func startMicrophoneRecording(to url: URL) throws -> AVAudioRecorder {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecorderError.noAudio
        }
        return recorder
    }

    private func mixAudioFiles(_ files: [URL], outputURL: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        var addedTracks = 0

        for file in files {
            let asset = AVURLAsset(url: file)
            guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
                continue
            }
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            let duration = asset.duration
            if duration.seconds > 0 {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
                addedTracks += 1
            }
        }

        guard addedTracks > 0 else {
            throw RecorderError.noAudio
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.noAudio
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exporter.error ?? RecorderError.noAudio)
                default:
                    continuation.resume(throwing: RecorderError.noAudio)
                }
            }
        }

        guard Self.usableAudioFile(outputURL) else {
            throw RecorderError.noAudio
        }
        return outputURL
    }

    private func upload(fileURL: URL, settings: [String: Any], serverPort: Int) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/upload") else {
            throw RecorderError.uploadFailed("The local transcription server URL was invalid.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }
        func appendField(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField("title", stringValue(settings["title"]))
        appendField("whisper_model", stringValue(settings["whisper_model"]))
        appendField("language", stringValue(settings["language"]))
        appendField("ollama_model", stringValue(settings["ollama_model"]))
        appendField("ollama_base_url", stringValue(settings["ollama_base_url"]))
        appendField("chunk_minutes", stringValue(settings["chunk_minutes"]))
        appendField("summary_chunk_chars", stringValue(settings["summary_chunk_chars"]))
        appendField("participants_notified", boolValue(settings["participants_notified"], defaultValue: false) ? "true" : "false")
        appendField("delete_source_audio", boolValue(settings["delete_source_audio"], defaultValue: true) ? "true" : "false")

        let fileName = fileURL.lastPathComponent
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw RecorderError.uploadFailed("The local transcription server did not respond.")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecorderError.uploadFailed("The local transcription server returned an unreadable response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecorderError.uploadFailed(payload["error"] as? String ?? "Upload failed with status \(http.statusCode).")
        }
        return payload
    }

    private func deleteFiles(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        if let value = value as? Bool {
            return value ? "true" : "false"
        }
        return ""
    }

    private func boolValue(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        return defaultValue
    }
}

private func errorPayload(_ error: Error) -> [String: Any] {
    return ["ok": false, "error": error.localizedDescription]
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var logView: NSTextView?
    private var progress: NSProgressIndicator?
    private var closeButton: NSButton?
    private var setupProcess: Process?
    private var appRoot: URL?
    private var dataRoot: URL?
    private var setupLogFile: URL?
    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var webView: WKWebView?
    private var outputBuffer = ""
    private var serverPort: Int?
    private let nativeRecorder = NativeMeetingRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let root = findAppRoot() else {
            showFatalError("Local Meeting Note Taker resources were not found inside this app bundle.")
            return
        }

        appRoot = root
        dataRoot = prepareDataRoot()
        setupLogFile = setupLogURL()
        continueStartup(with: root)
    }

    private func continueStartup(with root: URL) {
        if requirementsAreReady(in: root) {
            startAppWindow(from: root)
            return
        }

        buildSetupWindow()
        runSetup(from: root)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return setupProcess == nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        nativeRecorder.cancel()
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
        try? serverLogHandle?.close()
    }

    private func findAppRoot() -> URL? {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let resourceRoot = bundleURL.appendingPathComponent("Contents/Resources/local-meeting-note-taker")
        let sidecarRoot = bundleURL.deletingLastPathComponent().appendingPathComponent("local-meeting-note-taker")

        for candidate in [resourceRoot, sidecarRoot] {
            let launcher = candidate.appendingPathComponent("launch_app.sh")
            if fileManager.isExecutableFile(atPath: launcher.path) {
                return candidate
            }
        }

        return nil
    }

    private func prepareDataRoot() -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Local Meeting Note Taker")
        for child in ["logs", "uploads", "results", "notes", "native-recordings"] {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(child),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private func setupLogURL() -> URL {
        if let dataRoot {
            let appSupportLog = dataRoot.appendingPathComponent("logs/setup-window.log")
            if prepareLogFile(appSupportLog) {
                return appSupportLog
            }
        }
        let fallbackLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Local Meeting Note Taker/setup-window.log")
        _ = prepareLogFile(fallbackLog)
        return fallbackLog
    }

    private func prepareLogFile(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    private func requirementsAreReady(in root: URL) -> Bool {
        let checkScript = root.appendingPathComponent("check_ready.sh")
        guard FileManager.default.isExecutableFile(atPath: checkScript.path) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [checkScript.path]
        process.currentDirectoryURL = root
        process.environment = appEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func buildSetupWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.center()

        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Preparing Local Meeting Note Taker")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: "Installing required local components...")
        status.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        status.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: "This can take a while the first time. Progress is shown below.")
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 3
        progress.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let logView = NSTextView()
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = .textBackgroundColor
        scrollView.documentView = logView

        let logPath = setupLogFile?.path ?? "~/Library/Application Support/Local Meeting Note Taker/logs/setup-window.log"
        let logLabel = NSTextField(labelWithString: "Setup log: \(logPath)")
        logLabel.font = NSFont.systemFont(ofSize: 11)
        logLabel.textColor = .secondaryLabelColor
        logLabel.lineBreakMode = .byTruncatingMiddle
        logLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "Cancel", target: self, action: #selector(closeSetupWindow))
        button.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, status, detail, progress, scrollView, logLabel, button] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            detail.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            progress.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 16),
            progress.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 190),

            logLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 14),
            logLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            logLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -18),
            logLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),

            button.centerYAnchor.constraint(equalTo: logLabel.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])

        self.window = window
        self.statusLabel = status
        self.detailLabel = detail
        self.progress = progress
        self.logView = logView
        self.closeButton = button

        window.makeKeyAndOrderFront(nil)
    }

    private func runSetup(from root: URL) {
        let installer = root.appendingPathComponent("install_requirements.sh")
        guard FileManager.default.isExecutableFile(atPath: installer.path) else {
            setupFailed("Installer not found: \(installer.path)")
            return
        }

        appendOutput("Starting first-run setup\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer.path]
        process.currentDirectoryURL = root

        var environment = appEnvironment()
        environment["LMNT_ASSUME_YES"] = "1"
        environment["LMNT_MACHINE_PROGRESS"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            DispatchQueue.main.async {
                self?.appendOutput(text)
            }
        }

        process.terminationHandler = { [weak self] finishedProcess in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingText = String(data: remainingData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if !remainingText.isEmpty {
                    self?.appendOutput(remainingText)
                }
                if finishedProcess.terminationStatus == 0 {
                    self?.setupSucceeded()
                } else {
                    self?.setupFailed("Setup failed with exit code \(finishedProcess.terminationStatus).")
                }
            }
        }

        do {
            try process.run()
            setupProcess = process
        } catch {
            setupFailed("Could not start setup: \(error.localizedDescription)")
        }
    }

    private func setupSucceeded() {
        setupProcess = nil
        flushOutputBuffer()
        appendToSetupLog("Setup completed\n")
        progress?.doubleValue = 100
        statusLabel?.stringValue = "Starting Local Meeting Note Taker..."
        detailLabel?.stringValue = "The app is opening now."
        closeButton?.title = "Close"

        if let root = appRoot {
            startAppWindow(from: root)
        }
    }

    private func setupFailed(_ message: String) {
        setupProcess = nil
        flushOutputBuffer()
        appendToSetupLog("\(message)\n")
        statusLabel?.stringValue = "Setup could not finish."
        detailLabel?.stringValue = "\(message) Check the setup log for details."
        closeButton?.title = "Close"
        appendOutput("\n\(message)\n")
    }

    private func startAppWindow(from root: URL) {
        do {
            let port = try ensureServerRunning(from: root)
            buildAppWindow(port: port, root: root)
        } catch {
            showFatalError("Could not start the local app server: \(error.localizedDescription)")
        }
    }

    private func ensureServerRunning(from root: URL) throws -> Int {
        if let savedPort = readSavedPort(), serverMatchesApp(port: savedPort, root: root) {
            return savedPort
        }

        var lastExitCode: Int32 = 1
        for port in 5055...5155 {
            if serverResponds(port: port) {
                continue
            }

            try startServer(from: root, port: port)

            for _ in 0..<80 {
                if serverMatchesApp(port: port, root: root) {
                    return port
                }
                if let process = serverProcess, !process.isRunning {
                    lastExitCode = process.terminationStatus
                    cleanupServerHandles()
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            if let process = serverProcess, process.isRunning {
                process.terminate()
                cleanupServerHandles()
            }
        }

        throw NSError(
            domain: appName,
            code: Int(lastExitCode),
            userInfo: [NSLocalizedDescriptionKey: "The local server exited during startup on every available port. Check the app log in Library/Application Support/Local Meeting Note Taker/logs/webapp.log."]
        )
    }

    private func cleanupServerHandles() {
        serverProcess = nil
        try? serverLogHandle?.close()
        serverLogHandle = nil
    }

    private func startServer(from root: URL, port: Int) throws {
        let python = root.appendingPathComponent(".venv/bin/python")
        let app = root.appendingPathComponent("app.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(
                domain: appName,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled Python was not found at \(python.path)."]
            )
        }
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw NSError(
                domain: appName,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The local app server was not found at \(app.path)."]
            )
        }

        let runtimeRoot = dataRoot ?? prepareDataRoot()
        dataRoot = runtimeRoot
        let logFile = runtimeRoot.appendingPathComponent("logs/webapp.log")
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logFile)
        try logHandle.seekToEnd()
        if let header = "\n\n--- Launch \(Date()) ---\n".data(using: .utf8) {
            try? logHandle.write(contentsOf: header)
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [app.path]
        process.currentDirectoryURL = root
        process.environment = appEnvironment(
            extra: [
                "APP_HOST": "127.0.0.1",
                "APP_PORT": String(port),
                "LMNT_DATA_DIR": runtimeRoot.path,
                "PYTHONUNBUFFERED": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
            ]
        )
        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { [weak self] finishedProcess in
            self?.appendToSetupLog("Local server exited with code \(finishedProcess.terminationStatus)\n")
        }

        try process.run()
        serverProcess = process
        serverLogHandle = logHandle

        try? String(process.processIdentifier).write(
            to: runtimeRoot.appendingPathComponent("app.pid"),
            atomically: true,
            encoding: .utf8
        )
        try? String(port).write(
            to: runtimeRoot.appendingPathComponent("app.port"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func buildAppWindow(port: Int, root: URL) {
        let appWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        appWindow.title = appName
        appWindow.center()

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "nativeRecorder")
        userContentController.addUserScript(WKUserScript(
            source: nativeRecorderBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController = userContentController
        let webView = WKWebView(frame: appWindow.contentView?.bounds ?? .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        appWindow.contentView = webView

        let oldWindow = self.window
        self.window = appWindow
        self.webView = webView
        self.serverPort = port

        appWindow.makeKeyAndOrderFront(nil)
        oldWindow?.close()
        NSApp.activate(ignoringOtherApps: true)

        if let url = URL(string: "http://127.0.0.1:\(port)/?native=1") {
            appendToSetupLog("Loading app UI at \(url.absoluteString)\n")
            webView.load(URLRequest(url: url))
        }
    }

    private func nativeRecorderBridgeScript() -> String {
        return """
        (() => {
          if (window.localMeetingRecorder) return;
          const pending = new Map();
          let nextId = 1;
          const send = (action, settings) => new Promise((resolve, reject) => {
            const id = String(nextId++);
            pending.set(id, { resolve, reject });
            window.webkit.messageHandlers.nativeRecorder.postMessage({
              id,
              action,
              settings: settings || {}
            });
          });
          window.localMeetingRecorder = {
            start(settings) {
              return send("start", settings);
            },
            stop(settings) {
              return send("stop", settings);
            },
            _complete(message) {
              const id = String(message && message.id);
              const callbacks = pending.get(id);
              if (!callbacks) return;
              pending.delete(id);
              const payload = message.payload || {};
              if (payload.ok === false) {
                callbacks.reject(new Error(payload.error || "Native recording failed."));
              } else {
                callbacks.resolve(payload);
              }
            }
          };
          window.dispatchEvent(new Event("localMeetingRecorderReady"));
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativeRecorder",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else {
            return
        }

        let messageId = String(describing: body["id"] ?? "")
        let settings = body["settings"] as? [String: Any] ?? [:]

        switch action {
        case "start":
            guard appRoot != nil else {
                completeNativeRecorderMessage(id: messageId, payload: errorPayload(RecorderError.noAudio))
                return
            }
            let runtimeRoot = dataRoot ?? prepareDataRoot()
            dataRoot = runtimeRoot
            nativeRecorder.start(dataRoot: runtimeRoot, settings: settings) { [weak self] payload in
                self?.completeNativeRecorderMessage(id: messageId, payload: payload)
            }
        case "stop":
            guard let port = serverPort else {
                completeNativeRecorderMessage(id: messageId, payload: errorPayload(RecorderError.uploadFailed("The local transcription server is not ready.")))
                return
            }
            nativeRecorder.stopAndUpload(settings: settings, serverPort: port) { [weak self] payload in
                self?.completeNativeRecorderMessage(id: messageId, payload: payload)
            }
        default:
            completeNativeRecorderMessage(id: messageId, payload: errorPayload(RecorderError.uploadFailed("Unknown recorder action: \(action).")))
        }
    }

    private func completeNativeRecorderMessage(id: String, payload: [String: Any]) {
        let response: [String: Any] = ["id": id, "payload": payload]
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.localMeetingRecorder && window.localMeetingRecorder._complete(\(json));")
        }
    }

    private func readSavedPort() -> Int? {
        let runtimeRoot = dataRoot ?? prepareDataRoot()
        let portFile = runtimeRoot.appendingPathComponent("app.port")
        guard
            let text = try? String(contentsOf: portFile, encoding: .utf8),
            let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return port
    }

    private func serverResponds(port: Int) -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/identity")!
        return fetchJSON(url: url) != nil
    }

    private func serverMatchesApp(port: Int, root: URL) -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/identity")!
        guard let json = fetchJSON(url: url) else {
            return false
        }
        return json["app"] as? String == "local-meeting-note-taker"
            && json["app_version"] as? String == appVersion
            && json["app_root"] as? String == root.path
    }

    private func fetchJSON(url: URL) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.8
        configuration.timeoutIntervalForResource = 0.8
        let session = URLSession(configuration: configuration)
        var result: [String: Any]?

        let task = session.dataTask(with: url) { data, response, _ in
            defer {
                semaphore.signal()
            }
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return
            }
            result = json
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.0)
        session.invalidateAndCancel()
        return result
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showWebError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showWebError(error.localizedDescription)
    }

    private func showWebError(_ message: String) {
        let escapedMessage = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html>
          <body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#f5f6f8;color:#17212b;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
            <main style="max-width:560px;border:1px solid #d9dee5;border-radius:8px;background:#fff;padding:28px;">
              <h1 style="margin-top:0;font-size:22px;">Local app did not load</h1>
              <p style="color:#65717f;line-height:1.5;">\(escapedMessage)</p>
              <p style="color:#65717f;line-height:1.5;">Check Library/Application Support/Local Meeting Note Taker/logs/webapp.log for details.</p>
            </main>
          </body>
        </html>
        """
        webView?.loadHTMLString(html, baseURL: nil)
    }

    private func appendOutput(_ text: String) {
        appendToSetupLog(text)
        outputBuffer += text.replacingOccurrences(of: "\r", with: "\n")

        var visibleText = ""
        while let newline = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<newline.lowerBound])
            outputBuffer.removeSubrange(outputBuffer.startIndex..<newline.upperBound)
            if handleControlLine(line) {
                continue
            }
            updateStatus(from: line)
            visibleText += line + "\n"
        }

        appendVisibleOutput(visibleText)
    }

    private func flushOutputBuffer() {
        guard !outputBuffer.isEmpty else {
            return
        }
        let line = outputBuffer
        outputBuffer = ""
        if !handleControlLine(line) {
            updateStatus(from: line)
            appendVisibleOutput(line + "\n")
        }
    }

    private func appendVisibleOutput(_ text: String) {
        guard !text.isEmpty, let logView else {
            return
        }
        let attributed = NSAttributedString(string: text)
        logView.textStorage?.append(attributed)
        logView.scrollRangeToVisible(NSRange(location: logView.string.count, length: 0))
    }

    private func handleControlLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("LMNT_PROGRESS|") {
            let parts = trimmed.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count == 4,
               let current = Double(parts[1]),
               let total = Double(parts[2]),
               total > 0 {
                progress?.doubleValue = min(98, max(3, (current / total) * 100))
                statusLabel?.stringValue = String(parts[3])
                detailLabel?.stringValue = "Step \(Int(current)) of \(Int(total))"
            }
            return true
        }

        if trimmed.hasPrefix("LMNT_DETAIL|") {
            detailLabel?.stringValue = String(trimmed.dropFirst("LMNT_DETAIL|".count))
            return true
        }

        return false
    }

    private func updateStatus(from line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("==> ") {
            statusLabel?.stringValue = String(trimmed.dropFirst(4))
        } else if trimmed.contains("Collecting ") || trimmed.contains("Downloading ") {
            statusLabel?.stringValue = "Installing Python packages..."
        } else if trimmed.contains("Pulling ") {
            statusLabel?.stringValue = "Downloading local AI model..."
        }
    }

    private func appEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = existingPath.isEmpty ? appPathPrefix : "\(appPathPrefix):\(existingPath)"
        if let dataRoot {
            environment["LMNT_DATA_DIR"] = dataRoot.path
        }
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    private func appendToSetupLog(_ text: String) {
        guard let setupLogFile else {
            return
        }

        let directory = setupLogFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: setupLogFile.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: setupLogFile) else {
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func showFatalError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc private func closeSetupWindow() {
        if let process = setupProcess, process.isRunning {
            process.terminate()
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
