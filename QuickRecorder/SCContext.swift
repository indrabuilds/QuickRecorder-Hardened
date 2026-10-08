//
//  SCContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AVFAudio
import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications
import SwiftLAME
import SwiftUI
import AECAudioStream

class SCContext {
    static var trimingList = [URL]()
    static var firstFrame: CMSampleBuffer?
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession!
    static var previewSession: AVCaptureSession!
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0)
    static var screenArea: NSRect?
    static let audioEngine = AVAudioEngine()
    // Serializes the last sample callback with the transition to writer finalization.
    static let writerLock = NSRecursiveLock()
    static var isStoppingRecording = false
    static var microphoneSamplesWritten = 0
    static var systemSamplesWritten = 0
    static var microphoneBackend = MicrophoneBackend.none
    static var recordingOptions: RecordingOptions?
    static var recordingFailure: String?
    static var captureStartedAt: Date?
    static var lastMicrophoneArrival: Date?
    static var microphoneTapInstalled = false
    static var microphoneFormat: String?
    static var lastMicrophonePTS: CMTime?
    static var healthTimer: Timer?

    enum MicrophoneBackend: String {
        case none, audioEngine, echoCancellation, captureSession, screenCaptureKit
    }

    struct RecordingOptions {
        let microphone = ud.bool(forKey: "recordMic")
        let systemAudio = ud.bool(forKey: "recordWinSound")
        let mix = ud.bool(forKey: "remuxAudio")
        let echoCancellation = ud.bool(forKey: "enableAEC")
        let device = ud.string(forKey: "micDevice") ?? "default"
        let audioFormat = ud.string(forKey: "audioFormat") ?? "aac"
        let preview = ud.bool(forKey: "showPreview")
        let trim = ud.bool(forKey: "trimAfterRecord")
        let preventSleep = ud.bool(forKey: "preventSleep")
    }

    static func failRecording(_ reason: String) {
        writerLock.lock()
        let shouldStop = recordingFailure == nil && !isStoppingRecording
        if recordingFailure == nil { recordingFailure = reason }
        writerLock.unlock()
        if shouldStop { DispatchQueue.main.async { stopRecording() } }
    }

    static func startHealthMonitoring() {
        DispatchQueue.main.async {
            captureStartedAt = Date()
            healthTimer?.invalidate()
            let timer = Timer(timeInterval: 5, repeats: true) { _ in
                writerLock.lock()
                let stopping = isStoppingRecording
                let paused = isPaused
                let options = recordingOptions
                let backend = microphoneBackend
                let lastMic = lastMicrophoneArrival ?? captureStartedAt
                let writer = vW
                let path = filePath
                writerLock.unlock()
                guard !stopping, streamType != nil else { return }
                if writer?.status == .failed {
                    failRecording(writer?.error?.localizedDescription ?? "The media writer failed.")
                } else if let path = path,
                          let free = RecordingReliability.availableBytes(at: path.url),
                          free < 1024 * 1024 * 1024 {
                    failRecording("Recording stopped before the disk filled. Captured files have been retained.")
                } else if options?.microphone == true, backend != .none, !paused,
                          let arrival = lastMic, Date().timeIntervalSince(arrival) > 15 {
                    failRecording("Microphone samples stopped arriving. Captured files have been retained.")
                }
            }
            healthTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    static func appendMicrophoneSample(_ original: CMSampleBuffer) {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard !isStoppingRecording, !isPaused, let writer = vW else { return }
        lastMicrophoneArrival = Date()
        guard original.isValid, CMSampleBufferDataIsReady(original),
              let asbd = original.formatDescription?.audioStreamBasicDescription,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              original.presentationTimeStamp.isValid else {
            failRecording("The microphone delivered invalid audio samples.")
            return
        }
        let format = "\(asbd.mFormatID):\(asbd.mSampleRate):\(asbd.mChannelsPerFrame)"
        if let existing = microphoneFormat, existing != format {
            failRecording("The microphone format changed during recording. Earlier audio was retained.")
            return
        }
        microphoneFormat = format
        var sample = original
        if timeOffset.value > 0 {
            sample = adjustTime(sample: original, by: timeOffset) ?? original
        }
        if streamType == .systemaudio, startTime == nil, writer.status == .writing {
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            startTime = Date()
        }
        guard startTime != nil else { return }
        if let last = lastMicrophonePTS, CMTimeCompare(sample.presentationTimeStamp, last) < 0 {
            failRecording("Microphone timestamps stopped progressing normally.")
            return
        }
        if writer.status == .failed {
            failRecording(writer.error?.localizedDescription ?? "The microphone writer failed.")
            return
        }
        guard writer.status == .writing, let input = micInput,
              input.isReadyForMoreMediaData else { return }
        if input.append(sample) {
            microphoneSamplesWritten += 1
            lastMicrophonePTS = sample.presentationTimeStamp
        } else if writer.status == .failed {
            failRecording(writer.error?.localizedDescription ?? "The microphone writer rejected audio.")
        }
    }

    static func validMedia(at url: URL, video: Bool, minimumAudioTracks: Int = 0) -> Bool {
        guard let size = try? fd.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value > 0 else { return false }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard asset.isPlayable, seconds.isFinite, seconds > 0 else { return false }
        if video && asset.tracks(withMediaType: .video).isEmpty { return false }
        return asset.tracks(withMediaType: .audio).count >= minimumAudioTracks
    }
    static let AECEngine = AECAudioStream(sampleRate: 48000)
    static var backgroundColor: CGColor = CGColor.black
    static var filePath: String!
    static var filePath1: String!
    static var filePath2: String!
    static var audioFile: AVAudioFile?
    static var audioFile2: AVAudioFile?
    static var vW: AVAssetWriter!
    static var vwInput, awInput, micInput: AVAssetWriterInput!
    static var startTime: Date?
    static var timePassed: TimeInterval = 0
    static var stream: SCStream!
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    static func updateAvailableContentSync() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent? = nil

        updateAvailableContent { content in
            result = content
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
    
    private static func updateAvailableContent(completion: @escaping (SCShareableContent?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [self] content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.updateAvailableContent() {_ in}
                    }
                default:
                    print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                completion(nil) // 在错误情况下返回 nil
                return
            }

            availableContent = content
            if let displays = content?.displays, !displays.isEmpty {
                completion(content) // 返回成功获取的 content
            } else {
                print("There needs to be at least one display connected!".local)
                completion(nil) // 如果没有显示器连接，则返回 nil
            }
        }
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined: requestPermissions()
                default: print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                return
            }
            availableContent = content
            assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
            completion()
        }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return SCContext.availableContent!.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return SCContext.availableContent!.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).map({ $0.owningApplication }) {
            if !apps.contains(app!) { apps.append(app!) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        var windows = [SCWindow]()
        windows = availableContent!.windows.filter {
            guard let app =  $0.owningApplication,
                  let title = $0.title else {//, !title.isEmpty else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter({$0.isOnScreen == true}) }
        if hideSelf && ud.bool(forKey: "hideSelf") { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon!.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    static func getFilePath(capture: Bool = false) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return ud.string(forKey: "saveDirectory")! + (capture ? "/Capturing at ".local : "/Recording at ".local) + dateFormatter.string(from: Date())
    }
    
    static func updateAudioSettings(format: String = ud.string(forKey: "audioFormat") ?? "", rate: Int = 48000) -> [String : Any] {
        var audioSettings: [String : Any] = [AVSampleRateKey : rate, AVNumberOfChannelsKey : 2] // reset audioSettings
        var bitRate = ud.integer(forKey: "audioQuality") * 1000
        if rate < 44100 { bitRate = min(64000, bitRate / 2) }
        switch format {
        case AudioFormat.mp3.rawValue: fallthrough
        case AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            audioSettings[AVFormatIDKey] = ud.string(forKey: "videoFormat") != VideoFormat.mp4.rawValue ? kAudioFormatOpus : kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] =  bitRate
        default:
            assertionFailure("unknown audio format while setting audio settings: ".local + (ud.string(forKey: "audioFormat") ?? "[no defaults]".local))
        }
        return audioSettings
    }
    
    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black  }
        if color == BackgroundType.wallpaper.rawValue { return CGColor.black }
        switch color {
            case "clear": backgroundColor = CGColor.clear
            case "black": backgroundColor = CGColor.black
            case "white": backgroundColor = CGColor.white
            case "gray": backgroundColor = NSColor.systemGray.cgColor
            case "yellow": backgroundColor = NSColor.systemYellow.cgColor
            case "orange": backgroundColor = NSColor.systemOrange.cgColor
            case "green": backgroundColor = NSColor.systemGreen.cgColor
            case "blue": backgroundColor = NSColor.systemBlue.cgColor
            case "red": backgroundColor = NSColor.systemRed.cgColor
            default: backgroundColor = ud.cgColor(forKey: "userColor") ?? CGColor.black
        }
        return backgroundColor
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    
    private static func requestPermissions() {
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs screen recording permissions, even if you only intend on recording audio.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            NSApp.terminate(self)
        }
    }
    
    static func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized, .restricted, .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                let alert = createAlert(title: "Permission Required",
                                                           message: "QuickRecorder needs this permission to record your camera or mobile device.",
                                                           button1: "Open Settings",
                                                           button2: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        @unknown default:
            break
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        do {
            var wallpaper: NSImage?
            try wallpaper = NSImage(data: Data(contentsOf: url))
            if let w = wallpaper { return w }
        } catch {
            print("load wallpaper error: \(error)")
        }
        return nil
    }
    
    static func getRecordingSize() -> String {
        do {
            let fileAttr = try fd.attributesOfItem(atPath: filePath)
            let byteFormat = ByteCountFormatter()
            byteFormat.allowedUnits = [.useMB]
            byteFormat.countStyle = .file
            return byteFormat.string(fromByteCount: fileAttr[FileAttributeKey.size] as! Int64)
        } catch {
            print(String(format: "failed to fetch file for size indicator: %@".local, error.localizedDescription))
        }
        return "Unknown".local
    }
    
    static func getRecordingLength() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        if isPaused { return formatter.string(from: timePassed) ?? "Unknown".local }
        timePassed = Date.now.timeIntervalSince(startTime ?? Date.now)
        return formatter.string(from: timePassed) ?? "Unknown".local
    }
    
    static func isCameraRunning() -> Bool {
        var preview = false
        var capture = false
        if let session = previewSession { preview = session.isRunning }
        if let session = captureSession { capture = session.isRunning }
        return (preview || capture)
    }
    
    static func pauseRecording() {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard !isStoppingRecording, streamType != nil else { return }
        isPaused.toggle()
        PopoverState.shared.isPaused = isPaused
        if !isPaused {
            isResume = true
            startTime = Date.now.addingTimeInterval(-1) - SCContext.timePassed
        }
    }
    
    static func stopRecording() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { stopRecording() }
            return
        }
        writerLock.lock()
        guard !isStoppingRecording, let type = streamType, let originalPath = filePath else {
            writerLock.unlock()
            return
        }
        isStoppingRecording = true
        let options = recordingOptions ?? RecordingOptions()
        let backend = microphoneBackend
        let writer = (type != .systemaudio || options.microphone) ? vW : nil
        let capturedStream = stream
        let micSamples = microphoneSamplesWritten
        let systemSamples = systemSamplesWritten
        let path1 = filePath1
        let path2 = filePath2
        let captureFailure = recordingFailure
        writerLock.unlock()
        healthTimer?.invalidate()
        healthTimer = nil
        autoStop = 0
        AppDelegate.shared.stopGlobalMouseMonitor()
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        controlPanel.close()

        Task { @MainActor in
            var failure = captureFailure
            if let writer = writer {
                do { try await RecordingReliability.finish(writer) }
                catch { failure = failure ?? error.localizedDescription }
            }

            // Source objects remain alive while finishWriting flushes queued media.
            // The sample gate was closed above, so capture cannot append late data.
            if let capturedStream = capturedStream {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    capturedStream.stopCapture { _ in continuation.resume() }
                }
            }
            switch backend {
            case .audioEngine:
                if microphoneTapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
                microphoneTapInstalled = false
                audioEngine.stop()
            case .echoCancellation: try? AECEngine.stopAudioUnit()
            case .captureSession: AudioRecorder.shared.stop()
            case .none, .screenCaptureKit: break
            }
            stream = nil
            audioFile = nil
            audioFile2 = nil

            defer {
                if options.preventSleep { SleepPreventer.shared.allowSleep() }
                if camWindow.isVisible { camWindow.close() }
                if deviceWindow.isVisible { deviceWindow.close() }
                previewSession?.stopRunning()
                captureSession?.stopRunning()
                if let area = NSApp.windows.first(where: { $0.title == "Area Overlayer".local }) { area.close() }
                writerLock.lock()
                isPaused = false
                isResume = false
                isStoppingRecording = false
                microphoneBackend = .none
                captureStartedAt = nil
                lastMicrophoneArrival = nil
                microphoneFormat = nil
                lastMicrophonePTS = nil
                recordingOptions = nil
                recordingFailure = nil
                vW = nil
                vwInput = nil
                awInput = nil
                micInput = nil
                lastPTS = nil
                streamType = nil
                screen = nil
                window = nil
                application = nil
                startTime = nil
                recordCam = ""
                recordDevice = ""
                firstFrame = nil
                writerLock.unlock()
                hideMousePointer = false
                AppDelegate.shared.presenterType = "OFF"
                updateStatusBar()
            }

            do {
                if let failure = failure { throw RecordingReliabilityError.writer(failure) }
                if options.microphone && micSamples == 0 {
                    throw RecordingReliabilityError.invalid("no microphone samples were written")
                }
                var finalURL = originalPath.url
                if type == .systemaudio {
                    guard let systemPath = path1 else {
                        throw RecordingReliabilityError.invalid("the system audio file is missing")
                    }
                    _ = try await RecordingReliability.validate(systemPath.url,
                        expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 1))
                    if options.microphone {
                        guard let microphonePath = path2 else {
                            throw RecordingReliabilityError.invalid("the microphone file is missing")
                        }
                        _ = try await RecordingReliability.validate(microphonePath.url,
                            expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 1))
                    }
                    if options.microphone && options.mix {
                        let document = try qmaPackageHandle.load(from: finalURL)
                        let manager = AudioPlayerManager()
                        manager.loadAudioFiles(format: document.info.format, package: finalURL,
                                               encoder: document.info.encoder, saveMP3: document.info.exportMP3)
                        manager.sysVol = document.info.sysVol
                        manager.micVol = document.info.micVol
                        let extensionName = document.info.exportMP3 ? "mp3" : document.info.format
                        let destination = finalURL.deletingPathExtension().appendingPathExtension(extensionName)
                        finalURL = try await withCheckedThrowingContinuation { continuation in
                            manager.saveFile(destination, saveAsMP3: document.info.exportMP3) {
                                continuation.resume(with: $0)
                            }
                        }
                    } else if !options.microphone && options.audioFormat == "mp3" {
                        let destination = systemPath.url.deletingPathExtension().appendingPathExtension("mp3")
                        let staged = RecordingReliability.stagingURL(for: destination)
                        try await m4a2mp3(inputUrl: systemPath.url, outputUrl: staged)
                        try await RecordingReliability.publish(staged, to: destination,
                            expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 1))
                        try? fd.removeItem(atPath: systemPath)
                        finalURL = destination
                    }
                } else {
                    let expectedAudio = (options.microphone ? 1 : 0) + (systemSamples > 0 ? 1 : 0)
                    _ = try await RecordingReliability.validate(finalURL,
                        expectation: RecordingMediaExpectation(video: true, minimumAudioTracks: expectedAudio))
                    if options.microphone && options.systemAudio && options.mix {
                        let size = ((try? fd.attributesOfItem(atPath: originalPath)[.size]) as? NSNumber)?.int64Value ?? 0
                        try RecordingReliability.requireSpace(at: finalURL, bytes: size + 512 * 1024 * 1024)
                        finalURL = try await withCheckedThrowingContinuation { continuation in
                            mixAudioTracks(videoURL: originalPath.url) { continuation.resume(with: $0) }
                        }
                    }
                }

                if !options.preview {
                    showNotification(title: "Recording Completed".local,
                                     body: String(format: "File saved to: %@".local, finalURL.path),
                                     id: "quickrecorder.completed.\(UUID().uuidString)")
                } else {
                    let icon: NSImage? = type == .systemaudio
                        ? NSImage(named: options.microphone && !options.mix ? "qmaIcon" : "audioIcon") : nil
                    showPreview(path: finalURL.path, image: icon)
                }
                if options.trim && type != .systemaudio {
                    AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: finalURL),
                                                       title: finalURL.lastPathComponent, only: false)
                }
            } catch {
                writeRecoveryReport(at: originalPath.url, reason: error.localizedDescription,
                                    backend: backend, writer: writer,
                                    microphoneSamples: micSamples, systemSamples: systemSamples)
                showNotification(title: "Failed to save file".local,
                                 body: "\(error.localizedDescription)\nCaptured files retained at \(originalPath)",
                                 id: "quickrecorder.error.\(UUID().uuidString)")
            }
        }
    }

    static func writeRecoveryReport(at original: URL, reason: String,
                                    backend: MicrophoneBackend, writer: AVAssetWriter?,
                                    microphoneSamples: Int, systemSamples: Int) {
        let report: [String: Any] = [
            "recording": original.lastPathComponent,
            "failure": reason,
            "microphoneBackend": backend.rawValue,
            "writerStatus": writer?.status.rawValue ?? -1,
            "writerError": writer?.error?.localizedDescription ?? "",
            "microphoneSampleBuffers": microphoneSamples,
            "systemAudioSampleBuffers": systemSamples,
            "availableBytes": RecordingReliability.availableBytes(at: original) ?? -1,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let destination = original.pathExtension == "qma"
            ? original.appendingPathComponent("recovery.json")
            : original.appendingPathExtension("recovery.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination, options: .atomic)
        }
    }

    static func showPreview(path: String, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") { return }
        var previewImage: NSImage?
        let previewURL = fd.temporaryDirectory.appendingPathComponent("qr-preview.jpg")
        if image == nil { firstFrame?.nsImage?.saveToFile(previewURL, type: .jpeg) }
        
        if let i = image { previewImage = i } else { previewImage = NSImage(contentsOf: previewURL) }
        if let previewImage = previewImage, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(self)
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(ud.integer(forKey: "audioQuality"))),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
    
    static func trimVideo() {
        if ud.bool(forKey: "trimAfterRecord") {
            let fileURL = filePath.url
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: fileURL), title: fileURL.lastPathComponent, only: false)
        }
    }
    
    static func getCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        var discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        }
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    static func getiDevice() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getCurrentMic() -> AVCaptureDevice? {
        let deviceName = ud.string(forKey: "micDevice")
        return getMicrophone().first(where: { $0.localizedName == deviceName })
    }
    
    /*static func getChannelCount() -> Int? {
        if let device = getCurrentMic() {
            if let channels = device.formats.first?.formatDescription.audioChannelLayout?.numberOfChannels {
                return channels
            }
            
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let channelCount = audioStreamBasicDescription.mChannelsPerFrame
                return max(2, Int(channelCount))
            }
        }
        return getDefaultChannelCount()
    }
    
    static func getDefaultChannelCount() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取通道数
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // 查询流配置信息
        var streamConfig: UnsafeMutableAudioBufferListPointer?
        propertySize = 0
        
        // 先获取属性大小
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr else {
            print("Failed to get size for stream configuration")
            return nil
        }
        
        // 分配内存以存储音频流配置
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }
        
        let configStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard configStatus == noErr else {
            print("Failed to get stream configuration")
            return nil
        }
        
        streamConfig = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // 计算通道总数
        var totalChannels = 0
        for buffer in streamConfig! {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return max(2, totalChannels)
    }*/
    
    static func getSampleRate() -> Int? {
        if let device = getCurrentMic() {
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let sampleRate = audioStreamBasicDescription.mSampleRate
                return Int(sampleRate)
            }
        }
        return getDefaultSampleRate()
    }
    
    static func getDefaultSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取采样率
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout.size(ofValue: sampleRate))
        
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        
        guard sampleRateStatus == noErr else {
            print("Failed to get sample rate for the default input device")
            return nil
        }
        
        return Int(sampleRate)
    }
    
    static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetFormatDescription(sample) != nil else { return nil }
        
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(CMSampleBufferGetNumSamples(sample)))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingInfo.count, arrayToFill: &timingInfo, entriesNeededOut: nil)
        
        for i in 0..<timingInfo.count {
            timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
        }
        
        var outSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timingInfo.count, sampleTimingArray: &timingInfo, sampleBufferOut: &outSampleBuffer)
        
        return outSampleBuffer
    }
    
    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send：\(error.localizedDescription)") }
        }
    }
    
    static func mixAudioTracks(videoURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")
        
        let asset = AVAsset(url: videoURL)
        let outputURL = videoURL.deletingPathExtension().deletingPathExtension()
        let audioOutputURL = RecordingReliability.stagingURL(for: videoURL.deletingPathExtension())
        let finalStagedURL = RecordingReliability.stagingURL(for: outputURL)
        let audioOnlyComposition = AVMutableComposition()
        
        let fileEnding = videoURL.pathExtension
        var fileType: AVFileType?
        switch fileEnding {
        case VideoFormat.mov.rawValue: fileType = AVFileType.mov
        case VideoFormat.mp4.rawValue: fileType = AVFileType.mp4
        default: assertionFailure("loaded unknown video format".local)
        }
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
            return
        }
        
        for audioTrack in audioTracks {
            if let compositionAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                    return
                }
            }
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioOnlyComposition.tracks(withMediaType: .audio).map {
            AVMutableAudioMixInputParameters(track: $0)
        }
        
        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "AudioExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session."])))
            return
        }
        audioExportSession.outputURL = audioOutputURL
        audioExportSession.outputFileType = fileType ?? .mp4
        audioExportSession.audioMix = audioMix
        
        audioExportSession.exportAsynchronously {
            /*var exportStatus: AVAssetExportSession.Status = .unknown
            
            // Loop until export session is completed, failed, or cancelled
            while exportStatus != .completed && exportStatus != .failed && exportStatus != .cancelled {
                exportStatus = audioExportSession.status
                Thread.sleep(forTimeInterval: 0.1)
            }*/
            
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: audioOutputURL)
                let composition = AVMutableComposition()
                
                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    completion(.failure(NSError(domain: "VideoTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get video track."])))
                    return
                }
                
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "VideoTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert video track: \(error.localizedDescription)"])))
                    return
                }
                
                let audioTracks = audioAsset.tracks(withMediaType: .audio)
                guard audioTracks.count >= 1 else {
                    completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
                    return
                }
                
                for audioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                        } catch {
                            completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                            return
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    completion(.failure(NSError(domain: "ExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session."])))
                    return
                }
                
                exportSession.outputURL = finalStagedURL
                exportSession.outputFileType = fileType ?? .mp4
                
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        Task {
                            do {
                                try await RecordingReliability.publish(finalStagedURL, to: outputURL,
                                    expectation: RecordingMediaExpectation(video: true, minimumAudioTracks: 1))
                                try? fd.removeItem(at: videoURL)
                                try? fd.removeItem(at: audioOutputURL)
                                completion(.success(outputURL))
                            } catch { completion(.failure(error)) }
                        }
                    case .failed:
                        completion(.failure(exportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
                    case .cancelled:
                        completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
                    default:
                        break
                    }
                }
            case .failed:
                completion(.failure(audioExportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
            case .cancelled:
                completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
            default:
                break
            }
        }
    }
}
