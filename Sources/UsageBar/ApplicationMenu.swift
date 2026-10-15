import AppKit

@MainActor
enum ApplicationMenu {
    /// Accessory apps still need an Edit menu for shortcuts in native text fields and alerts.
    static func make() -> NSMenu {
        let main = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "UsageBar")
        application.submenu?.addItem(withTitle: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(application)

        let edit = NSMenu(title: "Edit")
        add("Undo", action: NSSelectorFromString("undo:"), key: "z", to: edit)
        add("Redo", action: NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add("Cut", action: #selector(NSText.cut(_:)), key: "x", to: edit)
        add("Copy", action: #selector(NSText.copy(_:)), key: "c", to: edit)
        add("Paste", action: #selector(NSText.paste(_:)), key: "v", to: edit)
        add("Select All", action: #selector(NSText.selectAll(_:)), key: "a", to: edit)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private static func add(_ title: String, action: Selector, key: String,
                            modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // A nil target routes the action to the focused text editor, including modal alerts.
        item.target = nil
    }
}
