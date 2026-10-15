import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.mainMenu = ApplicationMenu.make()
let controller = StatusItemController(providers: [ClaudeProvider(), CodexProvider(), CopilotProvider()])
controller.start()
app.run()
