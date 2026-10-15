import AppKit

enum PasteFlow {
    static func open(_ url: URL) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            NSWorkspace.shared.open(url)
        }
        Log.write("sign-in url copied \(url.host ?? "")")
    }

    static func run(url: URL, provider: String, accountID: String? = nil) async throws -> String {
        await open(url)
        return try await MainActor.run {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "code#state"
            let alert = NSAlert()
            alert.messageText = accountID == nil ? "\(provider) sign-in" : "Reconnect \(provider)"
            let accountNote = accountID.map { "Authorize as \($0). This updates your saved account in place.\n\n" } ?? ""
            alert.informativeText = accountNote + "Authorize in the browser, then paste the code it shows you here. The sign-in link is on your clipboard — paste it into another browser or profile if needed."
            alert.accessoryView = field
            alert.addButton(withTitle: accountID == nil ? "Sign in" : "Reconnect")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
            return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
