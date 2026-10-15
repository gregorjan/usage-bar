import AppKit
import Testing
@testable import UsageBar

@MainActor
private final class EditCommandTarget: NSObject {
    var pasteCount = 0
    @objc func paste(_ sender: Any?) { pasteCount += 1 }
}

@MainActor
struct ApplicationMenuTests {
    @Test func standardEditingShortcutsUseFocusedResponder() throws {
        let main = ApplicationMenu.make()
        let edit = try #require(main.items.first { $0.title == "Edit" }?.submenu)
        let bindings = [
            ("Undo", "undo:", "z", NSEvent.ModifierFlags.command),
            ("Redo", "redo:", "z", NSEvent.ModifierFlags([.command, .shift])),
            ("Cut", "cut:", "x", .command),
            ("Copy", "copy:", "c", .command),
            ("Paste", "paste:", "v", .command),
            ("Select All", "selectAll:", "a", .command),
        ]
        for (title, selector, key, modifiers) in bindings {
            let item = try #require(edit.items.first { $0.title == title })
            #expect(item.action.map(NSStringFromSelector) == selector)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
            #expect(item.target == nil)
        }
    }

    @Test func commandVDispatchesPasteButPlainVDoesNot() throws {
        _ = NSApplication.shared
        let main = ApplicationMenu.make()
        let edit = try #require(main.items.first { $0.title == "Edit" }?.submenu)
        let paste = try #require(edit.items.first { $0.title == "Paste" })
        let target = EditCommandTarget()
        paste.target = target
        let commandV = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: .command, timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "v",
                                                    charactersIgnoringModifiers: "v", isARepeat: false,
                                                    keyCode: 9))
        #expect(main.performKeyEquivalent(with: commandV))
        #expect(target.pasteCount == 1)
        let plainV = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                  modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "v",
                                                  charactersIgnoringModifiers: "v", isARepeat: false,
                                                  keyCode: 9))
        #expect(!main.performKeyEquivalent(with: plainV))
        #expect(target.pasteCount == 1)
    }
}
