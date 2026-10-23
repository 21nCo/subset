import AppKit
import Testing
@testable import TimerApp

@MainActor
struct EditMenuTests {
    /// The main menu carries the standard editing shortcuts with no target, so AppKit sends each one to the focused
    /// countdown field, whose field editor performs it. (A test process cannot own the key window; the live
    /// keystrokes are part of the real-Mac check.)
    @Test func editingShortcutsGoToTheFocusedField() throws {
        let edit = try #require(TimerApp.mainMenu().items.first { $0.title == "Edit" }?.submenu)
        let field = NSTextField(string: "25m")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.close() }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        for (key, action) in [("a", #selector(NSText.selectAll(_:))), ("c", #selector(NSText.copy(_:))), ("x", #selector(NSText.cut(_:))),
                              ("v", #selector(NSText.paste(_:))), ("z", Selector(("undo:")))] {
            let item = try #require(edit.items.first { $0.keyEquivalent == key }, "Command-\(key)")
            #expect(item.action == action && item.target == nil && item.keyEquivalentModifierMask == .command)
            #expect(editor.responds(to: action) || window.responds(to: action), "Command-\(key)")
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.tryToPerform(#selector(NSText.selectAll(_:)), with: nil))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 3))
    }
}
