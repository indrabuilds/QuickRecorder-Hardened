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
}

/// Coordinate space the status bar controls report their frames in.
private let statusBarSpace = "QRStatusBar"

/// Click routing for the menu bar item.
///
/// As of macOS 27 a view hosted inside an `NSStatusItem`'s button no longer receives
/// mouse events: the event that reaches the status item's window always reports
/// `locationInWindow` as the centre of the button regardless of where the click landed,
/// so SwiftUI can never tell which control was hit and no `Button` action ever fires.
/// Hover events are still delivered, which is why the item still looks responsive.
///
/// The status item button's own target/action *does* fire, and `NSEvent.mouseLocation`
/// is accurate, so each control records its frame while SwiftUI lays it out and we route
/// the click to whichever control's horizontal range contains the pointer. The controls
/// are in a single row, so matching on x alone is enough.
///
/// This only applies to the menu bar item. The same view hosted in the floating
/// "Recording Controller" panel is in an ordinary window and works normally, so it does
/// not register anything.
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

    /// - Parameter x: pointer position in the hosted view's coordinate space.
    func handleClick(atX x: CGFloat) {
        qrLog("handleClick x=\(x) regions=[" + regions.map { "\($0.key):\($0.value.range.lowerBound)...\($0.value.range.upperBound)" }.joined(separator: ", ") + "]")
        guard let hit = regions.first(where: { $0.value.range.contains(x) }) else { qrLog("  -> no region matched"); return }
        // The button can send its action for both mouse down and mouse up depending on
        // how AppKit dispatches it; without this a pause/resume toggle would cancel itself out.
        let now = Date.timeIntervalSinceReferenceDate
        if let last = lastFired, last.id == hit.key, now - last.time < 0.15 { qrLog("  -> \(hit.key) debounced"); return }
        lastFired = (hit.key, now)
        qrLog("  -> firing \(hit.key)")
        hit.value.action()
    }
}

private struct StatusBarHitRegion: ViewModifier {
    let id: String
    let enabled: Bool
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
                    let generation = StatusBarHitTest.shared.generation
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
    func statusBarHit(_ id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(StatusBarHitRegion(id: id, enabled: enabled, action: action))
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

    init(inStatusBar: Bool = false) {
        self.inStatusBar = inStatusBar
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
        popoverState.isShowing = true
    }

    private func deviceAction() {
        DispatchQueue.main.async {
            if deviceWindow.isVisible { deviceWindow.close() } else { deviceWindow.orderFront(nil) }
            deviceWindowIsShowing = deviceWindow.isVisible
        }
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
                            if isHovering {
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
                                .statusBarHit("stop", enabled: inStatusBar, action: stopAction)
                                if SCContext.streamType != .idevice {
                                    Button(action: pauseAction, label: {
                                        Image(systemName: popoverState.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("pause", enabled: inStatusBar, action: pauseAction)
                                } else {
                                    Button(action: deviceAction, label: {
                                        Image(systemName: "eye.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                            .opacity(deviceWindowIsShowing ? 1 : 0.7)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("device", enabled: inStatusBar, action: deviceAction)
                                }
                                if SCContext.streamType != .systemaudio && SCContext.streamType != .idevice && SCContext.streamType != .window {
                                    Button(action: cameraAction, label: {
                                        Image(systemName: "camera.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("camera", enabled: inStatusBar, action: cameraAction)
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
                                .statusBarHit("stop", enabled: inStatusBar, action: stopAction)
                                if SCContext.streamType != .idevice {//&& SCContext.streamType != .systemaudio {
                                    Button(action: pauseAction, label: {
                                        Image(systemName: popoverState.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    })
                                    .buttonStyle(.plain)
                                    .statusBarHit("pause", enabled: inStatusBar, action: pauseAction)
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
                .popover(isPresented: $popoverState.isShowing, arrowEdge: .bottom) {
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
                            .statusBarHit("camera", enabled: inStatusBar, action: cameraAction)
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
                            .statusBarHit("device", enabled: inStatusBar, action: deviceAction)
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
                .statusBarHit("panel", enabled: inStatusBar, action: cameraAction)
                .popover(isPresented: $popoverState.isShowing, arrowEdge: .bottom) {
                    if #available(macOS 13, *) {
                        ContentViewNew().onAppear{ closeAllWindow() }
                    } else {
                        ContentView(fromStatusBar: true)
                            .onAppear{
                                closeAllWindow()
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
        .onHover { hovering in
            isHovering = hovering
            hideMousePointer = hovering
            hideScreenMagnifier = hovering
        }
    }
}

extension AppDelegate {
    /// Routes a menu bar click to the control under the pointer. See `StatusBarHitTest`.
    @objc func statusBarButtonClicked(_ sender: Any?) {
        guard let button = statusBarItem?.button, let window = button.window else { qrLog("clicked but no button/window"); return }
        let xInWindow = NSEvent.mouseLocation.x - window.frame.minX
        qrLog("clicked mouse=\(NSEvent.mouseLocation) window=\(window.frame) button=\(button.frame) hosting=\(button.subviews.first?.frame.debugDescription ?? "nil")")
        StatusBarHitTest.shared.handleClick(atX: xInWindow - button.frame.minX)
    }
}

func updateStatusBar() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        if SCContext.streamType == nil && !ud.bool(forKey: "showMenubar") {
            statusBarItem.isVisible = false
            return
        }
        guard let button = statusBarItem.button else { return }
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
        button.sendAction(on: [.leftMouseDown])
        statusBarItem.isVisible = true
        installStatusBarEventProbe()
        qrLog("updateStatusBar: width=\(getStatusBarWidth()) streamType=\(String(describing: SCContext.streamType)) target=\(String(describing: button.target)) action=\(String(describing: button.action))")
    }
}
