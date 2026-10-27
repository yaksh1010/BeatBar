import AppKit

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--demo"), index + 1 < arguments.count {
    Demo.run(outputDirectory: URL(fileURLWithPath: arguments[index + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
