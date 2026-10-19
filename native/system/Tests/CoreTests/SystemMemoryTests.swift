import Darwin
import SystemCore
import XCTest

/// Values recorded on a 16 GB Apple silicon Mac under memory pressure (`sysctl`, `vm_stat`; 16 KB pages).
final class SystemMemoryTests: XCTestCase {
    private let pageSize: UInt64 = 16_384

    func testParsesRecordedSysctlAndVMStatistics() {
        let memory = SystemMemory(raw: recorded())

        XCTAssertEqual(memory.pressure, .warning)
        XCTAssertEqual(memory.physicalMemory, 17_179_869_184)
        XCTAssertEqual(memory.swapTotal, 13_958_643_712)
        XCTAssertEqual(memory.swapUsed, 12_399_210_496)
        // Anonymous pages minus purgeable pages, wired pages, and pages the compressor occupies.
        XCTAssertEqual(memory.app, (234_531 - 13) * pageSize)
        XCTAssertEqual(memory.wired, 306_309 * pageSize)
        XCTAssertEqual(memory.compressed, 343_646 * pageSize)
        XCTAssertEqual(memory.used, (234_518 + 306_309 + 343_646) * pageSize)
    }

    func testPressureLevelsMapAndUnknownLevelsAreUnavailable() {
        XCTAssertEqual(pressure(level: 1), .normal)
        XCTAssertEqual(pressure(level: 2), .warning)
        XCTAssertEqual(pressure(level: 4), .critical)
        XCTAssertNil(pressure(level: 0))
        XCTAssertNil(pressure(level: 3))
    }

    func testMissingOrMalformedValuesAreUnavailableRatherThanZero() {
        var raw = recorded()
        raw.pressureLevel = [2, 0]
        raw.swapUsage = Array(raw.swapUsage!.dropLast())
        raw.memorySize = nil
        raw.vmStatistics = nil
        let memory = SystemMemory(raw: raw)

        XCTAssertNil(memory.pressure)
        XCTAssertNil(memory.swapUsed)
        XCTAssertNil(memory.swapTotal)
        XCTAssertNil(memory.physicalMemory)
        XCTAssertNil(memory.app)
        XCTAssertNil(memory.wired)
        XCTAssertNil(memory.compressed)
        XCTAssertNil(memory.used)

        raw = recorded()
        raw.vmStatistics?.purgeable_count = 300_000
        XCTAssertNil(SystemMemory(raw: raw).app, "more purgeable than anonymous pages is not a real state")
        raw.pageSize = 0
        XCTAssertNil(SystemMemory(raw: raw).wired)
    }

    func testLiveReadReturnsThisMacsMemory() throws {
        let memory = SystemMemory(raw: LiveSystemMemorySource().read())

        XCTAssertNotNil(memory.pressure)
        XCTAssertEqual(memory.physicalMemory, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(try XCTUnwrap(memory.wired), 0)
        XCTAssertNotNil(memory.app)
        XCTAssertNotNil(memory.compressed)
        XCTAssertNotNil(memory.swapTotal)
    }

    // MARK: - Fixtures

    private func pressure(level: Int32) -> MemoryPressure? {
        var raw = recorded()
        raw.pressureLevel = bytes(of: level)
        return SystemMemory(raw: raw).pressure
    }

    private func recorded() -> RawSystemMemory {
        var stats = vm_statistics64()
        stats.free_count = 19_515
        stats.active_count = 170_173
        stats.inactive_count = 156_380
        stats.speculative_count = 12_887
        stats.wire_count = 306_309
        stats.purgeable_count = 13
        stats.external_page_count = 104_909
        stats.internal_page_count = 234_531
        stats.total_uncompressed_pages_in_compressor = 2_165_245
        stats.compressor_page_count = 343_646
        // vm.swapusage as the kernel lays out xsw_usage: total, avail, used (UInt64), page size (UInt32), and
        // encrypted (Int32), little-endian.
        let swap = le(13_958_643_712) + le(1_559_433_216) + le(12_399_210_496) + le32(16_384) + le32(1)
        return RawSystemMemory(
            pressureLevel: le32(2),
            swapUsage: swap,
            memorySize: le(17_179_869_184),
            vmStatistics: stats,
            pageSize: pageSize
        )
    }

    private func le(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func bytes(of value: Int32) -> [UInt8] { le32(UInt32(bitPattern: value)) }
}
