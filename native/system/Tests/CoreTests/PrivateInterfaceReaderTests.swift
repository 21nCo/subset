import Darwin
@testable import SystemCore
import XCTest

/// The two private-interface adapters, with the symbol missing or the call failing. Their fakes are C functions, so
/// they cannot capture state; each scenario is its own function.
final class PrivateInterfaceReaderTests: XCTestCase {
    private typealias Responsible = LiveResponsibleProcessReader.Function
    private typealias Coalition = LiveCoalitionReader.Function

    func testTheLiveResolverFindsNoUnknownSymbol() {
        XCTAssertNil(SymbolResolver.live.resolve("subset_system_no_such_symbol"))
        XCTAssertNotNil(SymbolResolver.live.resolve("proc_pidinfo"))
    }

    func testAMissingResponsibilitySymbolIsUnavailableWithItsName() {
        let reader = LiveResponsibleProcessReader(resolver: SymbolResolver { _ in nil })

        let signal = reader.responsibleProcess(of: getpid())

        XCTAssertEqual(signal, .unavailable(.symbolMissing("responsibility_get_pid_responsible_for_pid"), source: .responsibility))
        XCTAssertEqual(signal.failure?.reason, "responsibility_get_pid_responsible_for_pid is not available in this macOS")
    }

    func testAFailedResponsibilityCallIsUnavailableWithItsErrno() {
        let denied: Responsible = { _ in errno = EPERM; return -1 }
        let gone: Responsible = { _ in errno = ESRCH; return -1 }
        let invalid: Responsible = { _ in errno = EINVAL; return -1 }
        let zero: Responsible = { _ in errno = 0; return 0 }
        let found: Responsible = { pid in errno = 0; return pid + 1 }

        XCTAssertEqual(responsible(denied), .unavailable(.denied, source: .responsibility))
        XCTAssertEqual(responsible(gone), .unavailable(.processExited, source: .responsibility))
        XCTAssertEqual(responsible(invalid), .unavailable(.systemError(EINVAL), source: .responsibility))
        XCTAssertEqual(responsible(zero), .unavailable(.unexpectedResult("returned pid 0"), source: .responsibility))
        XCTAssertEqual(responsible(found), .value(51, source: .responsibility))
    }

    func testAMissingProcPidinfoSymbolLeavesTheCoalitionUnavailable() {
        let reader = LiveCoalitionReader(resolver: SymbolResolver { _ in nil })

        XCTAssertEqual(reader.coalition(of: getpid()), .unavailable(.symbolMissing("proc_pidinfo"), source: .coalitionInfo))
    }

    func testAFailedOrMalformedCoalitionReadIsUnavailableWithItsReason() {
        // A macOS that does not know the flavor rejects it; libproc reports failure as 0 with errno set.
        let unknownFlavor: Coalition = { _, _, _, _, _ in errno = EINVAL; return 0 }
        let denied: Coalition = { _, _, _, _, _ in errno = EPERM; return 0 }
        let short: Coalition = { _, _, _, _, _ in errno = 0; return 16 }
        let noCoalition: Coalition = { _, _, _, _, size in errno = 0; return size }

        XCTAssertEqual(coalition(unknownFlavor), .unavailable(.systemError(EINVAL), source: .coalitionInfo))
        XCTAssertEqual(coalition(denied), .unavailable(.denied, source: .coalitionInfo))
        XCTAssertEqual(coalition(short), .unavailable(.unexpectedResult("returned 16 bytes, expected 40"), source: .coalitionInfo))
        XCTAssertEqual(coalition(noCoalition), .unavailable(.unexpectedResult("reported no resource coalition"), source: .coalitionInfo))
    }

    func testTheCoalitionIsTheResourceCoalitionOfTheRequestedFlavor() {
        let found: Coalition = { pid, flavor, _, buffer, size in
            guard flavor == 20, size == 40, let words = buffer?.assumingMemoryBound(to: UInt64.self) else {
                errno = EINVAL
                return 0
            }
            words[0] = UInt64(pid) * 1000
            words[1] = 7
            return size
        }

        XCTAssertEqual(coalition(found), .value(50_000, source: .coalitionInfo))
    }

    private func responsible(_ function: Responsible) -> Signal<Int32> {
        let address = Int(bitPattern: unsafeBitCast(function, to: UnsafeMutableRawPointer.self))
        return LiveResponsibleProcessReader(resolver: resolver(LiveResponsibleProcessReader.symbol, address))
            .responsibleProcess(of: 50)
    }

    private func coalition(_ function: Coalition) -> Signal<UInt64> {
        let address = Int(bitPattern: unsafeBitCast(function, to: UnsafeMutableRawPointer.self))
        return LiveCoalitionReader(resolver: resolver(LiveCoalitionReader.symbol, address)).coalition(of: 50)
    }

    /// Resolves only `symbol`, to the function at `address`.
    private func resolver(_ symbol: String, _ address: Int) -> SymbolResolver {
        SymbolResolver { $0 == symbol ? UnsafeMutableRawPointer(bitPattern: address) : nil }
    }
}
