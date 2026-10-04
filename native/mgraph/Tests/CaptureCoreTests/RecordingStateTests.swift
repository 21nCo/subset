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

  func testThrottleAndInvalidationFenceLateResult() {
    let gate = RecordingGate()
    let first = gate.begin(at: 100)
    XCTAssertNotNil(first)
    XCTAssertNil(gate.begin(at: 100.1))
    XCTAssertTrue(gate.finish(first!))
    XCTAssertNil(gate.begin(at: 102.9))
    let second = gate.begin(at: 103)
    XCTAssertNotNil(second)
    gate.invalidate()
    XCTAssertFalse(gate.finish(second!))
    XCTAssertNotNil(gate.begin(at: 103.1), "Resume or app switch may capture immediately")
  }
}
