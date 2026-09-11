import AppKit
import LidAngleKit

if CommandLine.arguments.contains("--version") {
    print("MacBookUno \(ProjectVersion.current)")
    exit(0)
}

// .accessory: no Dock icon and no app menu, just a menu bar item.
// Setting this programmatically makes `swift run` behave correctly without an
// .app bundle too (LSUIElement in Info.plist does the same once bundled).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Test flags:
//   --simulate <degrees>  use a fixed angle instead of the sensor
//   --sweep               sweep the angle between 0 and the threshold
//   --log                 print angle and fold amount to stdout
//   --pattern             lay a striped test pattern under the overlay
//   --version             print the version and exit
let delegate = AppDelegate()
var arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--simulate"), index + 1 < arguments.count,
   let angle = Double(arguments[index + 1]) {
    delegate.simulatedAngle = angle
}
if arguments.contains("--sweep") {
    delegate.sweepEnabled = true
}
if arguments.contains("--log") {
    delegate.logEnabled = true
}
if arguments.contains("--pattern") {
    delegate.patternEnabled = true
}
app.delegate = delegate
app.run()
