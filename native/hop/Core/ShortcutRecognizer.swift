/// A keyboard event as the event tap sees it, reduced to what the switch needs.
public struct KeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown
        case keyUp
        /// A modifier key went down or up; `modifiers` is the new set.
        case flagsChanged
    }

    public var kind: Kind
    public var keyCode: UInt16
    /// The modifiers held when the event happened. Bits outside `ModifierMask.all` are ignored.
    public var modifiers: ModifierMask

    public init(_ kind: Kind, keyCode: UInt16, modifiers: ModifierMask = []) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }
}

/// What reaches the tap: a keyboard event, or the system's notice that it disabled the tap.
public enum TapInput: Sendable, Equatable {
    case key(KeyEvent)
    /// The system disabled the tap because a callback took too long or because of user input (secure input, for
    /// example). Key events may have been missed, including the release of the holding modifier.
    case tapDisabled
}

/// What the tap does with an event.
public enum Disposition: Sendable, Equatable {
    /// Deliver the event unchanged.
    case pass
    /// Drop the event: it belongs to a switch, so no app sees it.
    case swallow
}

/// The classifier's verdict on one input.
public struct Classification: Sendable, Equatable {
    public var disposition: Disposition
    /// The event to feed the session, if the input means anything to it.
    public var event: SwitchSession.Event?

    public init(_ disposition: Disposition, _ event: SwitchSession.Event? = nil) {
        self.disposition = disposition
        self.event = event
    }

    public static let pass = Classification(.pass)
}

/// Decides, for one input and the current session, whether the tap swallows the event and what it means to the
/// session. Only a press that starts a switch and key presses that belong to an active switch are swallowed; modifier
/// changes and key-ups always pass here, so apps never see a modifier stuck down.
public enum EventClassifier {
    public static func classify(_ input: TapInput, session: SwitchSession, shortcut: Shortcut) -> Classification {
        guard case let .key(key) = input else {
            return session.isActive ? Classification(.pass, .interrupted) : .pass
        }
        return session.isActive ? classifyActive(key, shortcut: shortcut) : classifyIdle(key, session: session, shortcut: shortcut)
    }

    private static func classifyIdle(_ key: KeyEvent, session: SwitchSession, shortcut: Shortcut) -> Classification {
        guard key.kind == .keyDown, key.keyCode == shortcut.keyCode, session.canStart else { return .pass }
        switch key.modifiers {
        case shortcut.forwardModifiers: return Classification(.swallow, .trigger(.forward))
        case shortcut.backwardModifiers: return Classification(.swallow, .trigger(.backward))
        default: return .pass
        }
    }

    private static func classifyActive(_ key: KeyEvent, shortcut: Shortcut) -> Classification {
        // The holding modifier is gone: it was released, possibly without a flags event the tap saw. The release
        // ends the switch; the event itself is the user's next keystroke and goes through.
        guard key.modifiers.contains(shortcut.holdModifier) else { return Classification(.pass, .modifierReleased) }
        switch key.kind {
        case .flagsChanged, .keyUp:
            // A key-up is swallowed exactly when its key-down was, which only ShortcutRecognizer knows: a key held
            // since before the switch started must still reach its app on release.
            return .pass
        case .keyDown:
            switch key.keyCode {
            case shortcut.keyCode:
                return Classification(.swallow, .step(key.modifiers.contains(.shift) ? .backward : .forward))
            case KeyCode.leftArrow: return Classification(.swallow, .step(.backward))
            case KeyCode.rightArrow: return Classification(.swallow, .step(.forward))
            case KeyCode.escape: return Classification(.swallow, .escape)
            default: return .pass
            }
        }
    }
}

/// The session plus the classifier, as the event tap drives them: classifies each input, applies the resulting
/// event, and reports what to do with the input and how a session ended.
///
/// It swallows the key-up of every key-down it swallowed, even after the session has ended (Tab released after ⌥,
/// for example), and no other key-up, so an app never receives a key-up without its key-down or misses the release
/// of a key it saw go down.
public struct ShortcutRecognizer: Sendable {
    public struct Result: Sendable, Equatable {
        public var disposition: Disposition
        /// How the session ended, when this input ended it.
        public var outcome: SwitchSession.Outcome?

        public init(disposition: Disposition, outcome: SwitchSession.Outcome?) {
            self.disposition = disposition
            self.outcome = outcome
        }
    }

    public private(set) var session: SwitchSession
    public var shortcut: Shortcut
    private var swallowedKeyDowns: Set<UInt16> = []

    public init(shortcut: Shortcut, windowCount: Int = 0) {
        self.shortcut = shortcut
        session = SwitchSession(count: windowCount)
    }

    public mutating func handle(_ input: TapInput) -> Result {
        if case let .key(key) = input, key.kind == .keyUp, swallowedKeyDowns.remove(key.keyCode) != nil {
            return Result(disposition: .swallow, outcome: nil)
        }
        if case .tapDisabled = input {
            // Key-ups may have been missed; forget them rather than swallow a later, unrelated key-up.
            swallowedKeyDowns.removeAll()
        }
        let classification = EventClassifier.classify(input, session: session, shortcut: shortcut)
        if case let .key(key) = input, key.kind == .keyDown, classification.disposition == .swallow {
            swallowedKeyDowns.insert(key.keyCode)
        }
        let outcome = classification.event.flatMap { session.handle($0) }
        return Result(disposition: classification.disposition, outcome: outcome)
    }

    /// Reports a new window count to the session; returns `.cancel` if that ended an active session.
    public mutating func listChanged(count: Int) -> SwitchSession.Outcome? {
        session.handle(.listChanged(count: count))
    }

    /// Ends any active session because the tap is going away, and forgets pending key-ups.
    public mutating func reset() -> SwitchSession.Outcome? {
        swallowedKeyDowns.removeAll()
        return session.handle(.interrupted)
    }
}
