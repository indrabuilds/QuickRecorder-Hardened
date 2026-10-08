import AppKit
import CoreGraphics
import Darwin
guard CGPreflightPostEventAccess() else {
    print("Native UI tests require existing permission to post mouse events.")
    exit(4)
}
let args = CommandLine.arguments
if args.count == 4 {
 let p = CGPoint(x: Double(args[1])!, y: NSScreen.screens[0].frame.maxY-Double(args[2])!)
 CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)
 usleep(250000)
 if args[3] == "move" { exit(0) }
 CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)
 usleep(100000)
 CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)
 usleep(250000)
}
