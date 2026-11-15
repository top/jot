// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import JotCore

@MainActor
final class AppUpdateManager: ObservableObject {
    @Published private(set) var automaticallyChecks: Bool
    @Published private(set) var availableUpdate: UpdateRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var statusMessage: String?

    var onAvailableUpdateChanged: ((UpdateRelease?) -> Void)?

    private let settings = SettingsStore()
    private let session = URLSession(configuration: OpenAIClient.makeEphemeralConfiguration(timeoutForResource: 300))
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var progressPanel: NSPanel?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    init() {
        self.automaticallyChecks = settings.automaticallyChecksForUpdates
    }

    deinit {
        session.invalidateAndCancel()
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .gtSettingDidChange,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard (note.object as? String) == "automaticallyChecksForUpdates" else { return }
                Task { @MainActor [weak self] in
                    self?.syncAutomaticCheckSetting()
                }
            }
        )
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkIfDue()
                }
            }
        )
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIfDue()
            }
        }
        checkIfDue()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        automaticallyChecks = enabled
        statusMessage = nil
        settings.setAutomaticallyChecksForUpdates(enabled)
    }

    func checkIfDue() {
        guard AppUpdateChecker.shouldCheck(
            automaticallyChecks: settings.automaticallyChecksForUpdates,
            lastCheckedAt: settings.lastUpdateCheckAt
        ) else { return }
        checkNow(userInitiated: false)
    }

    func checkNow(userInitiated: Bool) {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        if userInitiated {
            statusMessage = "Checking for updates…"
        }

        let current = currentVersion
        let updateSession = session
        Task { [weak self] in
            defer { self?.isChecking = false }
            do {
                let result = try await AppUpdateChecker.fetchLatestUpdate(
                    releasesURL: JotLinks.latestReleaseAPI,
                    currentVersion: current,
                    session: updateSession
                )
                guard let self else { return }
                self.settings.setLastUpdateCheckAt(Date())
                switch result {
                case .upToDate:
                    self.setAvailableUpdate(nil)
                    if userInitiated {
                        self.statusMessage = "Jot \(current) is the latest version."
                    }
                case .available(let release):
                    self.setAvailableUpdate(release)
                    self.statusMessage = "Update available: v\(release.version)"
                    if userInitiated {
                        self.promptAndInstall()
                    }
                }
            } catch {
                guard let self else { return }
                Log.session.warning("update check failed: \(error.localizedDescription, privacy: .public)")
                if userInitiated {
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func promptAndInstall() {
        guard let release = availableUpdate, !isInstalling else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Jot to v\(release.version)?"
        var info = "Current version: v\(currentVersion)\nNew version: v\(release.version)"
        if let notes = release.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let preview = notes.count > 400 ? String(notes.prefix(400)) + "…" : notes
            info += "\n\n\(preview)"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            install(release: release)
        }
    }

    private func syncAutomaticCheckSetting() {
        automaticallyChecks = settings.automaticallyChecksForUpdates
        if automaticallyChecks {
            checkIfDue()
        }
    }

    private func setAvailableUpdate(_ release: UpdateRelease?) {
        availableUpdate = release
        onAvailableUpdateChanged?(release)
    }

    private func install(release: UpdateRelease) {
        let targetBundleURL = Bundle.main.bundleURL
        do {
            try AppUpdateChecker.validateInstallTarget(bundleURL: targetBundleURL)
        } catch {
            showError(error.localizedDescription)
            return
        }

        isInstalling = true
        statusMessage = "Downloading v\(release.version)…"
        showProgressPanel(title: "Updating Jot to v\(release.version)…")

        let expectedBundleID = Bundle.main.bundleIdentifier ?? "org.ie9.app"
        Task { [weak self] in
            guard let self else { return }
            do {
                let stagingDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("jot-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

                let (downloadedURL, response) = try await session.download(from: release.downloadURL)
                guard let http = response as? HTTPURLResponse else {
                    throw AppUpdateError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw AppUpdateError.httpError(http.statusCode)
                }
                guard http.url?.scheme?.lowercased() == "https" else {
                    throw AppUpdateError.invalidResponse
                }

                let zipURL = stagingDir.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: downloadedURL, to: zipURL)
                try AppUpdateChecker.verifyDownloadedArchive(
                    at: zipURL,
                    expectedSize: release.expectedSize,
                    expectedSHA256: release.sha256
                )

                let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                self.statusMessage = "Installing v\(release.version)…"
                let newAppURL = try await Self.extractAndVerifyApp(
                    zipURL: zipURL,
                    extractDir: extractDir,
                    expectedBundleID: expectedBundleID
                )

                try Self.launchReplacementScript(
                    currentPID: ProcessInfo.processInfo.processIdentifier,
                    targetAppURL: targetBundleURL,
                    newAppURL: newAppURL,
                    stagingDir: stagingDir
                )
                NSApp.terminate(nil)
            } catch {
                self.closeProgressPanel()
                self.isInstalling = false
                self.statusMessage = error.localizedDescription
                Log.session.error("update install failed: \(error.localizedDescription, privacy: .public)")
                self.showError("Could not install update: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func extractAndVerifyApp(
        zipURL: URL,
        extractDir: URL,
        expectedBundleID: String
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try runTool("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, extractDir.path])

            let preferred = extractDir.appendingPathComponent("Jot.app", isDirectory: true)
            let newAppURL: URL
            if FileManager.default.fileExists(atPath: preferred.path) {
                newAppURL = preferred
            } else if let found = try FileManager.default.contentsOfDirectory(
                at: extractDir,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension.lowercased() == "app" }) {
                newAppURL = found
            } else {
                throw AppUpdateError.invalidResponse
            }

            guard Bundle(url: newAppURL)?.bundleIdentifier == expectedBundleID else {
                throw AppUpdateError.invalidResponse
            }
            try runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", newAppURL.path])
            return newAppURL
        }.value
    }

    private nonisolated static func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "JotUpdate",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent) exited with status \(process.terminationStatus)."]
            )
        }
    }

    private nonisolated static func launchReplacementScript(
        currentPID: Int32,
        targetAppURL: URL,
        newAppURL: URL,
        stagingDir: URL
    ) throws {
        let script = """
        pid="$1"
        target="$2"
        new_app="$3"
        staging="$4"
        backup="${target}.backup"

        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -ge 150 ] && exit 1
          sleep 0.1
        done

        rm -rf "$backup"
        if [ -e "$target" ]; then
          mv "$target" "$backup" || exit 1
        fi
        if mv "$new_app" "$target" 2>/dev/null || /usr/bin/ditto "$new_app" "$target"; then
          rm -rf "$backup" "$staging"
          /usr/bin/open -n "$target"
        else
          [ -e "$backup" ] && mv "$backup" "$target"
          rm -rf "$staging"
          exit 1
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "--", "\(currentPID)", targetAppURL.path, newAppURL.path, stagingDir.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func showProgressPanel(title: String) {
        closeProgressPanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 84),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Software Update"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(spinner)

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            spinner.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = container
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressPanel = panel
    }

    private func closeProgressPanel() {
        progressPanel?.close()
        progressPanel = nil
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
