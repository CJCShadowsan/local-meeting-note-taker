import AppKit
import AVFoundation
import Foundation
import WebKit

private let appName = "Local Meeting Note Taker"
private let appVersion = "0.1.12"
private let appPathPrefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var logView: NSTextView?
    private var progress: NSProgressIndicator?
    private var closeButton: NSButton?
    private var setupProcess: Process?
    private var appRoot: URL?
    private var setupLogFile: URL?
    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var webView: WKWebView?
    private var outputBuffer = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let root = findAppRoot() else {
            showFatalError("Local Meeting Note Taker resources were not found inside this app bundle.")
            return
        }

        appRoot = root
        setupLogFile = setupLogURL(for: root)

        requestMicrophoneAccess {
            self.continueStartup(with: root)
        }
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

    private func setupLogURL(for root: URL) -> URL {
        let bundledLog = root.appendingPathComponent("data/logs/setup-window.log")
        if prepareLogFile(bundledLog) {
            return bundledLog
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

    private func requestMicrophoneAccess(completion: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.appendToSetupLog("Microphone permission \(granted ? "granted" : "not granted")\n")
                    completion()
                }
            }
        default:
            appendToSetupLog("Microphone permission status: \(status.rawValue)\n")
            completion()
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

        let logPath = setupLogFile?.path ?? "data/logs/setup-window.log"
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
        if let savedPort = readSavedPort(from: root), serverMatchesApp(port: savedPort, root: root) {
            return savedPort
        }

        let port = chooseServerPort()
        try startServer(from: root, port: port)

        for _ in 0..<80 {
            if serverMatchesApp(port: port, root: root) {
                return port
            }
            if let process = serverProcess, !process.isRunning {
                throw NSError(
                    domain: appName,
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "The local server exited during startup. Check data/logs/webapp.log."]
                )
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        throw NSError(
            domain: appName,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The local server did not become ready. Check data/logs/webapp.log."]
        )
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

        let logFile = root.appendingPathComponent("data/logs/webapp.log")
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
                "PYTHONUNBUFFERED": "1",
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
            to: root.appendingPathComponent("data/app.pid"),
            atomically: true,
            encoding: .utf8
        )
        try? String(port).write(
            to: root.appendingPathComponent("data/app.port"),
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
        let webView = WKWebView(frame: appWindow.contentView?.bounds ?? .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        appWindow.contentView = webView

        let oldWindow = self.window
        self.window = appWindow
        self.webView = webView

        appWindow.makeKeyAndOrderFront(nil)
        oldWindow?.close()
        NSApp.activate(ignoringOtherApps: true)

        if let url = URL(string: "http://127.0.0.1:\(port)/?native=1") {
            appendToSetupLog("Loading app UI at \(url.absoluteString)\n")
            webView.load(URLRequest(url: url))
        }
    }

    private func readSavedPort(from root: URL) -> Int? {
        let portFile = root.appendingPathComponent("data/app.port")
        guard
            let text = try? String(contentsOf: portFile, encoding: .utf8),
            let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return port
    }

    private func chooseServerPort() -> Int {
        for port in 5055...5155 {
            if !serverResponds(port: port) {
                return port
            }
        }
        return 5055
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
              <p style="color:#65717f;line-height:1.5;">Check data/logs/webapp.log inside the installed app for details.</p>
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
