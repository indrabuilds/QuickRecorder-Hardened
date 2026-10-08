//
//  StatusBarItem.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import SwiftUI

class PopoverState: ObservableObject {
    static let shared = PopoverState()
    @Published var isShowing: Bool = false
    @Published var isPaused: Bool = false
    @Published var isStatusBarHovered: Bool = false
}

/// Coordinate space the status bar controls report their frames in.
private let statusBarSpace = "QRStatusBar"

/// Routes menu-bar clicks using the real screen pointer position. macOS 27
/// supplies a synthetic centre position in the event's locationInWindow.
/// Local and remote event monitors route before/around hosted-view delivery;
/// the status button's target/action remains a fallback. Floating controls
/// use their ordinary SwiftUI buttons.
let qrStatusBarDebug = ProcessInfo.processInfo.environment["QR_STATUSBAR_DEBUG"] != nil

func qrLog(_ message: @autoclosure () -> String) {
    guard qrStatusBarDebug else { return }
    FileHandle.standardError.write(("[QRSB] " + message() + "\n").data(using: .utf8)!)
}

final class StatusBarHitTest {
    static let shared = StatusBarHitTest()

    private struct Region {
        let range: ClosedRange<CGFloat>
        let generation: Int
        let action: () -> Void
    }

    private var regions = [String: Region]()
    private var lastFired: (id: String, time: TimeInterval)?
    /// Bumped every time the menu bar view is rebuilt. A teardown from the previous view can
    /// arrive after the replacement has already registered, so an unregister only takes effect
    /// if it refers to the generation that is still current.
    private(set) var generation = 0

    func reset() {
        regions.removeAll()
        lastFired = nil
        generation += 1
        qrLog("reset -> generation \(generation)")
    }

    func register(id: String, frame: CGRect, generation: Int, action: @escaping () -> Void) {
        guard frame.width > 0 else { qrLog("register \(id) IGNORED (zero width) frame=\(frame)"); return }
        guard generation == self.generation else { qrLog("register \(id) IGNORED (stale gen \(generation) != \(self.generation))"); return }
        regions[id] = Region(range: frame.minX...frame.maxX, generation: generation, action: action)
        qrLog("register \(id) x=\(frame.minX)...\(frame.maxX) gen=\(generation)")
    }

    func unregister(id: String, generation: Int) {
        guard regions[id]?.generation == generation else { qrLog("unregister \(id) IGNORED (stale gen \(generation))"); return }
        regions.removeValue(forKey: id)
        qrLog("unregister \(id)")
    }

    func target(atX x: CGFloat) -> String? {
        regions.first(where: { $0.value.range.contains(x) })?.key
    }

    /// - Parameter x: pointer position in the hosted view's coordinate space.
    @discardableResult
    func handleClick(atX x: CGFloat) -> Bool {
        qrLog("handleClick x=\(x) regions=[" + regions.map { "\($0.key):\($0.value.range.lowerBound)...\($0.value.range.upperBound)" }.joined(separator: ", ") + "]")
        guard let hit = regions.first(where: { $0.value.range.contains(x) }) else { qrLog("  -> no region matched"); return false }
        // The button can send its action for both mouse down and mouse up depending on
        // how AppKit dispatches it; without this a pause/resume toggle would cancel itself out.
        let now = Date.timeIntervalSinceReferenceDate
        if let last = lastFired, last.id == hit.key, now - last.time < 0.15 { qrLog("  -> \(hit.key) debounced"); return true }
        lastFired = (hit.key, now)
        qrLog("  -> firing \(hit.key)")
        hit.value.action()
        return true
    }
}

private struct StatusBarHitRegion: ViewModifier {
    let id: String
    let enabled: Bool
    let generation: Int
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            // SwiftUI cannot place the click itself (every event in the menu bar reports the
            // centre of the whole item), so it must not consume it: with hit testing off the
            // status item button sends its action instead and the click is routed by x.
            // Hit testing stays on for the container, so .onHover still works.
            content
                .allowsHitTesting(false)
                .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            qrLog("onAppear \(id) named=\(geo.frame(in: .named(statusBarSpace))) local=\(geo.frame(in: .local)) global=\(geo.frame(in: .global))")
                            StatusBarHitTest.shared.register(id: id, frame: geo.frame(in: .named(statusBarSpace)), generation: generation, action: action)
                        }
                        .onChange(of: geo.frame(in: .named(statusBarSpace))) { newFrame in
                            StatusBarHitTest.shared.register(id: id, frame: newFrame, generation: generation, action: action)
                        }
                        .onDisappear { StatusBarHitTest.shared.unregister(id: id, generation: generation) }
                }
            )
        } else {
            content
        }
    }
}

private extension View {
    func statusBarHit(_ id: String, enabled: Bool, generation: Int, action: @escaping () -> Void) -> some View {
        modifier(StatusBarHitRegion(id: id, enabled: enabled, generation: generation, action: action))
    }
}

private struct EmptyTapGesture: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.onTapGesture {} } else { content }
    }
}

private var statusBarProbeInstalled = false

/// Debug aid for the menu bar event path; enabled with QR_STATUSBAR_DEBUG.
func installStatusBarEventProbe() {
    guard qrStatusBarDebug, !statusBarProbeInstalled else { return }
    statusBarProbeInstalled = true
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
        let statusWindow = statusBarItem?.button?.window
        qrLog("probe local: type=\(event.type.rawValue) window=\(String(describing: event.window)) isStatusWindow=\(event.window === statusWindow) loc=\(event.locationInWindow)")
        return event
    }
    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { event in
        qrLog("probe global: down at \(NSEvent.mouseLocation)")
    }
}

struct StatusBarItem: View {
    /// True only for the instance hosted in the menu bar; see `StatusBarHitTest`.
    var inStatusBar: Bool = false
    private let registrationGeneration: Int

    init(inStatusBar: Bool = false) {
        self.inStatusBar = inStatusBar
        registrationGeneration = StatusBarHitTest.shared.generation
    }

    @State private var deviceWindowIsShowing = true
    @State private var isMainMenuShowing = false
    @State private var isHovering = false
    @State private var recordingLength = "00:00"
    //@State private var isPassed = SCContext.isPaused
    @StateObject private var popoverState = PopoverState.shared
    //@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("miniStatusBar") private var miniStatusBar: Bool = false
    //@AppStorage("highlightMouse") private var highlightMouse: Bool = false
    private var appDelegate = AppDelegate.shared

    private func stopAction() {
        if SCContext.streamType == .idevice {
            AVOutputClass.shared.stopRecording()
        } else {
            SCContext.stopRecording()
        }
    }

    private func pauseAction() {
        SCContext.pauseRecording()
    }

    private func cameraAction() {
        if inStatusBar {
            StatusBarPopover.shared.toggle(SCContext.streamType == nil ? .main : .camera)
        } else { popoverState.isShowing = true }
    }

    private func deviceAction() {
        DispatchQueue.main.async {
            if deviceWindow.isVisible { deviceWindow.close() } else { deviceWindow.orderFront(nil) }
            deviceWindowIsShowing = deviceWindow.isVisible
        }
    }

    private var floatingPopoverBinding: Binding<Bool> {
        Binding(get: { !inStatusBar && popoverState.isShowing },
                set: { if !inStatusBar { popoverState.isShowing = $0 } })
    }

    var body: some View {
        HStack(spacing: 0) {
            if SCContext.streamType != nil {
                ZStack {
                    Rectangle()
                        .fill(Color.mypurple)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .cornerRadius(4)
                    HStack(spacing: 4) {
                        if miniStatusBar {
                            if inStatusBar ? popoverState.isStatusBarHovered : isHovering {
                                Button(action: stopAction, label: {
                                    ZStack {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(inStatusBar ? Color.primary : Color.red)
                                            .frame(width: 10, alignment: .center)
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }
                                })
                                .buttonStyle(.plain)
                                .statusBarHit("stop", enabled: inStatusBar, generation: registrationGeneration, action: stopAction)
                                if SCContext.streamType != .idevice {
                                    Button(action: pauseAction, label: {
                                        Image(systemName: popoverState.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("pause", enabled: inStatusBar, generation: registrationGeneration, action: pauseAction)
                                } else {
                                    Button(action: deviceAction, label: {
                                        Image(systemName: "eye.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                            .opacity(deviceWindowIsShowing ? 1 : 0.7)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("device", enabled: inStatusBar, generation: registrationGeneration, action: deviceAction)
                                }
                                if SCContext.streamType != .systemaudio && SCContext.streamType != .idevice && SCContext.streamType != .window {
                                    Button(action: cameraAction, label: {
                                        Image(systemName: "camera.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("camera", enabled: inStatusBar, generation: registrationGeneration, action: cameraAction)
                                }
                            } else {
                                Text(recordingLength)
                                    .foregroundStyle(.white)
                                    .font(.system(size: 15).monospaced())
                                    .offset(x: 0.5)
                            }
                        } else {
                            Group {
                                Button(action: stopAction, label: {
                                    ZStack {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(inStatusBar ? Color.primary : Color.red)
                                            .frame(width: 10, alignment: .center)
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }
                                })
                                .buttonStyle(.plain)
                                .statusBarHit("stop", enabled: inStatusBar, generation: registrationGeneration, action: stopAction)
                                if SCContext.streamType != .idevice {//&& SCContext.streamType != .systemaudio {
                                    Button(action: pauseAction, label: {
                                        Image(systemName: popoverState.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("pause", enabled: inStatusBar, generation: registrationGeneration, action: pauseAction)
                                }
                                Text(recordingLength)
                                    .foregroundStyle(.white)
                                    .font(.system(size: 15).monospaced())
                                    .offset(x: 0.5)
                            }
                        }
                    }
                }
                .padding([.leading,.trailing], 4)
                .popover(isPresented: floatingPopoverBinding, arrowEdge: .bottom) {
                    CameraPopoverView(closePopover: { popoverState.isShowing = false })
                }
                .onReceive(updateTimer) { t in
                    recordingLength = SCContext.getRecordingLength()
                    let timePassed = Date.now.timeIntervalSince(SCContext.startTime ?? t)
                    if SCContext.autoStop != 0 && timePassed / 60 >= CGFloat(SCContext.autoStop) { SCContext.stopRecording() }
                    if let visible = statusBarItem.button?.window?.occlusionState.contains(.visible) {
                        if visible { NSApp.windows.first(where: { $0.title == "Recording Controller".local })?.close(); return }
                        if SCContext.streamType != nil  && !visible && !(NSApp.windows.first(where: { $0.title == "Recording Controller".local })?.isVisible ?? false) {
                            guard let screen = SCContext.getScreenWithMouse() else { return }
                            let width = getStatusBarWidth()
                            let wX = (screen.frame.width - width) / 2
                            let contentView = NSHostingView(rootView: StatusBarItem())
                            contentView.frame = NSRect(x: wX, y: screen.visibleFrame.maxY, width: width, height: 24)
                            controlPanel.setFrame(contentView.frame, display: true)
                            controlPanel.contentView = contentView
                            controlPanel.makeKeyAndOrderFront(nil)
                        }
                    }
                }
                if !miniStatusBar {
                    if SCContext.streamType != .systemaudio {
                        if SCContext.streamType != .idevice {
                            Button(action: cameraAction, label: {
                                ZStack {
                                    Rectangle()
                                        .fill(SCContext.isCameraRunning() ? Color.mygreen : .gray)
                                        .shadow(color: .black.opacity(0.3), radius: 4)
                                        .cornerRadius(4)
                                    Image("camera")
                                        .foregroundStyle(.white)
                                }.frame(width: 36).padding([.leading,.trailing], 4)
                            })
                            .buttonStyle(.plain)
                            .statusBarHit("camera", enabled: inStatusBar, generation: registrationGeneration, action: cameraAction)
                        } else {
                            Button(action: deviceAction, label: {
                                ZStack {
                                    Rectangle()
                                        .fill(deviceWindow.isVisible ? Color.myblue : .gray.opacity(0.7))
                                        .shadow(color: .black.opacity(0.3), radius: 4)
                                        .cornerRadius(4)
                                    Image(systemName: "apps.ipad")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white)
                                }.frame(width: 36).padding([.leading,.trailing], 4)
                            })
                            .buttonStyle(.plain)
                            .statusBarHit("device", enabled: inStatusBar, generation: registrationGeneration, action: deviceAction)
                        }
                    }
                }
            } else if ud.bool(forKey: "showMenubar") {
                Button(action: cameraAction, label: {
                    ZStack {
                        Color.white.opacity(0.0001)
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                            .font(.system(size: 14, weight: .medium))
                            .offset(y: 1)
                    }
                })
                .buttonStyle(.plain)
                .statusBarHit("panel", enabled: inStatusBar, generation: registrationGeneration, action: cameraAction)
                .popover(isPresented: floatingPopoverBinding, arrowEdge: .bottom) {
                    if #available(macOS 13, *) {
                        ContentViewNew()
                    } else {
                        ContentView(fromStatusBar: true)
                            .onAppear{
                                if isMacOS12 { NSApp.activate(ignoringOtherApps: true) }
                            }
                    }
                }
            }
        }
        .coordinateSpace(name: statusBarSpace)
        // An empty tap gesture over the whole item swallows the mouse down before the
        // status item button can send its action, which is the only way a click is
        // delivered in the menu bar on macOS 27.
        .modifier(EmptyTapGesture(enabled: !inStatusBar))
        .onChange(of: miniStatusBar) { _ in if inStatusBar { updateStatusBar() } }
        .onHover { hovering in
            // The menu-bar instance uses native pointer tracking; floating
            // controls retain SwiftUI's normal hover path.
            guard !inStatusBar else { return }
            isHovering = hovering
            hideMousePointer = hovering
            hideScreenMagnifier = hovering
        }
    }
}

/// One native owner keeps presentation independent of SwiftUI hover/layout updates.
final class StatusBarPopover: NSObject, NSPopoverDelegate {
    enum Kind { case main, camera }
    static let shared = StatusBarPopover()
    private let popover = NSPopover()
    private var kind: Kind?
    private var menuTracking = false
    private var deferredStatusRebuild = false
    private var observers = [NSObjectProtocol]()

    private override init() {
        super.init()
        // Dismiss from the same event path that opens the popup, so the opening
        // menu-server click cannot be mistaken for an outside click.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false })

    }

    func toggle(_ requested: Kind) {
        guard let button = statusBarItem?.button, statusBarItem.isVisible else { return }
        if popover.isShown && kind == requested { close(); return }
        close()
        // Cleanup precedes presentation; it must never close the popup being shown.
        if requested == .main { closeAllWindow() }
        kind = requested
        let content: AnyView
        if requested == .camera {
            content = AnyView(CameraPopoverView(closePopover: { [weak self] in self?.close() }))
        } else if #available(macOS 13, *) {
            content = AnyView(ContentViewNew())
        } else { content = AnyView(ContentView(fromStatusBar: true)) }
        popover.contentViewController = NSHostingController(rootView: content)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        qrLog("popup shown \(requested) frame=\(String(describing: popover.contentViewController?.view.window?.frame))")
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
        kind = nil
    }

    func closeMain() { if kind == .main { close() } }

    func deferStatusRebuildIfShown() -> Bool {
        guard popover.isShown else { return false }
        deferredStatusRebuild = true
        qrLog("status rebuild deferred")
        return true
    }

    func refreshForRecordingState() {
        if (kind == .main && SCContext.streamType != nil) ||
           (kind == .camera && SCContext.streamType == nil) { close() }
    }

    func observeMouseDown(at point: NSPoint) {
        guard popover.isShown, !menuTracking, NSApp.modalWindow == nil,
              let popupWindow = popover.contentViewController?.view.window else { return }
        if let anchor = statusBarItem?.button?.window, anchor.frame.contains(point) { return }
        for window in NSApp.windows where window.isVisible && window.frame.contains(point) {
            var ancestor: NSWindow? = window
            while let current = ancestor {
                if current === popupWindow { return }
                ancestor = current.parent ?? current.sheetParent
            }
        }
        close()
    }

    func handleEscape(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 48 {
            close() // Let Command-Tab continue switching applications.
            return false
        }
        guard event.keyCode == 53, popover.isShown, !menuTracking,
              event.window === popover.contentViewController?.view.window else { return false }
        close()
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        kind = nil
        qrLog("popup closed")
        if deferredStatusRebuild {
            deferredStatusRebuild = false
            updateStatusBar()
        }
    }
}

enum StatusBarClickRouting {
    private static var monitor: Any?
    private static var remoteMonitor: Any?

    private static var pending: (id: String, generation: Int)?
    private static var latestDown = -Double.infinity
    private static var latestUp = -Double.infinity
    private static var lastMouseArrival = -Double.infinity

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .keyDown]) { event in
            if event.type == .keyDown {
                return StatusBarPopover.shared.handleEscape(event) ? nil : event
            }
            refreshHover(screenPoint: NSEvent.mouseLocation)
            if event.type == .mouseMoved { return event }
            if event.type == .leftMouseDown { StatusBarPopover.shared.observeMouseDown(at: NSEvent.mouseLocation) }
            return processMouse(event, screenPoint: NSEvent.mouseLocation) ? nil : event
        }
        remoteMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) { event in
            refreshHover(screenPoint: NSEvent.mouseLocation)
            if event.type == .leftMouseDown { StatusBarPopover.shared.observeMouseDown(at: NSEvent.mouseLocation) }
            if event.type != .mouseMoved { processMouse(event, screenPoint: NSEvent.mouseLocation) }
        }
    }

    private static func target(at point: NSPoint) -> (String, CGFloat)? {
        guard statusBarItem?.isVisible == true, let button = statusBarItem?.button,
              let window = button.window, window.isVisible, window.occlusionState.contains(.visible),
              window.frame.contains(point), let host = button.subviews.first else { return nil }
        let x = host.convert(window.convertPoint(fromScreen: point), from: nil).x
        guard let id = StatusBarHitTest.shared.target(atX: x) else { return nil }
        return (id, x)
    }

    @discardableResult
    static func processMouse(_ event: NSEvent, screenPoint: NSPoint) -> Bool {
        lastMouseArrival = ProcessInfo.processInfo.systemUptime
        if event.type == .leftMouseDown {
            // Duplicate forwarding of the same physical event cannot start a new click.
            guard event.timestamp > latestDown, event.timestamp > latestUp else { return pending != nil }
            latestDown = event.timestamp
            guard !event.modifierFlags.contains(.command), let hit = target(at: screenPoint) else { pending = nil; return false }
            pending = (hit.0, StatusBarHitTest.shared.generation)
            return true
        }
        guard event.type == .leftMouseUp, event.timestamp > latestUp else { return false }
        latestUp = event.timestamp
        let click = pending
        pending = nil
        guard let click = click, click.generation == StatusBarHitTest.shared.generation,
              let hit = target(at: screenPoint), hit.0 == click.id else { return false }
        // Present popups after release, never in the middle of their opening press.
        return StatusBarHitTest.shared.handleClick(atX: hit.1)
    }

    static func nativeActivation() {
        // Native mouse target/actions are delayed on macOS 27 and can duplicate
        // already handled events. Keep non-mouse/accessible activation for idle.
        guard NSEvent.pressedMouseButtons == 0,
              ProcessInfo.processInfo.systemUptime - lastMouseArrival > 1,
              SCContext.streamType == nil else { return }
        StatusBarPopover.shared.toggle(.main)
    }

    static func refreshHover(screenPoint: NSPoint) {
        let hovered: Bool
        if statusBarItem?.isVisible == true, let window = statusBarItem?.button?.window {
            hovered = window.isVisible && window.occlusionState.contains(.visible) && window.frame.contains(screenPoint)
        } else { hovered = false }
        guard hovered != PopoverState.shared.isStatusBarHovered else { return }
        PopoverState.shared.isStatusBarHovered = hovered
        hideMousePointer = hovered
        hideScreenMagnifier = hovered
    }

    @discardableResult
    static func route(screenPoint: NSPoint) -> Bool {
        guard statusBarItem?.isVisible == true,
              let button = statusBarItem?.button, let window = button.window,
              window.isVisible, window.occlusionState.contains(.visible),
              window.frame.contains(screenPoint), let host = button.subviews.first else { return false }
        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        let pointInHost = host.convert(pointInWindow, from: nil)
        qrLog("route pointer=\(screenPoint) host=\(pointInHost)")
        return StatusBarHitTest.shared.handleClick(atX: pointInHost.x)
    }
}

extension AppDelegate {
    @objc func statusBarButtonClicked(_ sender: Any?) {
        StatusBarClickRouting.nativeActivation()
    }
}

func updateStatusBar() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        StatusBarPopover.shared.refreshForRecordingState()
        PopoverState.shared.isPaused = SCContext.isPaused
        if SCContext.streamType == nil && !ud.bool(forKey: "showMenubar") {
            StatusBarPopover.shared.close()
            statusBarItem.isVisible = false
            return
        }
        guard let button = statusBarItem.button else { return }
        if StatusBarPopover.shared.deferStatusRebuildIfShown() { return }
        //let width = SCContext.streamType == nil ? 36 : ((SCContext.streamType == .idevice || SCContext.streamType == .systemaudio) ? 138 : 158)
        StatusBarHitTest.shared.reset()
        let iconView = NSHostingView(rootView: StatusBarItem(inStatusBar: true).padding(.top, isMacOS14 ? -2 : -1))
        iconView.frame = NSRect(x: 0, y: 1, width: getStatusBarWidth(), height: isMacOS14 ? 22 : 21)
        button.subviews = [iconView]
        button.frame = iconView.frame
        button.setAccessibilityLabel("QuickRecorder")
        button.target = AppDelegate.shared
        button.action = #selector(AppDelegate.statusBarButtonClicked(_:))
        // A status item button hosting a subview does not send its action on mouse up on
        // macOS 27; it only does so if mouse down is in the mask. It can then send twice
        // per click, which the debounce in StatusBarHitTest absorbs.
        button.sendAction(on: [.leftMouseUp])
        statusBarItem.isVisible = true
        StatusBarClickRouting.install()
        DispatchQueue.main.async { StatusBarClickRouting.refreshHover(screenPoint: NSEvent.mouseLocation) }
        installStatusBarEventProbe()
        qrLog("updateStatusBar: width=\(getStatusBarWidth()) streamType=\(String(describing: SCContext.streamType)) target=\(String(describing: button.target)) action=\(String(describing: button.action))")
    }
}
