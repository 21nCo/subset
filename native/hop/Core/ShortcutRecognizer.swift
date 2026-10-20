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
    /// Whether this key-down is the keyboard's auto-repeat of a key held down, not a new press.
    public var isRepeat: Bool
    /// The character the key types on the current keyboard layout without modifiers (ASCII lowercased), or nil when
    /// it is unknown or the key types none. Operation keys (⌘W) match it, so they follow the layout as menu shortcuts
    /// do; only a key without an ASCII character (a non-Latin layout, or none) falls back to its US position.
    public var character: Character?

    public init(
        _ kind: Kind,
        keyCode: UInt16,
        modifiers: ModifierMask = [],
        isRepeat: Bool = false,
        character: Character? = nil
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
        self.isRepeat = kind == .keyDown && isRepeat
        self.character = character.map { $0.isASCII ? Character($0.lowercased()) : $0 }
    }
}

/// The keys that act on the selected window while a switch is active, pressed with ⌘ and the holding modifier.
public enum OperationKey {
    /// The operation for a key: by the ASCII character the layout gives it, so a Latin layout's punctuation on the US
    /// M, W, H or Q position (AZERTY's comma, Dvorak's comma and apostrophe) matches nothing; by its US key position
    /// only when the layout gives no ASCII character (a Cyrillic layout, for example, or a dead key).
    public static func operation(character: Character?, keyCode: UInt16) -> WindowOperation? {
        guard let character, character.isASCII else { return byKeyCode[keyCode] }
        return byLetter[character]
    }

    private static let byLetter: [Character: WindowOperation] = ["m": .minimize, "w": .close, "h": .hideApp, "q": .quitApp]
    /// The US layout positions of M, W, H and Q.
    private static let byKeyCode: [UInt16: WindowOperation] = [0x2E: .minimize, 0x0D: .close, 0x04: .hideApp, 0x0C: .quitApp]
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
///
/// Modifiers match exactly: the shortcut starts or steps a switch only with the holding modifier alone (forward) or
/// with ⇧ (backward); while a switch is active the arrows and Esc count only with the holding modifier, optionally plus
/// ⇧, and the operation keys (M, W, H, Q) only with the holding modifier plus ⌘. Any other modifier set (⌥⌘Tab, ⌥⌃→,
/// ⌥⇧⌘W) passes and changes nothing.
///
/// The classifier sees one event at a time. Which press a key-up or an auto-repeat belongs to is
/// `ShortcutRecognizer`'s job.
public enum EventClassifier {
    public static func classify(_ input: TapInput, session: SwitchSession, shortcut: Shortcut) -> Classification {
        guard case let .key(key) = input else {
            return session.isActive ? Classification(.pass, .interrupted) : .pass
        }
        return session.isActive ? classifyActive(key, shortcut: shortcut) : classifyIdle(key, shortcut: shortcut)
    }

    private static func classifyIdle(_ key: KeyEvent, shortcut: Shortcut) -> Classification {
        guard key.kind == .keyDown, key.keyCode == shortcut.keyCode else { return .pass }
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
        guard key.kind == .keyDown else { return .pass }
        if key.modifiers == shortcut.holdModifier.union(.command) {
            guard let operation = OperationKey.operation(character: key.character, keyCode: key.keyCode) else { return .pass }
            return Classification(.swallow, .operation(operation))
        }
        guard key.modifiers == shortcut.forwardModifiers || key.modifiers == shortcut.backwardModifiers else { return .pass }
        switch key.keyCode {
        case shortcut.keyCode:
            return Classification(.swallow, .step(key.modifiers == shortcut.backwardModifiers ? .backward : .forward))
        case KeyCode.leftArrow: return Classification(.swallow, .step(.backward))
        case KeyCode.rightArrow: return Classification(.swallow, .step(.forward))
        case KeyCode.upArrow: return Classification(.swallow, .row(.up))
        case KeyCode.downArrow: return Classification(.swallow, .row(.down))
        case KeyCode.escape: return Classification(.swallow, .escape)
        default: return .pass
        }
    }
}

/// The session plus the classifier, as the event tap drives them: classifies each input, applies the resulting
/// event, and reports what to do with the input and how a session ended.
///
/// It decides once per physical press. A new key-down is classified and its disposition is remembered until the key
/// goes up; the press's auto-repeats and its key-up get the same disposition, even after the session has ended (Tab
/// released after ⌥, for example). So an app sees all of a press or none of it: it never receives a key-up without
/// its key-down, or misses the release of a key it saw go down. A swallowed press's repeats keep moving the selection of
/// an active switch (holding Tab or ↓ moves on) but never start or cancel one or repeat an operation; a press the app
/// saw never moves, cancels or acts in a switch.
/// Any key event without the holding modifier still ends an active switch, because it shows the modifier is up.
public struct ShortcutRecognizer: Sendable {
    public struct Result: Sendable, Equatable {
        public var disposition: Disposition
        /// The event the session took from this input, for the host to apply to the switcher: a trigger that started
        /// a session, or a step, row move or operation in an active one.
        public var event: SwitchSession.Event?
        /// How the session ended, when this input ended it.
        public var outcome: SwitchSession.Outcome?

        public init(disposition: Disposition, event: SwitchSession.Event? = nil, outcome: SwitchSession.Outcome?) {
            self.disposition = disposition
            self.event = event
            self.outcome = outcome
        }
    }

    public private(set) var session: SwitchSession
    public var shortcut: Shortcut
    /// The disposition of each key's current press, from its key-down until its key-up.
    private var presses: [UInt16: Disposition] = [:]

    public init(shortcut: Shortcut) {
        self.shortcut = shortcut
        session = SwitchSession()
    }

    public mutating func handle(_ input: TapInput) -> Result {
        let classification = EventClassifier.classify(input, session: session, shortcut: shortcut)
        let disposition: Disposition
        var event = classification.event
        switch input {
        case .tapDisabled:
            // Key-ups may have been missed; forget the presses rather than swallow a later, unrelated key-up.
            presses.removeAll()
            disposition = classification.disposition
        case let .key(key) where key.kind == .flagsChanged:
            disposition = classification.disposition
        case let .key(key) where key.kind == .keyUp:
            disposition = presses.removeValue(forKey: key.keyCode) ?? .pass
        case let .key(key) where key.isRepeat:
            // A press that began before the tap saw it belongs to its app.
            disposition = presses[key.keyCode] ?? .pass
            switch event {
            case .step where disposition == .swallow, .row where disposition == .swallow, .modifierReleased: break
            default: event = nil
            }
        case let .key(key):
            // A new press, even of a key whose key-up was never seen, which replaces that stale press.
            disposition = classification.disposition
            presses[key.keyCode] = disposition
        }
        guard let event else { return Result(disposition: disposition, outcome: nil) }
        let (accepted, outcome) = session.handle(event)
        let applied: SwitchSession.Event? = switch event {
        case .trigger, .step, .row, .operation: accepted ? event : nil
        case .modifierReleased, .escape, .interrupted: nil
        }
        return Result(disposition: disposition, event: applied, outcome: outcome)
    }

    /// Ends an active session that the switcher ended by itself (a click on a window), keeping the presses in
    /// progress so their key-ups keep their dispositions. Returns whether a session was active.
    @discardableResult
    public mutating func endSession() -> Bool {
        session.end()
    }

    /// Ends any active session because the tap is going away, and forgets the presses in progress.
    public mutating func reset() -> SwitchSession.Outcome? {
        presses.removeAll()
        return session.handle(.interrupted).outcome
    }
}
