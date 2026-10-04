import Darwin
import Foundation
import XCTest

@testable import CaptureCore

@MainActor final class RecordingStateTests: XCTestCase {
  private let firstApp = URL(fileURLWithPath: "/Applications/First.app")
  private let newApp = URL(fileURLWithPath: "/Applications/New.app")

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func capture(_ bundleID: String, text: String) -> CaptureResult {
    CaptureResult(
      state: .available,
      source: .init(
        applicationName: "Fixture", bundleIdentifier: bundleID,
        processIdentifier: 123, windowTitle: "Fixture window"), text: text)
  }

  func testFreshInstallAllowsNoAppAndNewlySeenAppStaysExcluded() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let vault = try RecordingVault(directory: directory)
      XCTAssertEqual(vault.settings.mode, .off)
      XCTAssertTrue(vault.settings.allowedApps.isEmpty)
      XCTAssertFalse(vault.allows("com.example.first", at: firstApp))
      try vault.setMode(.recording)
      XCTAssertFalse(vault.allows("com.example.first", at: firstApp))
      try vault.allow("com.example.first", at: firstApp)
      XCTAssertTrue(vault.allows("com.example.first", at: firstApp))
      XCTAssertFalse(
        vault.allows("com.example.first", at: newApp),
        "A different bundle with the same ID is excluded")
      XCTAssertFalse(vault.allows("com.example.new", at: newApp))
      try vault.append(capture("com.example.new", text: "never persist"), from: newApp)
      XCTAssertTrue(vault.observations.isEmpty)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("captured-observations.json").path))
    }
    let reopened = try RecordingVault(directory: directory)
    XCTAssertEqual(reopened.settings.mode, .off)
    XCTAssertNotNil(reopened.settings.allowedApps["com.example.first"])
    XCTAssertFalse(reopened.allows("com.example.first", at: firstApp))
    XCTAssertFalse(reopened.allows("com.example.new", at: newApp))
  }

  func testPauseExclusionDeletionAndDuplicateEvents() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let vault = try RecordingVault(directory: directory)
      try vault.allow("com.example.first", at: firstApp)
      try vault.setMode(.recording)
      try vault.append(capture("com.example.first", text: "permitted body"), from: firstApp)
      try vault.append(capture("com.example.first", text: "permitted body"), from: firstApp)
      XCTAssertEqual(
        vault.observations.count, 1, "Repeated notifications must not duplicate unchanged text")
      let archive = try String(
        contentsOf: directory.appendingPathComponent("captured-observations.json"), encoding: .utf8)
      XCTAssertTrue(
        archive.contains("\"observedAt\":\""), "Persisted observations need readable timestamps")
      try vault.setMode(.paused)
      try vault.append(
        capture("com.example.first", text: "not recorded while paused"), from: firstApp)
      XCTAssertEqual(vault.observations.count, 1)
      try vault.setMode(.recording)
      try vault.exclude("com.example.first")
      XCTAssertEqual(vault.retainedAppIdentifiers, ["com.example.first"],
                     "Exclusion must leave retained data visible for deletion")
      try vault.append(
        capture("com.example.first", text: "not recorded when excluded"), from: firstApp)
      XCTAssertEqual(vault.observations.count, 1)
      try vault.deleteCapturedData()
      XCTAssertEqual(vault.settings.mode, .paused)
      XCTAssertTrue(vault.observations.isEmpty)
    }
    XCTAssertTrue(try RecordingVault(directory: directory).observations.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("captured-observations.json").path))
  }

  func testMalformedSettingsFailClosedAndPreserveFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("recording-settings.json")
    let damaged = Data(
      "{\"mode\":\"recording\",\"allowedApps\":{\"../../bad\":\"/Applications/Bad.app\"}}".utf8)
    try damaged.write(to: file)
    XCTAssertThrowsError(try RecordingVault(directory: directory)) { error in
      XCTAssertEqual(error as? RecordingError, .damagedSettings)
    }
    XCTAssertEqual(try Data(contentsOf: file), damaged)
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(try RecordingVault(directory: directory).settings.mode, .off)
  }

  func testPerAppDeletionKeepsOtherCaptureAndArchiveStaysBounded() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let vault = try RecordingVault(directory: directory)
      try vault.allow("com.example.first", at: firstApp)
      try vault.allow("com.example.new", at: newApp)
      try vault.setMode(.recording)
      try vault.append(capture("com.example.first", text: "delete this"), from: firstApp)
      for index in 0...RecordingVault.maximumObservations {
        try vault.append(capture("com.example.new", text: "retained \(index)"), from: newApp)
      }
      XCTAssertEqual(vault.observations.count, RecordingVault.maximumObservations)
      XCTAssertEqual(vault.observations.first?.text, "retained 1")
      try vault.append(capture("com.example.first", text: "delete this too"), from: firstApp)
      try vault.deleteCapturedData(bundleIdentifier: "com.example.first")
      XCTAssertEqual(vault.settings.mode, .paused)
      XCTAssertTrue(vault.observations.allSatisfy { $0.bundleIdentifier == "com.example.new" })
    }
    XCTAssertEqual(
      try RecordingVault(directory: directory).observations.count,
      RecordingVault.maximumObservations - 1)
  }

  func testDeletionPreservesOffAndPausedAndFencesActiveReads() throws {
    for mode in [RecordingMode.off, .paused, .recording] {
      for perApp in [false, true] {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try RecordingVault(directory: directory)
        try vault.allow("com.example.first", at: firstApp)
        try vault.allow("com.example.new", at: newApp)
        try vault.setMode(.recording)
        try vault.append(capture("com.example.first", text: "erase"), from: firstApp)
        try vault.append(capture("com.example.new", text: "keep if per app"), from: newApp)
        try vault.setMode(mode)

        let gate = RecordingGate()
        let pending = mode == .recording ? gate.begin(at: 100) : nil
        gate.invalidate() // RecordingController fences a read before deleting.
        try vault.deleteCapturedData(bundleIdentifier: perApp ? "com.example.first" : nil)
        if let pending { XCTAssertFalse(gate.finish(pending)) }

        let expectedMode: RecordingMode = mode == .recording ? .paused : mode
        XCTAssertEqual(vault.settings.mode, expectedMode)
        let settings = try JSONDecoder().decode(
          RecordingSettings.self,
          from: Data(contentsOf: directory.appendingPathComponent("recording-settings.json")))
        XCTAssertEqual(settings.mode, expectedMode)
        XCTAssertEqual(vault.observations.map(\.text), perApp ? ["keep if per app"] : [])
        try vault.append(capture("com.example.first", text: "late read"), from: firstApp)
        XCTAssertEqual(vault.observations.map(\.text), perApp ? ["keep if per app"] : [])
      }
    }
  }

  func testDeletionArchiveFailureKeepsDataAndOnlyPausesActiveRecording() throws {
    for mode in [RecordingMode.off, .paused, .recording] {
      for perApp in [false, true] {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("captured-observations.json")
        defer {
          _ = chflags(archive.path, 0)
          try? FileManager.default.removeItem(at: directory)
        }
        let vault = try RecordingVault(directory: directory)
        try vault.allow("com.example.first", at: firstApp)
        try vault.allow("com.example.new", at: newApp)
        try vault.setMode(.recording)
        try vault.append(capture("com.example.first", text: "erase"), from: firstApp)
        try vault.append(capture("com.example.new", text: "retain"), from: newApp)
        try vault.setMode(mode)
        let original = try Data(contentsOf: archive)
        XCTAssertEqual(chflags(archive.path, UInt32(UF_IMMUTABLE)), 0)

        XCTAssertThrowsError(
          try vault.deleteCapturedData(bundleIdentifier: perApp ? "com.example.first" : nil))
        let expectedMode: RecordingMode = mode == .recording ? .paused : mode
        XCTAssertEqual(vault.settings.mode, expectedMode)
        XCTAssertEqual(vault.observations.count, 2)
        XCTAssertEqual(try Data(contentsOf: archive), original)
      }
    }
  }

  func testDeletionCannotEraseWhenActiveRecordingCannotPersistPause() throws {
    for perApp in [false, true] {
      let directory = try temporaryDirectory()
      let settingsURL = directory.appendingPathComponent("recording-settings.json")
      defer {
        _ = chflags(settingsURL.path, 0)
        try? FileManager.default.removeItem(at: directory)
      }
      let vault = try RecordingVault(directory: directory)
      try vault.allow("com.example.first", at: firstApp)
      try vault.setMode(.recording)
      try vault.append(capture("com.example.first", text: "must survive"), from: firstApp)
      let archive = directory.appendingPathComponent("captured-observations.json")
      let original = try Data(contentsOf: archive)
      XCTAssertEqual(chflags(settingsURL.path, UInt32(UF_IMMUTABLE)), 0)

      XCTAssertThrowsError(
        try vault.deleteCapturedData(bundleIdentifier: perApp ? "com.example.first" : nil))
      XCTAssertEqual(vault.settings.mode, .paused, "A failed pause still fences new reads")
      XCTAssertEqual(vault.observations.count, 1)
      XCTAssertEqual(try Data(contentsOf: archive), original)
      try vault.append(capture("com.example.first", text: "late read"), from: firstApp)
      XCTAssertEqual(vault.observations.count, 1)
    }
  }

  func testDamagedArchiveIsNotOverwrittenOnOpen() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("captured-observations.json")
    let damaged = Data("not a capture archive".utf8)
    try damaged.write(to: file)
    XCTAssertThrowsError(try RecordingVault(directory: directory)) { error in
      XCTAssertEqual(error as? RecordingError, .damagedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: file), damaged)
  }

  func testSecondInstanceCannotUseStaleAllowlistWhileFirstOwnsRecorder() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var first: RecordingVault? = try RecordingVault(directory: directory)
    try first?.allow("com.example.first", at: firstApp)
    XCTAssertThrowsError(try RecordingVault(directory: directory)) { error in
      XCTAssertEqual(error as? RecordingError, .recorderInUse)
    }
    first = nil
    let reopened = try RecordingVault(directory: directory)
    XCTAssertEqual(reopened.settings.mode, .off)
    XCTAssertNotNil(reopened.settings.allowedApps["com.example.first"])
  }

  func testSecondInstanceCannotEraseLiveArchiveAndOwnerCannotRestoreDeletedText() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("captured-observations.json")
    var owner: RecordingVault? = try RecordingVault(directory: directory)
    try owner?.allow("com.example.first", at: firstApp)
    try owner?.setMode(.recording)
    try owner?.append(capture("com.example.first", text: "first"), from: firstApp)
    XCTAssertThrowsError(try RecordingVault.eraseArchiveWhileClosed(in: directory)) { error in
      XCTAssertEqual(error as? RecordingError, .recorderInUse)
    }
    XCTAssertTrue(try String(contentsOf: archive, encoding: .utf8).contains("first"))
    try owner?.append(capture("com.example.first", text: "second"), from: firstApp)
    XCTAssertEqual(owner?.observations.count, 2)
    owner = nil
    try RecordingVault.eraseArchiveWhileClosed(in: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertTrue(try RecordingVault(directory: directory).observations.isEmpty)
  }

  func testDamagedArchiveCanBeErasedOnlyAfterLockIsAcquired() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("captured-observations.json")
    try Data("malformed".utf8).write(to: archive)
    XCTAssertThrowsError(try RecordingVault(directory: directory)) { error in
      XCTAssertEqual(error as? RecordingError, .damagedArchive)
    }
    try RecordingVault.eraseArchiveWhileClosed(in: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertTrue(try RecordingVault(directory: directory).observations.isEmpty)
  }

  func testThrottleAndInvalidationFenceLateResult() {
    let gate = RecordingGate()
    let first = gate.begin(at: 100)
    XCTAssertNotNil(first)
    XCTAssertFalse(gate.canBegin(at: 100.1))
    XCTAssertNil(gate.begin(at: 100.1))
    XCTAssertTrue(gate.finish(first!))
    XCTAssertFalse(gate.canBegin(at: 102.9))
    XCTAssertNil(gate.begin(at: 102.9))
    XCTAssertTrue(gate.canBegin(at: 103))
    let second = gate.begin(at: 103)
    XCTAssertNotNil(second)
    gate.invalidate()
    XCTAssertFalse(gate.finish(second!))
    XCTAssertNil(gate.begin(at: 103.1), "A switch must not bypass the attempt interval")
    XCTAssertNotNil(gate.begin(at: 106))
  }

  func testAllowedAppSwitchesAndControlTransitionsDoNotResetAttemptLimit() {
    let gate = RecordingGate()
    var pending = gate.begin(at: 100) // First allowed foreground app.
    XCTAssertNotNil(pending)
    for time in [100.1, 100.2, 100.3, 102.9] {
      gate.invalidate() // Switch, pause/resume, exclusion, deletion, or sleep/wake.
      if let pending { XCTAssertFalse(gate.finish(pending), "Late AX work is discarded") }
      XCTAssertNil(gate.begin(at: time), "A control transition cannot start another AX read")
    }
    pending = gate.begin(at: 103) // Second allowed app may now be read.
    XCTAssertNotNil(pending)
    XCTAssertTrue(gate.finish(pending!))
    for time in [103.01, 104, 105.99] {
      XCTAssertNil(gate.begin(at: time), "Repeated AX notifications remain throttled")
    }
    XCTAssertNotNil(gate.begin(at: 106))
  }

  func testDelayedWorkerAdmissionExtendsLimitEvenAfterInvalidation() {
    let gate = RecordingGate()
    let pending = gate.begin(at: 100)
    XCTAssertNotNil(pending)
    gate.invalidate() // Pause or switch can precede delivery of the worker-start callback.
    gate.recordCaptureStart(at: 104.25) // Manual AX work delayed this automatic read.
    XCTAssertFalse(gate.finish(pending!))
    XCTAssertNil(gate.begin(at: 107.24), "The enqueue timestamp cannot bound a delayed AX start")
    XCTAssertNotNil(gate.begin(at: 107.25))
  }

  func testInvalidSelectedAppErrorNamesTheSelection() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = try RecordingVault(directory: directory)
    let selected = URL(fileURLWithPath: "/Applications/Invalid.app")
    XCTAssertThrowsError(try vault.allow("bad_identifier", at: selected)) { error in
      XCTAssertEqual(error as? RecordingError, .invalidBundleIdentifier("Invalid.app"))
      XCTAssertEqual(error.localizedDescription,
                     "The selected app \"Invalid.app\" has no valid bundle identifier.")
    }
    XCTAssertTrue(vault.settings.allowedApps.isEmpty)
  }

  func testObserverFailuresRetryOnHeartbeatAndRecoverAfterTransitions() {
    var retry = ObserverRetryState()
    let app: Int32 = 101
    XCTAssertTrue(retry.shouldAttempt(pid: app, at: 100))

    // AXObserverCreate fails. A completion tick cannot turn that into a tight retry loop.
    retry.failed(at: 100)
    XCTAssertNil(retry.registeredPID)
    XCTAssertFalse(retry.shouldAttempt(pid: app, at: 101.9))
    XCTAssertTrue(retry.shouldAttempt(pid: app, at: 102))

    // Notification registration fails after creation, then recovers on a later heartbeat.
    retry.failed(at: 102)
    XCTAssertFalse(retry.shouldAttempt(pid: app, at: 103))
    retry.failed(at: 104)
    XCTAssertEqual(retry.consecutiveFailures, 3)
    XCTAssertTrue(retry.shouldAttempt(pid: app, at: 106))
    retry.succeeded(pid: app)
    XCTAssertFalse(retry.shouldAttempt(pid: app, at: 108))
    XCTAssertEqual(retry.consecutiveFailures, 0)

    // Permission loss, sleep, and switching apps detach and allow a fresh attempt.
    for nextPID: Int32 in [app, 202, app] {
      retry.reset()
      XCTAssertNil(retry.registeredPID)
      XCTAssertTrue(retry.shouldAttempt(pid: nextPID, at: 108))
      retry.succeeded(pid: nextPID)
      XCTAssertFalse(retry.shouldAttempt(pid: nextPID, at: 110))
    }
  }
}
