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
    private var observedWindow: AXUIElement?
    private var observedPID: pid_t?
    private var awake = true
    private var workspaceTokens: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    private var workerReady = true
    private var stopped = false
    private(set) var lastError: String?

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

    func setMode(_ mode: RecordingMode) throws {
        invalidate()
        detachObserver()
        try vault.setMode(mode)
        foregroundChanged()
    }

    func allow(_ bundleIdentifier: String, at bundleURL: URL) throws {
        invalidate()
        try vault.allow(bundleIdentifier, at: bundleURL)
        foregroundChanged()
    }

    func exclude(_ bundleIdentifier: String) throws {
        invalidate()
        detachObserver()
        try vault.exclude(bundleIdentifier)
        foregroundChanged()
    }

    func deleteCapturedData(bundleIdentifier: String? = nil) throws {
        invalidate()
        try vault.deleteCapturedData(bundleIdentifier: bundleIdentifier)
    }

    func stop() {
        stopped = true
        invalidate()
        detachObserver()
        heartbeat?.invalidate()
        heartbeat = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
    }

    private func invalidate() {
        gate.invalidate()
        deadline?.cancel()
        deadline = nil
    }

    private func foregroundChanged() {
        invalidate()
        detachObserver()
        tick()
    }

    private func tick() {
        guard !stopped, awake, CaptureCollector.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              vault.allows(app.bundleIdentifier, at: app.bundleURL) else {
            if observedPID != nil { invalidate(); detachObserver() }
            return
        }
        if observedPID != app.processIdentifier {
            invalidate()
            detachObserver()
            observedPID = app.processIdentifier
            attachObserver(pid: app.processIdentifier)
        }
        signal()
    }

    private func signal() {
        guard !stopped, workerReady, awake, CaptureCollector.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              let bundleURL = app.bundleURL,
              vault.allows(bundleIdentifier, at: bundleURL),
              let token = gate.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
        let pid = app.processIdentifier
        workerReady = false
        deadline = CaptureCollector.captureForeground { [weak self] result in
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

    private func attachObserver(pid: pid_t) {
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            let controller = Unmanaged<RecordingController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                if notification as String == kAXFocusedWindowChangedNotification as String {
                    controller.attachWindowNotification()
                }
                controller.signal()
            }
        }, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
            _ = AXObserverAddNotification(created, app, notification as CFString, context)
        }
        observer = created
        observedApplication = app
        observedPID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        attachWindowNotification()
    }

    private func attachWindowNotification() {
        guard let observer, let app = observedApplication else { return }
        if let old = observedWindow {
            _ = AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
            observedWindow = nil
        }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        let window = raw as! AXUIElement
        if AXObserverAddNotification(observer, window, kAXValueChangedNotification as CFString,
                                     Unmanaged.passUnretained(self).toOpaque()) == .success {
            observedWindow = window
        }
    }

    private func detachObserver() {
        guard let observer else { observedPID = nil; return }
        if let app = observedApplication {
            for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
                _ = AXObserverRemoveNotification(observer, app, notification as CFString)
            }
        }
        if let window = observedWindow {
            _ = AXObserverRemoveNotification(observer, window, kAXValueChangedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        observedApplication = nil
        observedWindow = nil
        observedPID = nil
    }
}
