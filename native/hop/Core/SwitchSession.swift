/// The direction a switch moves through the window list: forward toward older windows, backward toward newer ones.
public enum SwitchDirection: Sendable, Equatable {
    case forward
    case backward
}

/// The direction ↑ and ↓ move the selection through the switcher's grid.
public enum RowDirection: Sendable, Equatable {
    case up
    case down
}

/// One hold-to-switch session: the shortcut starts it, further keys move the selection or act on the selected
/// window, and releasing the holding modifier ends it. Pure state; the host feeds it events from the event tap and acts
/// on the events it accepts and on how it ends.
///
/// The session only knows whether a switch is in progress. The window list and the selection belong to the switcher
/// (`SwitcherViewModel`), which the host opens when a session starts, so a switch starts even when there are no
/// windows and the switcher says so.
public struct SwitchSession: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case active
    }

    public enum Event: Sendable, Equatable {
        /// The shortcut was pressed while idle.
        case trigger(SwitchDirection)
        /// The shortcut key or ← or → was pressed while active.
        case step(SwitchDirection)
        /// ↑ or ↓ was pressed while active.
        case row(RowDirection)
        /// An operation key (⌘M, ⌘W, ⌘H, ⌘Q, with the holding modifier) was pressed while active.
        case operation(WindowOperation)
        /// The holding modifier was released.
        case modifierReleased
        /// Esc was pressed.
        case escape
        /// The host stopped receiving key events (the event tap was disabled or removed), so the release of the
        /// holding modifier may never arrive. Cancels like Esc.
        case interrupted
    }

    public enum Outcome: Sendable, Equatable {
        /// Switch to the selected window.
        case commit
        /// Leave the windows as they were.
        case cancel
    }

    public private(set) var state: State = .idle

    public init() {}

    public var isActive: Bool { state == .active }

    /// Applies one event. Returns whether the session took it (a trigger while idle, or any event while active) and,
    /// when the event ended the session, how.
    @discardableResult
    public mutating func handle(_ event: Event) -> (accepted: Bool, outcome: Outcome?) {
        switch (state, event) {
        case (.idle, .trigger):
            state = .active
            return (true, nil)
        case (.idle, _):
            return (false, nil)
        case (.active, .modifierReleased):
            state = .idle
            return (true, .commit)
        case (.active, .escape), (.active, .interrupted):
            state = .idle
            return (true, .cancel)
        case (.active, .trigger), (.active, .step), (.active, .row), (.active, .operation):
            return (true, nil)
        }
    }

    /// Ends an active session that the switcher ended by itself, such as with a click on a window; the release of the
    /// holding modifier that follows then changes nothing. Returns whether a session was active.
    @discardableResult
    public mutating func end() -> Bool {
        defer { state = .idle }
        return isActive
    }
}
