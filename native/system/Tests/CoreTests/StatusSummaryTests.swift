import SystemCore
import XCTest

final class StatusSummaryTests: XCTestCase {
    func testMenuBarShowsMachineCPUShareAndMemoryPressure() throws {
        // Half the host's ticks were busy.
        let summary = StatusSummary(snapshot: try snapshot(busyTicks: 400, idleTicks: 400), memory: memory(level: 4))

        XCTAssertEqual(summary.title, "50%")
        XCTAssertEqual(summary.pressure, .critical)
        XCTAssertEqual(summary.cpuRow(logicalCoreCount: 8), "CPU: 50% of 8 cores")
        XCTAssertEqual(summary.pressureRow, "Memory pressure: Critical")
        XCTAssertEqual(summary.accessibilityLabel, "Subset System: CPU 50%, memory pressure critical")
    }

    func testBeforeTwoSamplesCPUIsNotShownAsZero() {
        let summary = StatusSummary(snapshot: nil, memory: nil)

        XCTAssertEqual(summary.title, "–")
        XCTAssertEqual(summary.cpuRow(logicalCoreCount: nil), "CPU: not measured yet")
        XCTAssertEqual(summary.pressureRow, "Memory pressure: Unknown")
        XCTAssertEqual(summary.accessibilityLabel, "Subset System: CPU not measured yet, memory pressure unknown")
    }

    func testAFailingSampleHidesTheLastCPUFigureUntilASampleSucceeds() throws {
        let last = try snapshot(busyTicks: 300, idleTicks: 100)

        let failing = StatusSummary(snapshot: last, memory: memory(level: 1), samplingFailed: true)
        XCTAssertNil(failing.cpuPercent)
        XCTAssertEqual(failing.title, "–")
        XCTAssertEqual(failing.cpuRow(logicalCoreCount: 8), "CPU: unavailable, sampling failed")
        XCTAssertEqual(failing.accessibilityLabel, "Subset System: CPU unavailable, sampling failed, memory pressure normal")

        let recovered = StatusSummary(snapshot: last, memory: memory(level: 1))
        XCTAssertEqual(recovered.title, "75%")
    }

    /// The second of two samples whose host ticks advanced by the given amounts.
    private func snapshot(busyTicks: UInt32, idleTicks: UInt32) throws -> ProcessSnapshot {
        let timebase = MachTimebase(numer: 1, denom: 1)
        var sampler = Sampler(
            source: FixtureProcessSource([
                RawProcessSample(timestamp: 0, timebase: timebase, processes: []),
                RawProcessSample(timestamp: 1_000_000_000, timebase: timebase, processes: [])
            ]),
            hostCPU: FixtureHostCPUSource([
                HostCPUTicks(user: 0, system: 0, idle: 0, nice: 0),
                HostCPUTicks(user: busyTicks, system: 0, idle: idleTicks, nice: 0)
            ]),
            logicalCoreCount: 8
        )
        _ = try sampler.sample()
        return try sampler.sample()
    }

    private func memory(level: Int32) -> SystemMemory {
        SystemMemory(raw: RawSystemMemory(
            pressureLevel: withUnsafeBytes(of: level) { Array($0) },
            swapUsage: nil,
            memorySize: nil,
            vmStatistics: nil,
            pageSize: nil
        ))
    }
}
