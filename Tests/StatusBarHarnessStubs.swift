import CoreGraphics
import Darwin
var statusBarItem: NSStatusItem!
let isMacOS14 = false
let isMacOS12 = false
let ud = UserDefaults.standard
let updateTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
var hideMousePointer = false
var hideScreenMagnifier = false
let deviceWindow = NSWindow()
let controlPanel = NSWindow()
extension String { var local: String { self } }
extension Color {
    static let mypurple = Color.purple
    static let mygreen = Color.green
    static let myblue = Color.blue
}
func closeAllWindow() {}
func getStatusBarWidth() -> CGFloat { ud.bool(forKey: "miniStatusBar") ? 68 : 114 }
func report(_ action: String) { print("ACTION", action); fflush(stdout) }
struct CameraPopoverView: View { let closePopover: () -> Void; var body: some View { Text("Test") } }
struct ContentViewNew: View { var body: some View { Text("Test") } }
struct ContentView: View { var fromStatusBar: Bool; var body: some View { Text("Test") } }
enum StreamType { case systemaudio, idevice, window, screen }
struct SCContext {
    static var streamType: StreamType? = .systemaudio
    static var isPaused = false
    static var startTime: Date? = Date()
    static var autoStop = 0
    static func getRecordingLength() -> String { "00:00" }
    static func getScreenWithMouse() -> NSScreen? { NSScreen.main }
    static func isCameraRunning() -> Bool { false }
    static func stopRecording() { report("stop") }
    static func pauseRecording() { isPaused.toggle(); PopoverState.shared.isPaused = isPaused; report(isPaused ? "pause" : "resume") }
}
final class AVOutputClass { static let shared = AVOutputClass(); func stopRecording() { report("stop-device") } }
final class ClickSwallowingView: NSView {
    override func mouseDown(with event: NSEvent) { report("swallowed") }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private var signalSource: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        ud.setVolatileDomain(["miniStatusBar": ProcessInfo.processInfo.environment["QR_TEST_LAYOUT"] == "mini"], forName: UserDefaults.argumentDomain)
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBar()
        if ProcessInfo.processInfo.environment["QR_TEST_SWALLOW"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                let button = statusBarItem.button!
                button.addSubview(ClickSwallowingView(frame: button.bounds))
            }
        }
        signal(SIGUSR1, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signalSource?.setEventHandler { updateStatusBar() }
        signalSource?.resume()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let button = statusBarItem.button!
            let view = button.subviews.first!
            let origin = button.window!.convertToScreen(button.convert(view.bounds, from: view)).origin
            print("WINDOW",button.window!.frame,"BUTTON",button.frame,"HOST",view.frame)
            fflush(stdout)
            try? "\(origin.x),\(origin.y)".write(toFile: ProcessInfo.processInfo.environment["QR_TEST_COORDINATES"] ?? "/private/tmp/qr-statusbar-investigation/actual-coordinates", atomically: true, encoding: .utf8)
        }
        Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in NSApp.terminate(nil) }
    }
}


func runRoutingUnitChecks() {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL", message); exit(1) }
        checks += 1
    }
    let registry = StatusBarHitTest.shared
    registry.reset()
    let previous = registry.generation
    var stops = 0
    var pauses = 0
    registry.register(id: "stop", frame: NSRect(x: 0, y: 0, width: 16, height: 21), generation: previous) { stops += 1 }
    registry.register(id: "pause", frame: NSRect(x: 20, y: 0, width: 16, height: 21), generation: previous) { pauses += 1 }
    check(registry.handleClick(atX: 8) && stops == 1, "stop routes correctly")
    check(registry.handleClick(atX: 28) && pauses == 1, "pause routes correctly")
    check(registry.handleClick(atX: 28) && pauses == 1, "duplicate delivery cannot toggle pause twice")
    check(!registry.handleClick(atX: 18), "gap is not a control")
    check(!registry.handleClick(atX: -10), "outside point is not a control")
    registry.reset()
    let current = registry.generation
    registry.register(id: "stop", frame: NSRect(x: 0, y: 0, width: 16, height: 21), generation: current) { stops += 1 }
    registry.unregister(id: "stop", generation: previous)
    check(registry.handleClick(atX: 8) && stops == 2, "stale teardown preserves rebuilt stop")
    registry.register(id: "camera", frame: NSRect(x: 200, y: 0, width: 16, height: 21), generation: previous) { stops += 100 }
    check(!registry.handleClick(atX: 208), "stale registration is ignored")
    check(!StatusBarClickRouting.route(screenPoint: .zero), "missing status item is ignored")
    print("PASS: \(checks) menu-bar routing checks")
}
if ProcessInfo.processInfo.environment["QR_TEST_UNIT"] == "1" {
    runRoutingUnitChecks()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = AppDelegate.shared
app.run()
