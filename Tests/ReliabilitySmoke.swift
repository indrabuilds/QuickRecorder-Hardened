@preconcurrency import AVFoundation
import Foundation
import Darwin

enum TestFailure: Error { case failed(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.failed(message) }
}

@main
struct ReliabilitySmoke {
    static let rate = 48_000.0
    static func audio(_ frame: Int, frequency: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        pcm.frameLength = 1024
        for channel in 0..<2 {
            for sample in 0..<1024 {
                pcm.floatChannelData![channel][sample] = Float(sin(Double(frame * 1024 + sample) * frequency * 2 * .pi / rate) * 0.1)
            }
        }
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description)
        try require(status == noErr, "audio format creation")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: Int64(frame * 1024), timescale: 48000),
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        let made = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: 1024,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        try require(made == noErr, "audio sample creation")
        try require(CMSampleBufferSetDataBufferFromAudioBufferList(buffer!,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.mutableAudioBufferList) == noErr, "audio data creation")
        return buffer!
    }

    static func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        for _ in 0..<2000 {
            if input.isReadyForMoreMediaData { return }
            if writer.status == .failed { throw writer.error ?? TestFailure.failed("writer failure") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TestFailure.failed("writer backpressure did not clear")
    }

    static func pixel() throws -> CVPixelBuffer {
        var p: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &p) == kCVReturnSuccess,
            "pixel buffer creation")
        CVPixelBufferLockBaseAddress(p!, [])
        memset(CVPixelBufferGetBaseAddress(p!), 64, CVPixelBufferGetDataSize(p!))
        CVPixelBufferUnlockBaseAddress(p!, [])
        return p!
    }

    static func makeMedia(_ path: URL, audioTracks: Int = 2,
                          codec: AVVideoCodecType? = nil, fragments: Bool = false) async throws -> AVAssetWriter {
        let fileType: AVFileType = path.pathExtension == "mov" ? .mov : (codec == nil ? .m4a : .mp4)
        let writer = try AVAssetWriter(outputURL: path, fileType: fileType)
        if fragments { writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600) }
        var inputs: [AVAssetWriterInput] = []
        for _ in 0..<audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
            ])
            try require(writer.canAdd(input), "can add audio")
            writer.add(input); inputs.append(input)
        }
        var video: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if let codec = codec {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 100000]
            ])
            try require(writer.canAdd(input), "can add video")
            writer.add(input); video = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        }
        try require(writer.startWriting(), "start writing")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            for (index, input) in inputs.enumerated() {
                try await ready(input, writer: writer)
                try require(input.append(try audio(frame, frequency: index == 0 ? 440 : 880)), "append audio")
            }
            if frame < 8, let input = video, let adaptor = adaptor {
                try await ready(input, writer: writer)
                try require(adaptor.append(try pixel(), withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "append video")
            }
        }
        return writer
    }

    static func fragmentChild(_ path: URL) async throws -> Never {
        let writer = try AVAssetWriter(outputURL: path, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 100000]
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        try require(writer.startWriting(), "fragment start")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<125 {
            try await ready(input, writer: writer)
            try require(adaptor.append(try pixel(), withPresentationTime: CMTime(value: Int64(frame), timescale: 5)), "fragment append")
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // Intentional process interruption, without finishWriting or destructors.
        _exit(0)
    }

    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fragment-child" {
            try await fragmentChild(URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickRecorder-native-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        let cycles = Int(ProcessInfo.processInfo.environment["QR_TEST_CYCLES"] ?? "100") ?? 100
        for cycle in 0..<cycles {
            let url = root.appendingPathComponent("cycle-\(cycle).m4a")
            let writer = try await makeMedia(url)
            try await RecordingReliability.finish(writer)
            let summary = try await RecordingReliability.validate(url,
                expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 2, minimumDuration: 0.2))
            try require(writer.status == .completed && summary.audioTracks == 2, "dual audio finalization \(cycle)")
            checks += 1
            if (cycle + 1) % 10 == 0 { print("Verified \(cycle + 1)/\(cycles) dual-audio writer cycles") }
        }
        for fileExtension in ["mov", "mp4"] {
            for codec in [AVVideoCodecType.h264, .hevc] {
                let url = root.appendingPathComponent("\(fileExtension)-\(codec.rawValue).\(fileExtension)")
                let writer = try await makeMedia(url, codec: codec)
                try await RecordingReliability.finish(writer)
                _ = try await RecordingReliability.validate(url,
                    expectation: RecordingMediaExpectation(video: true, minimumAudioTracks: 2, minimumDuration: 0.2))
                checks += 1
            }
        }

        let oneTrack = root.appendingPathComponent("one-track.m4a")
        try await RecordingReliability.finish(try await makeMedia(oneTrack, audioTracks: 1))
        do {
            _ = try await RecordingReliability.validate(oneTrack,
                expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 2))
            throw TestFailure.failed("missing audio track accepted")
        } catch is RecordingReliabilityError { checks += 1 }

        let corrupt = root.appendingPathComponent("corrupt.m4a")
        let raw = Data([0,0,0,8,102,116,121,112])
        try raw.write(to: corrupt)
        do {
            _ = try await RecordingReliability.validate(corrupt,
                expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 1))
            throw TestFailure.failed("corrupt container accepted")
        } catch {
            if error is TestFailure { throw error }
            try require(try Data(contentsOf: corrupt) == raw, "corrupt original was altered"); checks += 1
        }

        let final = root.appendingPathComponent("existing.m4a")
        let existing = Data("existing recording".utf8)
        try existing.write(to: final)
        let staged = RecordingReliability.stagingURL(for: final)
        try await RecordingReliability.finish(try await makeMedia(staged))
        do {
            try await RecordingReliability.publish(staged, to: final,
                expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 2))
            throw TestFailure.failed("existing output overwritten")
        } catch is RecordingReliabilityError {
            try require(try Data(contentsOf: final) == existing, "existing recording changed")
            try require(FileManager.default.fileExists(atPath: staged.path), "candidate lost after publish failure")
            checks += 1
        }
        let newFinal = root.appendingPathComponent("published.m4a")
        try await RecordingReliability.publish(staged, to: newFinal,
            expectation: RecordingMediaExpectation(video: false, minimumAudioTracks: 2))
        try require(FileManager.default.fileExists(atPath: newFinal.path), "validated output missing")
        checks += 1

        let untouched = root.appendingPathComponent("unknown.m4a")
        let unknownWriter = try AVAssetWriter(outputURL: untouched, fileType: .m4a)
        do {
            try await RecordingReliability.finish(unknownWriter)
            throw TestFailure.failed("unstarted writer accepted")
        } catch is RecordingReliabilityError { checks += 1 }

        let partial = root.appendingPathComponent("interrupted.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--fragment-child", partial.path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "fragment child")
        let fragmented = try await RecordingReliability.validate(partial,
            expectation: RecordingMediaExpectation(video: true, minimumAudioTracks: 0, minimumDuration: 10))
        try require(fragmented.duration >= 10, "interrupted fragments unreadable")
        checks += 1

        print("PASS: \(checks) native media checks, including \(cycles) repeated dual-audio recordings.")
        let receipt: [String: Any] = ["passed": checks, "syntheticCycles": cycles,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "physicalMicrophoneTested": false]
        let destination = ProcessInfo.processInfo.environment["QR_TEST_REPORT"] ?? root.appendingPathComponent("report.json").path
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination))
        try FileManager.default.removeItem(at: root)
    }
}
