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
//   --appearance <light|dark>  force the app appearance for comparison
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
// --appearance light|dark forces the APP's appearance, for checking how the
// effect reads against each theme without touching the user's system setting.
// The overlay window pins itself to dark regardless; this flag changes the
// desktop-facing side of the comparison only.
if let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count {
    app.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
}
app.delegate = delegate
app.run()
