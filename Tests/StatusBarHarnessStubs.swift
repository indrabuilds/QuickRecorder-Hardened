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
func closeAllWindow() {
    StatusBarPopover.shared.close()
    for w in NSApp.windows.filter({ $0.title != "Item-0" && !$0.title.isEmpty && !$0.title.lowercased().contains(".qma") }) {
        print("CLEANUP",w.title);w.close()
    }
}
func getStatusBarWidth() -> CGFloat {
    if SCContext.streamType == nil { return 36 }
    if SCContext.streamType == .window { return ud.bool(forKey: "miniStatusBar") ? 78 : 158 }
    return ud.bool(forKey: "miniStatusBar") ? 68 : 114
}
func report(_ action: String) { print("ACTION", action); fflush(stdout) }
struct CameraPopoverView: View {
    let closePopover: () -> Void
    var body: some View { Button("Camera setting") { report("camera-setting") }.background(TestRegion(name: "camera-setting")).frame(width: 220, height: 120) }
}
final class TestRegionView: NSView {
    var name = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        guard let window = window, bounds.width > 0, bounds.height > 0,
              let path = ProcessInfo.processInfo.environment["QR_TEST_REGIONS"] else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        var regions = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String:[Double]] ?? [:]
        regions[name] = [rect.minX,rect.minY,rect.width,rect.height]
        try? JSONSerialization.data(withJSONObject: regions).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
struct TestRegion: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> TestRegionView { let view = TestRegionView(); view.name = name; return view }
    func updateNSView(_ view: TestRegionView, context: Context) { view.needsLayout = true }
}
func closeMainWindow() { StatusBarPopover.shared.closeMain() }
struct ContentViewNew: View {
    @HarnessState private var nested = false
    var body: some View {
        VStack {
            Text("Recording controls test")
            Button("Test setting") { report("popup-setting") }.background(TestRegion(name: "setting"))
            Button("Nested options") { nested = true }.background(TestRegion(name: "nested-open"))
                .popover(isPresented: $nested) {
                    Button("Nested setting") { report("nested-setting") }.background(TestRegion(name: "nested-setting"))
                        .frame(width: 200, height: 100).onAppear { report("nested-appeared") }
                }
            Button("Choose window") { closeMainWindow(); report("selector-chosen") }.background(TestRegion(name: "selector"))
        }.frame(width: 320, height: 160)
        .onAppear { report("popup-appeared") }
        .onDisappear { report("popup-disappeared") }
    }
}
struct ContentView: View { var fromStatusBar: Bool; var body: some View { Text("Test") } }
enum StreamType { case systemaudio, idevice, window, screen }
struct SCContext {
    static var streamType: StreamType? = {
        switch ProcessInfo.processInfo.environment["QR_TEST_MODE"] {
        case "idle": return nil
        case "video": return .window
        default: return .systemaudio
        }
    }()
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
    private var outsideWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        ud.setVolatileDomain(["showMenubar": true, "miniStatusBar": ProcessInfo.processInfo.environment["QR_TEST_LAYOUT"] == "mini"], forName: UserDefaults.argumentDomain)
        if ProcessInfo.processInfo.environment["QR_TEST_MODE"] == "idle" {
            let outside = NSWindow(contentRect: NSRect(x: 100, y: 240, width: 220, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            outside.title = "Outside test.qma"
            outside.contentView = NSHostingView(rootView: Button("Outside control") { report("outside-click") }.background(TestRegion(name: "outside")))
            outside.isReleasedWhenClosed = false
            outside.makeKeyAndOrderFront(nil)
            outsideWindow = outside
        }
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
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
    check(!StatusBarClickRouting.processMouse(down, screenPoint: .zero), "press outside item is ignored")
    check(!StatusBarClickRouting.processMouse(up, screenPoint: .zero), "release without target is ignored")
    check(!StatusBarClickRouting.processMouse(down, screenPoint: .zero), "late duplicate press cannot start another click")
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
