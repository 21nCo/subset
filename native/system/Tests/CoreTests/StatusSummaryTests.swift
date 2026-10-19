import SystemCore
import XCTest

final class StatusSummaryTests: XCTestCase {
    func testMenuBarShowsMachineCPUShareAndMemoryPressure() throws {
        let snapshot = try snapshot(cpuSeconds: [3, 1], logicalCoreCount: 8)
        let summary = StatusSummary(snapshot: snapshot, memory: memory(level: 4))

        // 400% of eight cores is half the machine.
        XCTAssertEqual(summary.title, "50%")
        XCTAssertEqual(summary.pressure, .critical)
        XCTAssertEqual(summary.cpuRow(logicalCoreCount: 8), "CPU: 50% of 8 cores")
        XCTAssertEqual(summary.pressureRow, "Memory pressure: Critical")
        XCTAssertEqual(summary.accessibilityLabel, "Subset System: CPU 50%, memory pressure critical")
    }

    func testBeforeTwoSamplesCPUIsNotShownAsZero() {
        let summary = StatusSummary(snapshot: nil, memory: nil)

        XCTAssertEqual(summary.title, "–")
        XCTAssertEqual(summary.pressureRow, "Memory pressure: Unknown")
        XCTAssertEqual(summary.accessibilityLabel, "Subset System: CPU not measured yet, memory pressure unknown")
    }

    func testSkewAboveTheMachinesCapacityIsShownAsOneHundredPercent() throws {
        let summary = StatusSummary(snapshot: try snapshot(cpuSeconds: [1.1], logicalCoreCount: 1), memory: nil)
        XCTAssertEqual(summary.title, "100%")
    }

    /// Two samples one second apart in which each process used the given CPU seconds.
    private func snapshot(cpuSeconds: [Double], logicalCoreCount: Int) throws -> ProcessSnapshot {
        let timebase = MachTimebase(numer: 1, denom: 1)
        func records(_ seconds: [Double]) -> [RawProcessRecord] {
            seconds.enumerated().map { index, value in
                RawProcessRecord(
                    identity: ProcessIdentity(pid: Int32(index + 100), startTime: 1),
                    ppid: 1,
                    uid: 501,
                    executablePath: nil,
                    name: "p",
                    usage: .available(RawProcessUsage(physFootprint: 1, userTime: UInt64(value * 1e9), systemTime: 0, billedEnergy: 0))
                )
            }
        }
        var sampler = Sampler(source: FixtureProcessSource([
            RawProcessSample(timestamp: 0, timebase: timebase, processes: records(cpuSeconds.map { _ in 0 })),
            RawProcessSample(timestamp: 1_000_000_000, timebase: timebase, processes: records(cpuSeconds))
        ]), logicalCoreCount: logicalCoreCount)
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
