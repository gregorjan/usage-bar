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

    static func run(url: URL, provider: String) async throws -> String {
        await open(url)
        return try await MainActor.run {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "code#state"
            let alert = NSAlert()
            alert.messageText = "\(provider) sign-in"
            alert.informativeText = "Authorize in the browser, then paste the code it shows you here. The sign-in link is on your clipboard — paste it into another browser or profile if you need a different account."
            alert.accessoryView = field
            alert.addButton(withTitle: "Sign in")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
            return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
