import Foundation
import Testing
@testable import TimerApp
@testable import TimerCore

private func state(schemaVersion: Int) -> EventSubscription.Update {
    .event(ServerSentEvent(event: "state", data: #"{"structuredContent":{"schemaVersion":\#(schemaVersion),"observedAt":0,"timers":[]},"text":"","viewId":"subset.timer.board@\#(schemaVersion)"}"#))
}

@MainActor
struct StateTests {
    @Test func anUnreadableStateIsItsOwnProblemUntilTheNextReadableOne() {
        let controller = TimerController()
        controller.handle(.connected)
        controller.handle(state(schemaVersion: 2))
        #expect(controller.connectionProblem == nil)
        #expect(controller.stateProblem == DaemonError.unsupportedSchema(2).localizedDescription)
        controller.handle(.event(ServerSentEvent(event: "state", data: "{")))
        #expect(controller.connectionProblem == nil)
        #expect(controller.stateProblem != nil)
        controller.handle(state(schemaVersion: 1))
        #expect(controller.stateProblem == nil)
        #expect(controller.connectionProblem == nil)
    }

    @Test func aDisconnectIsAConnectionProblemUntilTheStreamReconnects() {
        let controller = TimerController()
        controller.handle(.disconnected(error: nil, retryIn: 1))
        #expect(controller.connectionProblem == "The Timer daemon closed the connection.")
        #expect(controller.stateProblem == nil)
        controller.handle(.connected)
        #expect(controller.connectionProblem == nil)
    }
}
