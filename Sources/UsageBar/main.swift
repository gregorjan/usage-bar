import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusItemController(providers: [ClaudeProvider(), CodexProvider(), CopilotProvider()])
controller.start()
app.run()
