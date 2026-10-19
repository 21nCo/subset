/// The direction a switch moves through the window list: forward toward older windows, backward toward newer ones.
public enum SwitchDirection: Sendable, Equatable {
    case forward
    case backward
}

/// One hold-to-switch session: the shortcut starts it, each further press moves the selection, and releasing the
/// holding modifier ends it. Pure state; the host feeds it events from the event tap and acts on its outcomes.
///
/// Indices refer to the window list in recency order, where index 0 is the frontmost window. The session only knows
/// the list's size (`count`), which the host reports with `listChanged` whenever the list changes, idle or not.
public struct SwitchSession: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case active(selection: Int)
    }

    public enum Event: Sendable, Equatable {
        /// The shortcut was pressed while idle.
        case trigger(SwitchDirection)
        /// The shortcut key or an arrow key was pressed while active.
        case step(SwitchDirection)
        /// The holding modifier was released.
        case modifierReleased
        /// Esc was pressed.
        case escape
        /// The window list now has `count` windows.
        case listChanged(count: Int)
        /// The host stopped receiving key events (the event tap was disabled or removed), so the release of the
        /// holding modifier may never arrive. Cancels like Esc.
        case interrupted
    }

    public enum Outcome: Sendable, Equatable {
        /// Switch to the window at this index.
        case commit(index: Int)
        /// Leave the windows as they were.
        case cancel
    }

    public private(set) var state: State = .idle
    /// The number of windows in the list; never negative.
    public private(set) var count: Int

    public init(count: Int = 0) {
        self.count = max(0, count)
    }

    public var isActive: Bool {
        if case .active = state { true } else { false }
    }

    /// Whether `trigger` would start a session now: there must be a window to select.
    public var canStart: Bool { count > 0 }

    /// Applies one event and returns the outcome that ended the session, if this event ended one.
    @discardableResult
    public mutating func handle(_ event: Event) -> Outcome? {
        switch (state, event) {
        case let (.idle, .trigger(direction)):
            guard count > 0 else { return nil }
            // Forward starts on the previous window, the usual target; backward starts on the oldest one. With a
            // single window both select it.
            state = .active(selection: count == 1 ? 0 : (direction == .forward ? 1 : count - 1))
            return nil
        case let (.active(selection), .trigger(direction)), let (.active(selection), .step(direction)):
            let offset = direction == .forward ? 1 : -1
            state = .active(selection: ((selection + offset) % count + count) % count)
            return nil
        case let (.active(selection), .modifierReleased):
            state = .idle
            return .commit(index: selection)
        case (.active, .escape), (.active, .interrupted):
            state = .idle
            return .cancel
        case let (_, .listChanged(newCount)):
            count = max(0, newCount)
            guard case let .active(selection) = state else { return nil }
            if count == 0 {
                state = .idle
                return .cancel
            }
            state = .active(selection: min(selection, count - 1))
            return nil
        case (.idle, _):
            return nil
        }
    }
}
