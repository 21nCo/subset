import Foundation
import Testing
@testable import PointInTimeCore

private let newYork = TimeZone(identifier: "America/New_York")!

private func local(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, zone: TimeZone = newYork) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pit-status-\(UUID().uuidString)", isDirectory: true)
}

private nonisolated(unsafe) let setUp: [String: Any] = [StoredSettings.Key.onboardingCompleted: true, StoredSettings.Key.trackingEnabled: true]

private func environment(_ directory: URL?, now: Date, zone: TimeZone = newYork, settings: [String: Any] = setUp,
                         appRunning: Bool? = true) -> StatusEnvironment {
    StatusEnvironment(now: now, timeZone: zone, storeDirectory: directory, settings: StoredSettings(settings), appRunning: appRunning,
                      version: "0.1.0 (1)")
}

private func segment(_ bundleID: String, _ name: String, _ start: Date, minutes: Double, title: String? = nil, url: String? = nil,
                     excluded: Bool = false) -> Segment {
    Segment(start: start, end: start.addingTimeInterval(minutes * 60), excluded: excluded, bundleID: bundleID, appName: name,
            windowTitle: title, url: url.flatMap(RedactedURL.init))
}

/// Labels every stored block in `[from, to)` whose dominant app is `bundleID`.
private func label(_ store: ActivityStore, _ bundleID: String, _ label: BlockLabel, from: Date, to: Date, at date: Date) throws {
    let blocks = try store.blocks(from: from, to: to).filter { $0.dominantBundleID == bundleID }
    try store.applyClassifications(blocks.map { BlockClassification(blockStart: $0.start, revision: $0.revision, label: label, reason: "r", confidence: 0.9) },
                                   rejected: [], provider: "openrouter", model: "m", at: date)
}

/// October 21 in New York: 30 minutes in an editor on a private page (Focus), 15 in a browser on a video (Drift), and
/// 3 minutes of an excluded app.
private func seedWorkday(_ store: ActivityStore) throws {
    try store.save(segment("com.example.editor", "Editor", local(21, 9), minutes: 30, title: "Secret Plan Q4",
                           url: "https://docs.example.com/private/roadmap?token=abc#notes"))
    try store.save(segment("com.example.browser", "Browser", local(21, 9, 30), minutes: 15, title: "Cat video",
                           url: "https://video.example.net/watch/123"))
    try store.save(segment("com.example.vault", "Vault", local(21, 9, 45), minutes: 3, excluded: true))
    try label(store, "com.example.editor", .focus, from: local(21, 0), to: local(22, 0), at: local(21, 10))
    try label(store, "com.example.browser", .drift, from: local(21, 0), to: local(22, 0), at: local(21, 10, 5))
}

private func object(_ output: StatusCommand.Output) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8)) as? [String: Any])
}

/// Every file of the store with its bytes and modification time, to prove a read changed nothing.
private func fingerprint(_ directory: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
        let url = directory.appendingPathComponent(name)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        result[name] = "\(try Data(contentsOf: url).hashValue) \(modified?.timeIntervalSince1970 ?? 0)"
    }
    return result
}

// MARK: Schema

/// A validator for the JSON Schema keywords `schemas/status-v1.schema.json` uses. `checkKeywords` fails on any other
/// keyword, so the schema cannot rely on one this validator would silently ignore.
private struct SchemaValidator {
    static let keywords: Set<String> = ["$schema", "$id", "$defs", "$ref", "title", "description", "type", "additionalProperties",
                                        "required", "properties", "const", "enum", "format", "minLength", "minimum", "maximum",
                                        "maxItems", "items"]
    let root: [String: Any]

    static func load() throws -> SchemaValidator {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schemas/status-v1.schema.json")
        return SchemaValidator(root: try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]))
    }

    func unsupportedKeywords(_ schema: [String: Any]? = nil, path: String = "#") -> [String] {
        let schema = schema ?? root
        var problems = schema.keys.filter { !Self.keywords.contains($0) }.map { "\(path)/\($0)" }
        for container in ["properties", "$defs"] {
            for (name, child) in schema[container] as? [String: Any] ?? [:] {
                problems += unsupportedKeywords(child as? [String: Any] ?? [:], path: "\(path)/\(container)/\(name)")
            }
        }
        if let items = schema["items"] as? [String: Any] { problems += unsupportedKeywords(items, path: "\(path)/items") }
        return problems
    }

    func errors(_ value: Any, _ schema: [String: Any]? = nil, path: String = "$") -> [String] {
        var schema = schema ?? root
        if let reference = schema["$ref"] as? String {
            let name = reference.replacingOccurrences(of: "#/$defs/", with: "")
            schema = ((root["$defs"] as? [String: Any])?[name] as? [String: Any] ?? [:]).merging(schema) { definition, _ in definition }
        }
        var problems: [String] = []
        if let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map({ [$0] }), !types.contains(where: { Self.matches(value, $0) }) {
            return ["\(path): \(value) is not \(types)"]
        }
        if let constant = schema["const"], !Self.equal(value, constant) { problems.append("\(path): \(value) is not \(constant)") }
        if let options = schema["enum"] as? [Any], !options.contains(where: { Self.equal(value, $0) }) { problems.append("\(path): \(value) not in enum") }
        if let text = value as? String {
            if let minimum = schema["minLength"] as? Int, text.count < minimum { problems.append("\(path): too short") }
            switch schema["format"] as? String {
            case "date-time":
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                if formatter.date(from: text) == nil { problems.append("\(path): \(text) is not a date-time") }
            case "date":
                if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil { problems.append("\(path): \(text) is not a date") }
            default: break
            }
        }
        if let number = value as? NSNumber, !Self.isBool(value) {
            if let minimum = schema["minimum"] as? Double, number.doubleValue < minimum { problems.append("\(path): below minimum") }
            if let maximum = schema["maximum"] as? Double, number.doubleValue > maximum { problems.append("\(path): above maximum") }
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { problems.append("\(path): missing \(key)") }
            if schema["additionalProperties"] as? Bool == false {
                for key in object.keys where properties[key] == nil { problems.append("\(path): unexpected \(key)") }
            }
            for (key, child) in object {
                if let childSchema = properties[key] as? [String: Any] { problems += errors(child, childSchema, path: "\(path).\(key)") }
            }
        }
        if let array = value as? [Any] {
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { problems.append("\(path): more than \(maximum) items") }
            if let items = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() { problems += errors(item, items, path: "\(path)[\(index)]") }
            }
        }
        return problems
    }

    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func matches(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "null": value is NSNull
        case "boolean": isBool(value)
        case "integer": !isBool(value) && (value as? NSNumber).map { $0.doubleValue.rounded() == $0.doubleValue } == true
        case "number": !isBool(value) && value is NSNumber
        case "string": value is String
        case "array": value is [Any]
        case "object": value is [String: Any]
        default: false
        }
    }

    static func equal(_ value: Any, _ other: Any) -> Bool {
        (value as? NSObject)?.isEqual(other) == true && isBool(value) == isBool(other)
    }
}

/// Validates `output`'s JSON against the checked-in schema and returns it.
@discardableResult
private func validated(_ output: StatusCommand.Output) throws -> [String: Any] {
    let json = try object(output)
    let problems = try SchemaValidator.load().errors(json)
    #expect(problems.isEmpty, "\(problems)")
    return json
}

@Suite struct StatusSchemaTests {
    @Test func theSchemaUsesOnlyKeywordsTheValidatorChecks() throws {
        let validator = try SchemaValidator.load()
        #expect(validator.unsupportedKeywords().isEmpty, "\(validator.unsupportedKeywords())")
        #expect(validator.root["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
    }

    @Test func theValidatorRejectsOutputThatBreaksTheSchema() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seedWorkday(ActivityStore(directory: directory))
        var json = try validated(StatusCommand.run(["status", "--json", "--date", "2026-10-21"], environment: environment(directory, now: local(21, 12))))
        let validator = try SchemaValidator.load()
        json["extra"] = 1
        json["focusPercent"] = 101
        json.removeValue(forKey: "errors")
        json["titles"] = "Secret Plan Q4"
        var tracking = try #require(json["tracking"] as? [String: Any])
        tracking["state"] = "recording"
        json["tracking"] = tracking
        let problems = validator.errors(json).joined(separator: "\n")
        for expected in ["unexpected extra", "focusPercent: above maximum", "missing errors", "titles: Secret Plan Q4 is not", "tracking.state: recording not in enum"] {
            #expect(problems.contains(expected), "\(expected) in \(problems)")
        }
    }
}

// MARK: Output

@Suite struct StatusOutputTests {
    @Test func aNormalDaySummarizesTotalsAppsAndSitesWithoutTitlesOrPaths() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seedWorkday(ActivityStore(directory: directory))
        let output = StatusCommand.run(["status", "--json", "--date", "2026-10-21"], environment: environment(directory, now: local(21, 12)))
        #expect(output.exitCode == .ok)
        #expect(output.standardError.isEmpty)
        let json = try validated(output)
        #expect(json["date"] as? String == "2026-10-21")
        #expect(json["timeZone"] as? String == "America/New_York")
        #expect(json["observedAt"] as? String == "2026-10-21T12:00:00-04:00")
        let totals = try #require(json["totals"] as? [String: Int])
        #expect(totals == ["focus": 1_800, "neutral": 0, "drift": 900, "unclassified": 0, "excluded": 180, "classified": 2_700, "recorded": 2_880])
        #expect(json["focusPercent"] as? Int == 67)
        let apps = try #require(json["topApps"] as? [[String: Any]])
        #expect(apps.map { $0["bundleID"] as? String } == ["com.example.editor", "com.example.browser"])
        #expect(apps.map { $0["name"] as? String } == ["Editor", "Browser"])
        let hosts = try #require(json["topHosts"] as? [[String: Any]])
        #expect(hosts.map { $0["host"] as? String } == ["docs.example.com", "video.example.net"])
        #expect(hosts.map { $0["seconds"] as? Int } == [1_800, 900])
        #expect(json["titles"] is NSNull)
        #expect(json["currentDrift"] is NSNull)
        #expect((json["errors"] as? [Any])?.isEmpty == true)
        #expect(json["store"] as? [String: AnyHashable] == ["state": "ok", "schemaVersion": 2])
        #expect(json["freshness"] as? [String: String] == ["lastSegmentEnd": "2026-10-21T09:48:00-04:00", "lastClassifiedAt": "2026-10-21T10:05:00-04:00"])
        #expect(json["classification"] as? [String: AnyHashable] == ["provider": "off", "pending": 0, "failed": 0])
        // No title, page path, query, or excluded app anywhere, in either output.
        let text = StatusCommand.run(["status", "--date", "2026-10-21"], environment: environment(directory, now: local(21, 12)))
        for leak in ["Secret Plan", "Cat video", "/private", "roadmap", "/watch", "token", "com.example.vault", "Vault"] {
            #expect(!output.standardOutput.contains(leak), "JSON contains \(leak)")
            #expect(!text.standardOutput.contains(leak), "text contains \(leak)")
        }
        #expect(text.exitCode == .ok)
        #expect(text.standardOutput.contains("Focus 30 min, Drift 15 min, Excluded 3 min. Focus is 67% of classified time."))
        #expect(text.standardOutput.contains("Top sites: docs.example.com 30 min, video.example.net 15 min."))
    }

    @Test func includeTitlesAddsTitlesAndPagesButNeverQueries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seedWorkday(ActivityStore(directory: directory))
        let output = StatusCommand.run(["status", "--json", "--include-titles", "--date=2026-10-21"], environment: environment(directory, now: local(21, 12)))
        let json = try validated(output)
        let titles = try #require(json["titles"] as? [[String: Any]])
        #expect(titles.map { $0["title"] as? String } == ["Secret Plan Q4", "Cat video"])
        #expect(titles.map { $0["url"] as? String } == ["https://docs.example.com/private/roadmap", "https://video.example.net/watch/123"])
        #expect(titles.map { $0["seconds"] as? Int } == [1_800, 900])
        #expect(!output.standardOutput.contains("token"))
        #expect(!output.standardOutput.contains("notes"))
        #expect(!output.standardOutput.contains("Vault"))
        let text = StatusCommand.run(["status", "--include-titles", "--date", "2026-10-21"], environment: environment(directory, now: local(21, 12)))
        #expect(text.standardOutput.contains("Secret Plan Q4"))
    }

    @Test func anEmptyStoreReportsZeroTimeAndNoFocusShare() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ActivityStore(directory: directory)
        let output = StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12)))
        #expect(output.exitCode == .ok)
        let json = try validated(output)
        #expect(json["totals"] as? [String: Int] == ["focus": 0, "neutral": 0, "drift": 0, "unclassified": 0, "excluded": 0, "classified": 0, "recorded": 0])
        #expect(json["focusPercent"] is NSNull)
        #expect((json["topApps"] as? [Any])?.isEmpty == true)
        #expect(json["freshness"] as? [String: NSNull] == ["lastSegmentEnd": NSNull(), "lastClassifiedAt": NSNull()])
        #expect((json["errors"] as? [Any])?.isEmpty == true)
        let text = StatusCommand.run(["status"], environment: environment(directory, now: local(21, 12)))
        #expect(text.standardOutput.contains("No activity recorded."))
        #expect(text.standardOutput.contains("Last activity: none. Last classified: never."))
    }

    @Test func anAllUnclassifiedDayCountsPendingTimeAndHasNoFocusShare() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("com.example.editor", "Editor", local(21, 9), minutes: 12))
        try store.save(segment("com.example.mail", "Mail", local(21, 9, 12), minutes: 6))
        try store.applyClassifications([], rejected: try store.blocks(from: local(21, 9, 12), to: local(21, 9, 15)), provider: "openrouter",
                                       model: "m", at: local(21, 10), maxAttempts: 1)
        let settings = setUp.merging([StoredSettings.Key.classificationProvider: "openRouter"]) { $1 }
        let json = try validated(StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12), settings: settings)))
        #expect((json["totals"] as? [String: Int])?["unclassified"] == 1_080)
        #expect((json["totals"] as? [String: Int])?["classified"] == 0)
        #expect(json["focusPercent"] is NSNull)
        #expect(json["classification"] as? [String: AnyHashable] == ["provider": "openrouter", "pending": 5, "failed": 1])
    }

    @Test func trackingStateComesFromTheAppsSettings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ActivityStore(directory: directory)
        let now = local(21, 12)
        func tracking(_ settings: [String: Any], appRunning: Bool? = true) throws -> [String: AnyHashable]? {
            try validated(StatusCommand.run(["status", "--json"], environment: environment(directory, now: now, settings: settings, appRunning: appRunning)))["tracking"] as? [String: AnyHashable]
        }
        let null = NSNull() as AnyHashable
        #expect(try tracking([:], appRunning: false) == ["state": "notSetUp", "pausedUntil": null, "appRunning": false])
        #expect(try tracking([StoredSettings.Key.onboardingCompleted: true]) == ["state": "off", "pausedUntil": null, "appRunning": true])
        #expect(try tracking(setUp, appRunning: nil) == ["state": "on", "pausedUntil": null, "appRunning": null])
        #expect(try tracking(setUp.merging([StoredSettings.Key.pausedUntil: local(21, 12, 15)]) { $1 })
                == ["state": "paused", "pausedUntil": "2026-10-21T12:15:00-04:00", "appRunning": true])
        #expect(try tracking(setUp.merging([StoredSettings.Key.pausedUntil: Date.distantFuture]) { $1 })
                == ["state": "paused", "pausedUntil": null, "appRunning": true])
        // A pause that has ended reads as on, as the app treats it.
        #expect(try tracking(setUp.merging([StoredSettings.Key.pausedUntil: local(21, 11)]) { $1 })
                == ["state": "on", "pausedUntil": null, "appRunning": true])
    }

    @Test func theCurrentDriftIsTheCompanionsEpisodeAndOnlyToday() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        // Drift since 11:48, read at 12:00: four blocks, the last ending at 12:00.
        try store.save(segment("com.example.browser", "Browser", local(21, 11, 48), minutes: 12, url: "https://video.example.net/watch"))
        try label(store, "com.example.browser", .drift, from: local(21, 0), to: local(22, 0), at: local(21, 12))
        let now = local(21, 12, 1)
        func drift(_ settings: [String: Any], date: [String] = []) throws -> [String: AnyHashable]? {
            try validated(StatusCommand.run(["status", "--json"] + date, environment: environment(directory, now: now, settings: setUp.merging(settings) { $1 })))["currentDrift"] as? [String: AnyHashable]
        }
        let episode: [String: AnyHashable] = ["start": "2026-10-21T11:48:00-04:00", "end": "2026-10-21T12:00:00-04:00", "driftBlocks": 4, "threshold": 2]
        #expect(try drift([:]) == episode.merging(["state": "notYetOffered"]) { $1 })
        #expect(try drift([StoredSettings.Key.driftPromptedEpisode: local(21, 11, 48)]) == episode.merging(["state": "offered"]) { $1 })
        #expect(try drift([StoredSettings.Key.driftThreshold: 5]) == episode.merging(["threshold": 5, "state": "belowThreshold"]) { $1 })
        #expect(try drift([StoredSettings.Key.driftCompanionEnabled: false]) == episode.merging(["state": "companionOff"]) { $1 })
        // Quiet hours from 12:01: the drift before them is confirmed but not offered now.
        #expect(try drift([StoredSettings.Key.quietHoursEnabled: true, StoredSettings.Key.quietHoursStart: 12 * 60 + 1, StoredSettings.Key.quietHoursEnd: 13 * 60])
                == episode.merging(["state": "suppressed"]) { $1 })
        // A focus window started at 12:00 settles what came before it, so there is no current episode.
        #expect(try drift([StoredSettings.Key.focusWindowStart: local(21, 12), StoredSettings.Key.focusWindowEnd: local(21, 12, 25)]) == nil)
        #expect(try drift([:], date: ["--date", "2026-10-20"]) == nil)
    }
}

// MARK: Dates and time zones

@Suite struct StatusDateTests {
    /// Six minutes from 23:57 to 00:03 New York time, across midnight into October 22.
    private func acrossMidnight() throws -> URL {
        let directory = temporaryDirectory()
        try ActivityStore(directory: directory).save(segment("com.example.editor", "Editor", local(21, 23, 57), minutes: 6))
        return directory
    }

    private func summary(_ directory: URL, _ arguments: [String] = [], now: Date, zone: TimeZone = newYork) throws -> [String: Any] {
        try validated(StatusCommand.run(["status", "--json"] + arguments, environment: environment(directory, now: now, zone: zone)))
    }

    @Test func todayTurnsOverAtLocalMidnight() throws {
        let directory = try acrossMidnight()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try summary(directory, now: local(21, 23, 59))
        #expect(before["date"] as? String == "2026-10-21")
        #expect((before["totals"] as? [String: Int])?["recorded"] == 180)
        let after = try summary(directory, now: local(22, 0, 1))
        #expect(after["date"] as? String == "2026-10-22")
        #expect((after["totals"] as? [String: Int])?["recorded"] == 180)
        #expect(after["day"] as? [String: AnyHashable] == ["start": "2026-10-22T00:00:00-04:00", "end": "2026-10-23T00:00:00-04:00", "isToday": true])
        let yesterday = try summary(directory, ["--date", "2026-10-21"], now: local(22, 0, 1))
        #expect((yesterday["totals"] as? [String: Int])?["recorded"] == 180)
        #expect(yesterday["day"] as? [String: AnyHashable] == ["start": "2026-10-21T00:00:00-04:00", "end": "2026-10-22T00:00:00-04:00", "isToday": false])
    }

    @Test func theDayIsTheTimeZonesDay() throws {
        let directory = try acrossMidnight()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 00:01 in New York is 21:01 the evening before in Los Angeles, where both blocks fall on October 21.
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let json = try summary(directory, now: local(22, 0, 1), zone: losAngeles)
        #expect(json["date"] as? String == "2026-10-21")
        #expect(json["timeZone"] as? String == "America/Los_Angeles")
        #expect(json["observedAt"] as? String == "2026-10-21T21:01:00-07:00")
        #expect((json["totals"] as? [String: Int])?["recorded"] == 360)
        // --date names a day in the time zone too: October 22 in Tokyo ends at 11:00 New York time, before either block.
        let tokyo = try summary(directory, ["--date", "2026-10-22"], now: local(22, 0, 1), zone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect((tokyo["totals"] as? [String: Int])?["recorded"] == 360)
        #expect((tokyo["day"] as? [String: Any])?["start"] as? String == "2026-10-22T00:00:00+09:00")
    }

    @Test func aDayTheClocksGoBackIsTwentyFiveHours() throws {
        let directory = try acrossMidnight()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = try summary(directory, ["--date", "2026-11-01"], now: local(21, 12))
        #expect(json["day"] as? [String: AnyHashable] == ["start": "2026-11-01T00:00:00-04:00", "end": "2026-11-02T00:00:00-05:00", "isToday": false])
    }

    @Test func malformedArgumentsAreUsageErrors() throws {
        let env = environment(nil, now: local(21, 12))
        for arguments in [[], ["status", "--date"], ["status", "--date", "2026-02-30"], ["status", "--date", "2026-2-03"], ["status", "--date", "tomorrow"],
                          ["status", "--date=2026-13-01"], ["status", "--date", "２０２６-10-21"], ["status", "--verbose"], ["serve"], ["--version", "status"]] {
            let output = StatusCommand.run(arguments, environment: env)
            #expect(output.exitCode == .usage, "\(arguments)")
            #expect(output.standardOutput.isEmpty, "\(arguments)")
            #expect(output.standardError.contains("Usage: point-in-time status"), "\(arguments)")
        }
        #expect(StatusCommand.run(["--version"], environment: env) == .init(standardOutput: "point-in-time 0.1.0 (1)\n", standardError: "", exitCode: .ok))
        #expect(StatusCommand.day("2028-02-29") == DateComponents(year: 2028, month: 2, day: 29))
        #expect(StatusCommand.day("2026-02-29") == nil)
    }
}

// MARK: Store access

@Suite struct StatusStoreTests {
    @Test func theReadConnectionCannotWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try seedWorkday(store)
        let path = store.databaseURL.path
        for mode in [SQLiteConnection.ReadOnlyMode.sharedMemoryReadOnly, .sharedMemoryWritable] {
            let connection = try SQLiteConnection(readingOnly: path, mode)
            #expect(try StoreSnapshot.read(connection, from: local(21, 0), to: local(22, 0)).blocks.count == 16)
            #expect(throws: StoreError.self) { try connection.execute("DELETE FROM segments") }
            do {
                try connection.execute("INSERT INTO schema_version (version, applied_at) VALUES (9, 0)")
                Issue.record("A read-only connection wrote")
            } catch {
                #expect(String(describing: error).contains("readonly"))
            }
        }
        #expect(try store.segmentCount() == 3)
        #expect(try store.schemaVersion() == 2)
    }

    @Test func readingChangesNoFileWhileTheAppIsOpenOrAfterItQuits() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ActivityStore? = try ActivityStore(directory: directory)
        try seedWorkday(try #require(store))
        let env = environment(directory, now: local(21, 12))
        // Open: the rows are only in the WAL, which the command reads through its index without writing either.
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("activity.sqlite-wal").path))
        let before = try fingerprint(directory)
        Thread.sleep(forTimeInterval: 0.02)
        let open = StatusCommand.run(["status", "--json", "--date", "2026-10-21"], environment: env)
        #expect(open.exitCode == .ok)
        #expect((try object(open)["totals"] as? [String: Int])?["recorded"] == 2_880)
        #expect(try fingerprint(directory) == before)
        // Quit: the last connection checkpoints the WAL; macOS's SQLite may leave the emptied WAL and its index behind.
        store = nil
        func readsWithoutChanges() throws {
            let before = try fingerprint(directory)
            Thread.sleep(forTimeInterval: 0.02)
            let closed = StatusCommand.run(["status", "--json", "--date", "2026-10-21"], environment: env)
            #expect(closed.exitCode == .ok)
            #expect(closed.standardOutput == open.standardOutput)
            #expect(try fingerprint(directory) == before)
        }
        try readsWithoutChanges()
        // With no WAL or index at all, the main file is read alone and nothing is created beside it.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent("activity.sqlite" + suffix)) }
        try readsWithoutChanges()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["activity.sqlite"])
    }

    @Test func theCommandSeesWritesTheAppMakesWhileItReads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let env = environment(directory, now: local(21, 12))
        func recorded() throws -> Int? {
            let output = StatusCommand.run(["status", "--json", "--date", "2026-10-21"], environment: env)
            #expect(output.exitCode == .ok, "\(output.standardOutput)")
            return (try object(output)["totals"] as? [String: Int])?["recorded"]
        }
        for minute in 0..<20 {
            try store.save(segment("com.example.editor", "Editor", local(21, 9, minute), minutes: 1))
            #expect(try recorded() == (minute + 1) * 60)
        }
    }

    @Test func aMissingStoreIsReportedAndNothingIsCreated() throws {
        let directory = temporaryDirectory()
        let output = StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12)))
        #expect(output.exitCode == .storeMissing)
        #expect(output.exitCode.rawValue == 3)
        let json = try validated(output)
        #expect(json["store"] as? [String: AnyHashable] == ["state": "missing", "schemaVersion": NSNull()])
        #expect((json["errors"] as? [[String: String]])?.map { $0["code"] } == ["store_missing"])
        #expect(json["totals"] is NSNull)
        #expect(json["focusPercent"] is NSNull)
        #expect((json["tracking"] as? [String: Any])?["state"] as? String == "on")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let text = StatusCommand.run(["status"], environment: environment(directory, now: local(21, 12)))
        #expect(text.exitCode == .storeMissing)
        #expect(text.standardError.contains("No activity store was found"))
        let noFolder = StatusCommand.run(["status", "--json"], environment: environment(nil, now: local(21, 12)))
        #expect(noFolder.exitCode == .storeUnreadable)
        try validated(noFolder)
    }

    @Test func aNewerSchemaIsRefusedWithoutChangingTheStore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try seedWorkday(store)
        let writer = try SQLiteConnection(path: store.databaseURL.path)
        try writer.execute("INSERT INTO schema_version (version, applied_at) VALUES (3, 0)")
        // Leave frames in the WAL, as a newer app that is running would.
        let before = try fingerprint(directory)
        let output = StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12)))
        #expect(output.exitCode == .newerSchema)
        #expect(output.exitCode.rawValue == 4)
        let json = try validated(output)
        #expect(json["store"] as? [String: AnyHashable] == ["state": "newerSchema", "schemaVersion": 3])
        #expect((json["errors"] as? [[String: String]])?.map { $0["code"] } == ["store_newer_schema"])
        #expect(json["totals"] is NSNull)
        #expect(try fingerprint(directory) == before)
    }

    @Test func aStoreHeldExclusivelyIsReportedAsLocked() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The app has quit; another process then holds the store exclusively.
        try seedWorkday(ActivityStore(directory: directory))
        let holder = try SQLiteConnection(path: directory.appendingPathComponent("activity.sqlite").path)
        try holder.execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; INSERT INTO block_revision (value) VALUES (0);")
        defer { try? holder.execute("ROLLBACK") }
        let started = ContinuousClock.now
        let output = StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12)))
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(output.exitCode == .storeLocked)
        #expect(output.exitCode.rawValue == 5)
        let json = try validated(output)
        #expect(json["store"] as? [String: AnyHashable] == ["state": "locked", "schemaVersion": NSNull()])
        #expect((json["errors"] as? [[String: String]])?.map { $0["code"] } == ["store_locked"])
    }

    @Test func aDamagedOrOutdatedStoreIsUnreadable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("activity.sqlite")
        try Data("not a database, just some text that is long enough to have a header".utf8).write(to: path)
        let damaged = StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12)))
        #expect(damaged.exitCode == .storeUnreadable)
        #expect(damaged.exitCode.rawValue == 6)
        #expect((try validated(damaged)["errors"] as? [[String: String]])?.map { $0["code"] } == ["store_unreadable"])
        // A store from before classification (schema 1) is not migrated by a reader.
        try FileManager.default.removeItem(at: path)
        let writer = try SQLiteConnection(path: path.path)
        try writer.execute("CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL); INSERT INTO schema_version VALUES (1, 0);")
        try writer.execute(try #require(ActivityStore.migrations[1]))
        let outdated = StatusCommand.run(["status", "--json"], environment: environment(directory, now: local(21, 12)))
        #expect(outdated.exitCode == .storeUnreadable)
        let json = try validated(outdated)
        #expect(json["store"] as? [String: AnyHashable] == ["state": "olderSchema", "schemaVersion": 1])
        #expect((json["errors"] as? [[String: String]])?.map { $0["code"] } == ["store_older_schema"])
    }
}

@Suite struct StoredSettingsTests {
    @Test func missingKeysReadAsTheAppsDefaults() {
        let settings = StoredSettings([:])
        #expect(!settings.onboardingCompleted && !settings.trackingEnabled && settings.pausedUntil == nil)
        #expect(settings.provider == .off)
        #expect(settings.driftRule == DriftRule(enabled: true, threshold: 2, quietHours: nil))
        #expect(settings.quietStartMinute == 22 * 60 && settings.quietEndMinute == 7 * 60)
        #expect(settings.companionState == CompanionState())
    }

    @Test func storedValuesReadAsUserDefaultsReadsThem() throws {
        let suite = "pit-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("YES", forKey: StoredSettings.Key.trackingEnabled)
        defaults.set(9, forKey: StoredSettings.Key.driftThreshold)
        defaults.set(true, forKey: StoredSettings.Key.quietHoursEnabled)
        defaults.set(60, forKey: StoredSettings.Key.quietHoursStart)
        defaults.set("openRouter", forKey: StoredSettings.Key.classificationProvider)
        defaults.set(false, forKey: StoredSettings.Key.driftCompanionEnabled)
        defaults.set(local(21, 9), forKey: StoredSettings.Key.focusWindowStart)
        defaults.set(local(21, 8), forKey: StoredSettings.Key.focusWindowEnd)
        let settings = StoredSettings { defaults.object(forKey: $0) }
        #expect(settings.trackingEnabled == defaults.bool(forKey: StoredSettings.Key.trackingEnabled))
        #expect(settings.driftRule == DriftRule(enabled: false, threshold: 5, quietHours: QuietHours(startMinute: 60, endMinute: 7 * 60)))
        #expect(settings.provider == .openRouter)
        // An end before the start is an empty window, as the app reads it.
        #expect(settings.companionState.focusWindow == DateInterval(start: local(21, 9), end: local(21, 9)))
    }
}
