import AppKit

@MainActor
final class StatusItemController {
    private var items: [String: NSStatusItem] = [:]
    private let providers: [any UsageProvider]
    private var timer: Timer?
    private var snapshots: [AccountSnapshot] = []

    init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    func start() {
        snapshots = providers.map {
            AccountSnapshot(providerID: $0.id, glyph: $0.glyph, accountID: "-", accountLabel: $0.displayName,
                            windows: [], error: "Loading…", fetchedAt: Date())
        }
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        for provider in providers {
            Task { @MainActor in
                let fresh = await provider.fetch()
                Log.write("fetch \(provider.id) -> \(fresh.count) [\(fresh.map { "\($0.accountID):\($0.error ?? Format.barText($0))" }.joined(separator: ", "))]")
                self.snapshots.removeAll { $0.providerID == provider.id }
                self.snapshots.append(contentsOf: fresh)
                self.render()
            }
        }
    }

    private func render() {
        var keyed: [(String, AccountSnapshot)] = []
        for provider in providers {
            let mine = snapshots.filter { $0.providerID == provider.id }
            for (index, snapshot) in mine.enumerated() {
                keyed.append(("\(provider.id)#\(index)", snapshot))
            }
        }
        let live = Set(keyed.map(\.0))
        for (key, item) in items where !live.contains(key) {
            NSStatusBar.system.removeStatusItem(item)
            items[key] = nil
        }
        for (key, snapshot) in keyed {
            let item = items[key] ?? {
                let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                items[key] = created
                return created
            }()
            if let image = Self.icon(named: snapshot.glyph) {
                item.button?.image = image
                item.button?.imagePosition = .imageLeading
                item.button?.title = " \(Format.barText(snapshot))"
            } else {
                item.button?.title = "\(snapshot.glyph) \(Format.barText(snapshot))"
            }
            item.menu = menu(for: snapshot)
        }
        Log.write("render \(keyed.map { "\($0.0)=\($0.1.glyph) \(Format.barText($0.1))" }.joined(separator: " | "))")
    }

    private func menu(for snapshot: AccountSnapshot) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(snapshot.accountLabel)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let error = snapshot.error {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for window in snapshot.windows {
            let line = window.label.isEmpty ? Format.percent(window.percentUsed) : "\(window.label): \(Format.percent(window.percentUsed))"
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let reset = window.resetsAt {
                let sub = NSMenuItem(title: "    resets \(Format.fullReset(reset))", action: nil, keyEquivalent: "")
                sub.isEnabled = false
                menu.addItem(sub)
            }
        }

        menu.addItem(.separator())
        let updated = NSMenuItem(title: "Updated \(Format.shortResetTime(snapshot.fetchedAt))", action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self

        let provider = providers.first { $0.id == snapshot.providerID }
        if provider != nil {
            let signIn = NSMenuItem(title: snapshot.error == nil ? "Sign in another account…" : "Sign in…",
                                    action: #selector(signIn(_:)), keyEquivalent: "")
            signIn.target = self
            signIn.representedObject = snapshot.providerID
            menu.addItem(signIn)

            if snapshot.error == nil {
                let signOut = NSMenuItem(title: "Sign out \(snapshot.accountLabel)", action: #selector(signOut(_:)), keyEquivalent: "")
                signOut.target = self
                signOut.representedObject = snapshot
                menu.addItem(signOut)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static var iconCache: [String: NSImage] = [:]

    private static func icon(named name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "pdf"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.size = NSSize(width: 15, height: 15)
        image.isTemplate = true
        iconCache[name] = image
        return image
    }

    @objc private func refreshNow() { refresh() }

    @objc private func signIn(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String,
              let provider = providers.first(where: { $0.id == providerID }) else { return }
        Task {
            do {
                try await provider.signIn { code, url in
                    Task { @MainActor in Self.presentCode(code, url: url, provider: provider.displayName) }
                }
                await MainActor.run { self.refresh() }
            } catch {
                await MainActor.run { Self.presentError(error, provider: provider.displayName) }
            }
        }
    }

    @objc private func signOut(_ sender: NSMenuItem) {
        guard let snapshot = sender.representedObject as? AccountSnapshot,
              let provider = providers.first(where: { $0.id == snapshot.providerID }) else { return }
        Task {
            await provider.signOut(accountID: snapshot.accountID)
            await MainActor.run { self.refresh() }
        }
    }

    private static func presentCode(_ code: String, url: URL, provider: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSLog("UsageBar %@ device code: %@", provider, code)

        let field = NSTextField(labelWithString: code)
        field.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        field.isSelectable = true
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 40)

        let alert = NSAlert()
        alert.messageText = "\(provider) sign-in"
        alert.informativeText = "Enter this code at \(url.host ?? url.absoluteString). It stays here until you close this dialog; UsageBar keeps polling in the background."
        alert.accessoryView = field
        alert.addButton(withTitle: "Open browser")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    private static func presentError(_ error: any Error, provider: String) {
        let alert = NSAlert()
        alert.messageText = "\(provider) sign-in failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

extension Format {
    static func shortResetTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

