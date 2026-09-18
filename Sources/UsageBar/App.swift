import AppKit

@MainActor
final class StatusItemController {
    private var items: [String: NSStatusItem] = [:]
    private let providers: [any UsageProvider]
    private var timer: Timer?
    private var snapshots: [AccountSnapshot] = []
    private var lastPercent: [String: Double] = [:]

    init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    func start() {
        snapshots = providers.map {
            AccountSnapshot(providerID: $0.id, glyph: $0.glyph, accountID: "-", accountLabel: $0.displayName,
                            windows: [], error: "Loading…", fetchedAt: Date())
        }
        render()
        Notify.shared.start()
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
                self.noteResets(fresh)
                self.snapshots.removeAll { $0.providerID == provider.id }
                self.snapshots.append(contentsOf: fresh)
                self.render()
            }
        }
    }

    private func noteResets(_ fresh: [AccountSnapshot]) {
        for snapshot in fresh where snapshot.error == nil {
            for window in snapshot.windows {
                guard let used = window.percentUsed else { continue }
                let key = "\(snapshot.itemKey)/\(window.label)"
                let previous = lastPercent[key]
                lastPercent[key] = used
                guard let previous, previous >= Format.nearLimit, used < previous else { continue }
                let what = window.label.isEmpty ? "Usage" : "\(window.label) window"
                Notify.shared.post(title: "\(snapshot.accountLabel) limit reset",
                                   body: "\(what) back to \(Format.percent(used))")
            }
        }
    }

    private var merged: Bool {
        get { UserDefaults.standard.bool(forKey: "merged") }
        set { UserDefaults.standard.set(newValue, forKey: "merged") }
    }

    private func render() {
        var keyed: [(String, AccountSnapshot)] = []
        for provider in providers {
            let mine = snapshots.filter { $0.providerID == provider.id }
            for (index, snapshot) in mine.enumerated() {
                keyed.append(("\(provider.id)#\(index)", snapshot))
            }
        }
        let live = merged ? Set(["merged"]) : Set(keyed.map(\.0))
        for (key, item) in items where !live.contains(key) {
            NSStatusBar.system.removeStatusItem(item)
            items[key] = nil
        }
        if merged {
            let item = statusItem(for: "merged")
            item.button?.title = ""
            item.button?.image = mergedImage(keyed.map(\.1))
            item.button?.imagePosition = .imageOnly
            item.menu = mergedMenu(keyed.map(\.1))
        } else {
            for (key, snapshot) in keyed {
                let item = statusItem(for: key)
                if let image = Self.icon(named: snapshot.glyph) {
                    item.button?.image = image
                    item.button?.imagePosition = .imageLeading
                    item.button?.title = " \(Format.barText(snapshot))"
                } else {
                    item.button?.title = "\(snapshot.glyph) \(Format.barText(snapshot))"
                }
                item.menu = menu(for: snapshot)
            }
        }
        Log.write("render merged=\(merged) \(keyed.map { "\($0.0)=\(Format.barText($0.1))" }.joined(separator: " | "))")
    }

    private func statusItem(for key: String) -> NSStatusItem {
        if let existing = items[key] { return existing }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        items[key] = created
        return created
    }

    private func mergedImage(_ all: [AccountSnapshot]) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let iconSize: CGFloat = 14
        let gap: CGFloat = 3
        let groupGap: CGFloat = 9

        let pieces = all.map { snapshot -> (NSImage?, NSAttributedString) in
            (Self.icon(named: snapshot.glyph),
             NSAttributedString(string: Format.compact(snapshot), attributes: attributes))
        }
        let width = pieces.reduce(CGFloat(0)) { total, piece in
            total + (piece.0 == nil ? 0 : iconSize + gap) + piece.1.size().width + groupGap
        } - groupGap
        let height = max(iconSize, font.capHeight + 6)

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (icon, text) in pieces {
                if let icon {
                    icon.draw(in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
                    x += iconSize + gap
                }
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += size.width + groupGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func mergedMenu(_ all: [AccountSnapshot]) -> NSMenu {
        let menu = NSMenu()
        for snapshot in all {
            let header = NSMenuItem(title: "\(snapshot.accountLabel)", action: nil, keyEquivalent: "")
            header.image = Self.icon(named: snapshot.glyph)
            header.isEnabled = false
            menu.addItem(header)
            if let error = snapshot.error {
                let item = NSMenuItem(title: "    \(error)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            for window in snapshot.windows {
                let line = window.label.isEmpty ? Format.percent(window.percentUsed) : "\(window.label): \(Format.percent(window.percentUsed))"
                let item = NSMenuItem(title: "    \(line)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                if let reset = window.resetsAt {
                    let sub = NSMenuItem(title: "        resets \(Format.fullReset(reset))", action: nil, keyEquivalent: "")
                    sub.isEnabled = false
                    menu.addItem(sub)
                }
            }
            addAccountActions(for: snapshot, to: menu, indent: "    ")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
        addSplitToggle(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func addAccountActions(for snapshot: AccountSnapshot, to menu: NSMenu, indent: String) {
        guard let provider = providers.first(where: { $0.id == snapshot.providerID }) else { return }
        let signIn = NSMenuItem(title: indent + (snapshot.error == nil ? "Sign in another \(provider.displayName) account…" : "Sign in to \(provider.displayName)…"),
                                action: #selector(signIn(_:)), keyEquivalent: "")
        signIn.target = self
        signIn.representedObject = provider.id
        menu.addItem(signIn)

        if snapshot.error == nil {
            let signOut = NSMenuItem(title: indent + "Sign out \(snapshot.accountLabel)", action: #selector(signOut(_:)), keyEquivalent: "")
            signOut.target = self
            signOut.representedObject = snapshot
            menu.addItem(signOut)
        }
    }

    private func addSplitToggle(to menu: NSMenu) {
        let toggle = NSMenuItem(title: merged ? "Split into separate items" : "Merge into one item",
                                action: #selector(toggleMerged), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
    }

    @objc private func toggleMerged() {
        merged.toggle()
        render()
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
        addSplitToggle(to: menu)

        addAccountActions(for: snapshot, to: menu, indent: "")
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

