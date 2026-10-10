import AppKit
import ApplicationServices
import CaptureCore
import Foundation

@MainActor final class RecordingController {
    let vault: RecordingVault
    private let gate = RecordingGate()
    private var deadline: CaptureCollector.Deadline?
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var foregroundPID: pid_t?
    private var observerRetry = ObserverRetryState()
    private var awake = true
    private var workspaceTokens: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    private var workerReady = true
    private var stopped = false
    private(set) var lastError: String?
    private(set) var observerError: String?

    /// Wires one locked vault to foreground, sleep, and AX events on the menu thread.
    init(vault: RecordingVault) {
        self.vault = vault
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.foregroundChanged() }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.awake = false
                self?.invalidate()
                self?.detachObserver()
            }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.awake = true
                self?.foregroundChanged()
            }
        })
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        foregroundChanged()
    }

    /// Fences pending work before changing the durable recording mode.
    func setMode(_ mode: RecordingMode) throws {
        invalidate()
        detachObserver()
        try vault.setMode(mode)
        lastError = nil
        foregroundChanged()
    }

    /// Adds a selected app without implicitly starting recording.
    func allow(_ bundleIdentifier: String, at bundleURL: URL) throws {
        invalidate()
        try vault.allow(bundleIdentifier, at: bundleURL)
        lastError = nil
        foregroundChanged()
    }

    /// Cancels pending reads before removing an app from the allowlist.
    func exclude(_ bundleIdentifier: String) throws {
        invalidate()
        detachObserver()
        try vault.exclude(bundleIdentifier)
        lastError = nil
        foregroundChanged()
    }

    /// Fences results before deleting one app's archive rows or all captured data.
    func deleteCapturedData(bundleIdentifier: String? = nil) throws {
        invalidate()
        defer {
            detachObserver()
            foregroundPID = nil
        }
        try vault.deleteCapturedData(bundleIdentifier: bundleIdentifier)
        lastError = nil
    }

    /// Removes timers and observers when the menu host shuts down.
    func stop() {
        stopped = true
        invalidate()
        detachObserver()
        heartbeat?.invalidate()
        heartbeat = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
    }

    /// Cancels queued AX work and rejects any in-flight result from an older generation.
    private func invalidate() {
        gate.invalidate()
        deadline?.cancel()
        deadline = nil
    }

    /// Tears down the previous app observer before evaluating the newly frontmost app.
    private func foregroundChanged() {
        invalidate()
        detachObserver()
        foregroundPID = nil
        tick()
    }

    /// Rechecks trust, wake state, and the allowlist; heartbeat backs up missing AX events.
    private func tick() {
        guard !stopped, awake, CaptureCollector.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              vault.allows(app.bundleIdentifier, at: app.bundleURL) else {
            if foregroundPID != nil {
                invalidate()
                detachObserver()
                foregroundPID = nil
            }
            return
        }
        if foregroundPID != app.processIdentifier {
            invalidate()
            detachObserver()
            foregroundPID = app.processIdentifier
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if observerRetry.shouldAttempt(pid: app.processIdentifier, at: uptime) {
            if let error = attachObserver(pid: app.processIdentifier) {
                observerRetry.failed(at: uptime)
                if observerRetry.consecutiveFailures >= 3 {
                    observerError = "AX notifications unavailable (\(error)); checking every 2 seconds"
                }
            } else {
                observerRetry.succeeded(pid: app.processIdentifier)
                observerError = nil
            }
        }
        signal()
    }

    /// Reserves one throttled automatic request for the currently authorized app identity.
    private func signal() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard !stopped, workerReady, awake, gate.canBegin(at: uptime),
              CaptureCollector.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              let bundleURL = app.bundleURL,
              vault.allows(bundleIdentifier, at: bundleURL),
              let token = gate.begin(at: uptime) else { return }
        let pid = app.processIdentifier
        workerReady = false
        deadline = CaptureCollector.captureAllowedForeground(
            pid: pid, bundleIdentifier: bundleIdentifier, bundleURL: bundleURL,
            onWorkerStart: { [weak self] startedAt in
            self?.gate.recordCaptureStart(at: startedAt)
        }) { [weak self] result in
            guard let self else { return }
            CaptureCollector.afterCaptureWorkerDrains { [weak self] in
                guard let self else { return }
                self.workerReady = true
                self.tick()
            }
            guard self.gate.finish(token) else { return }
            self.deadline = nil
            guard self.awake, CaptureCollector.isTrusted(),
                  self.vault.allows(bundleIdentifier, at: bundleURL),
                  let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.processIdentifier == pid,
                  frontmost.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() ==
                      bundleURL.standardizedFileURL.resolvingSymlinksInPath(),
                  result.state == .available, result.processIdentifier == pid,
                  result.bundleIdentifier == bundleIdentifier else { return }
            do {
                try self.vault.append(result, from: bundleURL)
                self.lastError = nil
            }
            catch { self.lastError = error.localizedDescription }
        }
    }

    // A failed partial registration must be removed before the next attempt.
    // Return a diagnostic only after the caller can safely retry on a heartbeat.
    /// Registers both focus notifications or removes a partial registration for retry.
    private func attachObserver(pid: pid_t) -> String? {
        // AXObserverCreate's CF_RETURNS_RETAINED out parameter imports as a
        // Swift-managed AXObserver. Dropping `created` releases a failed setup;
        // `self.observer = nil` releases a successful one after source removal.
        var created: AXObserver?
        let createError = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let controller = Unmanaged<RecordingController>.fromOpaque(context).takeUnretainedValue()
            // This source is installed on the main run loop. Handle the bounded
            // signal there without enqueuing one main-queue block per AX event.
            MainActor.assumeIsolated {
                controller.signal()
            }
        }, &created)
        guard createError == .success, let created else {
            return "observer creation failed: \(createError.rawValue)"
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registered: [String] = []
        for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
            let result = AXObserverAddNotification(created, app, notification as CFString, context)
            guard result == .success else {
                for name in registered {
                    _ = AXObserverRemoveNotification(created, app, name as CFString)
                }
                return "notification registration failed: \(result.rawValue)"
            }
            registered.append(notification)
        }
        observer = created
        observedApplication = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        return nil
    }

    /// Removes the current AX run-loop source and clears observer retry diagnostics.
    private func detachObserver() {
        if let observer {
            if let app = observedApplication {
                for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
                    _ = AXObserverRemoveNotification(observer, app, notification as CFString)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        self.observer = nil
        observedApplication = nil
        observerRetry.reset()
        observerError = nil
    }
}
