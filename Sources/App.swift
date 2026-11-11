import AppKit
import UniformTypeIdentifiers
import WebKit

private final class WindowDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class SetupWindow: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 548, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
    private let webView = WKWebView()
    private var pageURL: URL?
    private var pageReady = false
    private var busy = false
    private var restoring = false
    private var gameReady = false
    private var launchingGame = false
    private let growtopiaBundleID = "com.rtsoft.Growtopia"
    private var completed = 0
    private var next: StepState = .pending
    private var review: Review?
    private var title = "Ready to install"
    private var detail = "Close Growtopia first. macOS may ask for administrator approval."
    private var mode = "Setup not started"
    private var progressTimer: Timer?

    private enum StepState: String {
        case pending, active, approval, error
    }

    private enum Review {
        case install, restore
    }

    private var hasRecovery: Bool {
        FileManager.default.fileExists(atPath: "/var/db/com.royalgtps.setup/recovery.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Royal GTPS Setup", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu

        if BuildPin.sha256.isEmpty {
            title = "Install unavailable"
            detail = "This build has no certificate fingerprint."
        } else if hasRecovery {
            mode = "Saved setup found"
            title = "Saved setup found"
            detail = "Verify Royal GTPS or restore your previous settings."
        }

        window.title = "Royal GTPS Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        configureContent()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "setup")
        if let url = Bundle.main.url(forResource: "SetupWindow", withExtension: "html") {
            pageURL = url
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            NSAlert(error: SetupError("This copy is missing its setup window. Extract the ZIP again.")).runModal()
            app.terminate(nil)
            return
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        let content = NSView()
        window.contentView = content
        let dragArea = WindowDragArea()
        webView.translatesAutoresizingMaskIntoConstraints = false
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        content.addSubview(dragArea, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragArea.topAnchor.constraint(equalTo: content.topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 72),
            dragArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !busy }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "setup")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == pageURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        render()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView, webView.url == pageURL else { return }
        if let body = message.body as? [String: Any], let height = body["height"] as? Double,
           height.isFinite, (300...750).contains(height) {
            let oldFrame = window.frame
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let height = min(CGFloat(height), visible?.height ?? CGFloat(height))
            if abs(oldFrame.height - height) > 1 {
                let bottom = max(visible?.minY ?? 0, oldFrame.maxY - height)
                window.setFrame(NSRect(x: oldFrame.minX, y: bottom, width: oldFrame.width, height: height), display: true)
            }
            return
        }
        guard !busy, !launchingGame, window.attachedSheet == nil, let action = message.body as? String else { return }
        switch action {
        case "install" where review == nil && !gameReady && !BuildPin.sha256.isEmpty:
            beginReview(.install)
        case "restore" where review == nil && hasRecovery:
            beginReview(.restore)
        case "confirm" where review != nil:
            let undo = review == .restore
            review = nil
            if readyToProceed() { perform(undo ? "undo" : "install") }
        case "cancel" where review != nil:
            cancelReview()
        case "launch" where review == nil && gameReady && hasRecovery:
            launchGrowtopia()
        default:
            break
        }
    }

    private func render() {
        window.standardWindowButton(.closeButton)?.isEnabled = !busy
        guard pageReady else { return }
        let primaryAction: String
        let primaryLabel: String
        if let review {
            primaryAction = "confirm"
            primaryLabel = review == .restore ? "Restore settings" : "Continue"
        } else if busy {
            primaryAction = ""
            primaryLabel = ""
        } else if gameReady && hasRecovery {
            primaryAction = "launch"
            primaryLabel = launchingGame ? "Opening Growtopia…" : "Launch Growtopia"
        } else {
            primaryAction = "install"
            primaryLabel = hasRecovery ? "Verify Royal GTPS" : "Install Royal GTPS"
        }
        let state: [String: Any] = [
            "mode": mode, "title": title, "detail": detail, "restoring": restoring,
            "completed": completed, "next": next.rawValue, "primaryAction": primaryAction,
            "primaryLabel": primaryLabel,
            "primaryDisabled": launchingGame || (primaryAction == "install" && BuildPin.sha256.isEmpty),
            "showRestore": review == nil && !busy, "restoreDisabled": !hasRecovery || launchingGame,
            "showCancel": review != nil
        ]
        webView.callAsyncJavaScript("window.renderSetup(state)", arguments: ["state": state],
                                    in: nil, in: .page, completionHandler: nil)
    }

    private func showStatus(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
        render()
    }

    private func renderSteps(completed: Int, next: StepState = .pending) {
        self.completed = completed
        self.next = next
    }

    private func readyToProceed() -> Bool {
        if runningGrowtopia != nil {
            renderSteps(completed: 0, next: .error)
            showStatus("Growtopia is still open", "Quit the game, then try again.")
            return false
        }
        return true
    }

    private func beginReview(_ choice: Review) {
        restoring = choice == .restore
        guard readyToProceed() else { return }
        review = choice
        renderSteps(completed: 1, next: .active)
        if restoring {
            showStatus("Return to Original Growtopia?",
                       "Setup will restore your saved addresses and remove certificate trust it added.")
        } else {
            showStatus("Review certificate trust",
                       "Setup will add the Royal GTPS private CA to the System keychain and enable SSL trust. macOS may ask for administrator approval.")
        }
    }

    private func cancelReview() {
        review = nil
        restoring = false
        renderSteps(completed: gameReady ? 4 : 0)
        if gameReady {
            showStatus("Royal GTPS is ready", "All four checks passed. You can launch Growtopia.")
        } else if hasRecovery {
            showStatus("Saved setup found", "Verify Royal GTPS or restore your previous settings.")
        } else {
            showStatus("Ready to install", "Close Growtopia first. macOS may ask for administrator approval.")
        }
    }

    private var runningGrowtopia: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier == growtopiaBundleID ||
                app.localizedName?.caseInsensitiveCompare("Growtopia") == .orderedSame ||
                app.executableURL?.lastPathComponent.caseInsensitiveCompare("Growtopia") == .orderedSame ||
                app.bundleURL?.lastPathComponent.caseInsensitiveCompare("Growtopia.app") == .orderedSame
        }
    }

    private func isGrowtopia(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: url), bundle.bundleIdentifier == growtopiaBundleID,
              let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    private func launchGrowtopia() {
        if let runningGrowtopia {
            runningGrowtopia.activate()
            return
        }
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let folders = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                       home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")]
            + (files.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? [])
        let known = [UserDefaults.standard.url(forKey: "GrowtopiaApplication"),
                     NSWorkspace.shared.urlForApplication(withBundleIdentifier: growtopiaBundleID)]
            .compactMap { $0 }
        if let url = (known + folders.map { $0.appendingPathComponent("Growtopia.app") }).first(where: isGrowtopia) {
            openGrowtopia(url)
            return
        }

        showStatus("Choose Growtopia", "Select Growtopia.app to launch it. If you have the disk image, open it first.")
        let chooser = NSOpenPanel()
        chooser.title = "Find Growtopia"
        chooser.message = "Select Growtopia.app. If you downloaded a disk image, open it first."
        chooser.prompt = "Launch"
        chooser.allowedContentTypes = [.applicationBundle]
        chooser.directoryURL = URL(fileURLWithPath: "/Applications")
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            guard result == .OK, let url = chooser.url else {
                self.showStatus("Royal GTPS is ready", "All four checks passed. You can launch Growtopia.")
                return
            }
            guard self.isGrowtopia(url) else {
                self.showStatus("Growtopia wasn’t selected", "Click Launch Growtopia and choose Growtopia.app.")
                return
            }
            self.openGrowtopia(url)
        }
    }

    private func openGrowtopia(_ url: URL) {
        launchingGame = true
        showStatus("Opening Growtopia…", "Royal GTPS setup is complete.")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launchingGame = false
                if let error {
                    self.showStatus("Growtopia couldn’t open", error.localizedDescription)
                } else if app != nil {
                    UserDefaults.standard.set(url, forKey: "GrowtopiaApplication")
                    self.showStatus("Growtopia launched", "Royal GTPS setup is complete.")
                } else {
                    self.showStatus("Growtopia couldn’t open", "Click Launch Growtopia to try again.")
                }
            }
        }
    }

    private struct AuthenticationCancelled: LocalizedError {
        var errorDescription: String? { "Administrator authentication cancelled." }
    }

    private static func runHelper(_ command: String, operation: String? = nil) throws -> String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RoyalGTPSHelper").path
        let script = """
        on run argv
            try
                set commandText to quoted form of item 1 of argv
                repeat with argumentIndex from 2 to count of argv
                    set commandText to commandText & " " & quoted form of item argumentIndex of argv
                end repeat
                return do shell script commandText with administrator privileges
            on error errorMessage number errorNumber
                if errorNumber is -128 then return "SETUP_CANCELLED"
                return "SETUP_ERROR:" & errorMessage
            end try
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, helper, command, String(ProcessInfo.processInfo.processIdentifier)]
            + (operation.map { [$0] } ?? [])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw SetupError(output.isEmpty ? "Could not run setup." : output)
        }
        if output == "SETUP_CANCELLED" { throw AuthenticationCancelled() }
        if output.hasPrefix("SETUP_ERROR:") { throw SetupError(String(output.dropFirst("SETUP_ERROR:".count))) }
        return output
    }

    private func completeUndo(rollback operation: String? = nil) throws -> String {
        let progress = UUID().uuidString
        if operation == nil {
            showProgress("Approve macOS prompts to restore your previous settings.", completed: 1, next: .approval)
            watchVerification(progress)
        }
        let response = try Self.runHelper(operation == nil ? "undo" : "rollback", operation: operation ?? progress)
        let prefix = "REMOVE_TRUST:"
        guard response.hasPrefix(prefix) else { return response }
        guard let data = Data(base64Encoded: String(response.dropFirst(prefix.count))) else {
            throw SetupError("Could not read the certificate from the recovery record.")
        }
        if operation == nil {
            showProgress("Approve the removal of SSL trust when macOS asks.", completed: 1, next: .approval)
        }
        let system = try SystemCertificate(Certificate.parse(data))
        do {
            if let settings = try system.trust() {
                guard system.isSetupTrust(settings) else {
                    throw SetupError("The certificate trust changed during undo.")
                }
                try system.removeTrust()
            }
        } catch {
            let trustFailure = error.localizedDescription
            do {
                // Even if SSL approval failed, restore any hosts changes that can be recovered.
                _ = try Self.runHelper("finish-undo", operation: progress)
            } catch {
                throw SetupError("\(trustFailure) \(error.localizedDescription)")
            }
            return "Setup undone"
        }
        if operation == nil {
            showProgress("Restoring the saved server addresses…", completed: 2)
        }
        return try Self.runHelper("finish-undo", operation: progress)
    }

    private func completeInstall() throws -> String {
        let response = try Self.runHelper("prepare")
        if response == "Setup complete" { return response }
        let fields = response.split(separator: ":")
        guard fields.count == 3, fields[0] == "PREPARED", UUID(uuidString: String(fields[1])) != nil,
              fields[2] == "trust" || fields[2] == "trusted" else {
            throw SetupError("Could not start setup.")
        }
        let operation = String(fields[1])
        do {
            if fields[2] == "trust" {
                showProgress("Approve SSL trust for the Royal GTPS certificate when macOS asks.", completed: 1, next: .approval)
                guard let url = Bundle.main.url(forResource: "RoyalGTPS", withExtension: "crt") else {
                    throw SetupError("The Royal GTPS certificate is missing from this copy of the app.")
                }
                let system = try SystemCertificate(Certificate.pinned(Data(contentsOf: url)))
                guard try system.item() != nil, try system.trust() == nil else {
                    throw SetupError("The certificate or its trust settings changed during setup.")
                }
                // Request trust from the logged-in app so macOS can present SecurityAgent.
                try system.setTrust()
            }
            showProgress("Updating Growtopia server addresses…", completed: 2)
            watchVerification(operation)
            return try Self.runHelper("finish", operation: operation)
        } catch {
            let failure = error.localizedDescription
            DispatchQueue.main.async {
                self.progressTimer?.invalidate()
                self.showStatus("Rolling back this setup attempt…", "Restoring the settings changed during this attempt.")
            }
            do {
                _ = try completeUndo(rollback: operation)
            } catch {
                throw SetupError("\(failure) Recovery needs attention. \(error.localizedDescription)")
            }
            throw SetupError("\(failure) Changes from this attempt were rolled back.")
        }
    }

    private func showProgress(_ message: String, completed: Int, next: StepState = .active) {
        DispatchQueue.main.async {
            self.renderSteps(completed: completed, next: next)
            self.showStatus(next == .approval ? "Waiting for macOS approval" :
                                self.restoring ? "Restoring server addresses…" : "Updating server addresses…", message)
        }
    }

    private func watchVerification(_ operation: String) {
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let file = URL(fileURLWithPath: "/var/db/com.royalgtps.setup/progress")
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                      data == Data(operation.utf8) else { return }
                timer.invalidate()
                self.renderSteps(completed: 3, next: .active)
                self.showStatus(self.restoring ? "Verifying restoration…" : "Refreshing and verifying…",
                                self.restoring ? "Refreshing DNS and checking the saved settings."
                                    : "Checking certificate trust and both server addresses.")
            }
        }
    }

    private func perform(_ operation: String) {
        busy = true
        gameReady = false
        renderSteps(completed: 1, next: .approval)
        mode = restoring ? "Restoring setup" : "Installing"
        showStatus("Waiting for macOS approval", "Approve the macOS administrator prompt when it appears.")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try operation == "install" ? self.completeInstall() : self.completeUndo()
            }
            DispatchQueue.main.async {
                self.progressTimer?.invalidate()
                self.busy = false
                switch result {
                case .success("Setup complete"):
                    self.gameReady = true
                    self.renderSteps(completed: 4)
                    self.mode = "Royal GTPS installed"
                    self.showStatus("Royal GTPS is ready", "All four checks passed. You can launch Growtopia.")
                case .success("Setup undone"):
                    self.renderSteps(completed: 4)
                    self.mode = "Previous settings restored"
                    self.showStatus("Previous settings restored", "Setup changes have been reversed. You can reopen Growtopia.")
                case .success(let message):
                    self.renderSteps(completed: 0)
                    self.mode = "No saved setup"
                    self.showStatus(message, "There are no saved changes to restore.")
                case .failure(let error as AuthenticationCancelled):
                    self.renderSteps(completed: self.completed)
                    self.mode = self.hasRecovery ? "Saved setup found" : "Setup not started"
                    self.showStatus("Approval cancelled", error.localizedDescription)
                case .failure(let error):
                    self.renderSteps(completed: min(self.completed, 3), next: .error)
                    self.mode = self.hasRecovery ? "Recovery available" : "Setup stopped"
                    self.showStatus(self.hasRecovery ? "Setup needs attention" : "Setup could not continue",
                                    error.localizedDescription)
                }
            }
        }
    }
}

@main
enum RoyalGTPSApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = SetupWindow()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
