import HopCore
import XCTest

final class AccessibilityGateTests: XCTestCase {
    func testTheFirstSampleAlwaysReportsAChange() {
        var trusted = AccessibilityGate()
        XCTAssertEqual(trusted.update(trusted: true), .granted)
        var untrusted = AccessibilityGate()
        XCTAssertEqual(untrusted.update(trusted: false), .revoked)
    }

    func testGrantAndRevokeAreReportedOnceEach() {
        var gate = AccessibilityGate()
        _ = gate.update(trusted: false)
        XCTAssertNil(gate.update(trusted: false))
        XCTAssertEqual(gate.update(trusted: true), .granted)
        XCTAssertNil(gate.update(trusted: true))
        XCTAssertEqual(gate.update(trusted: false), .revoked)
        XCTAssertEqual(gate.isTrusted, false)
    }

    func testOnboardingOpensUnaskedOnlyOnTheFirstUntrustedLaunch() {
        XCTAssertTrue(AccessibilityGate.showsOnboardingAtLaunch(trusted: false, onboardingShownBefore: false))
        XCTAssertFalse(AccessibilityGate.showsOnboardingAtLaunch(trusted: false, onboardingShownBefore: true))
        XCTAssertFalse(AccessibilityGate.showsOnboardingAtLaunch(trusted: true, onboardingShownBefore: false))
    }
}
