@preconcurrency import AVFoundation
import Foundation

struct RecordingMediaExpectation {
    let video: Bool
    let minimumAudioTracks: Int
    var minimumDuration: Double = 0
}

struct RecordingMediaSummary: Codable {
    let bytes: Int64
    let duration: Double
    let videoTracks: Int
    let audioTracks: Int
}

enum RecordingReliabilityError: LocalizedError {
    case writer(String)
    case invalid(String)
    case destinationExists(String)
    case lowSpace(Int64)

    var errorDescription: String? {
        switch self {
        case .writer(let reason): return "The recording writer failed: \(reason)"
        case .invalid(let reason): return "The recording failed validation: \(reason)"
        case .destinationExists(let path): return "An existing recording was preserved at \(path)."
        case .lowSpace(let bytes):
            return "There is insufficient free space (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
        }
    }
}

enum RecordingReliability {
    // The caller must close its sample gate before entering this method. Keep the
    // capture devices alive until this returns: stopping a device can invalidate
    // formats while the writer still has queued compression work.
    static func finish(_ writer: AVAssetWriter) async throws {
        switch writer.status {
        case .completed: return
        case .writing:
            for input in writer.inputs { input.markAsFinished() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw RecordingReliabilityError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
            }
        case .failed, .cancelled, .unknown:
            throw RecordingReliabilityError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        @unknown default:
            throw RecordingReliabilityError.writer("unknown writer state")
        }
    }

    static func validate(_ url: URL, expectation: RecordingMediaExpectation) async throws -> RecordingMediaSummary {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else {
            throw RecordingReliabilityError.invalid("the output is empty")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration >= expectation.minimumDuration else {
            throw RecordingReliabilityError.invalid("the duration is missing or implausible")
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !expectation.video || !videos.isEmpty else {
            throw RecordingReliabilityError.invalid("the video track is missing")
        }
        guard audios.count >= expectation.minimumAudioTracks else {
            throw RecordingReliabilityError.invalid("an expected audio track is missing")
        }

        // Creating an AVURLAsset alone does not decode AAC packets. Decode every
        // audio track before publishing; stream the samples without retaining them.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    for track in audios { try decodeAudio(asset: asset, track: track) }
                    if let video = videos.first { try decodeFirstVideoFrame(asset: asset, track: video) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        return RecordingMediaSummary(bytes: bytes.int64Value, duration: duration,
                                     videoTracks: videos.count, audioTracks: audios.count)
    }

    private static func decodeAudio(asset: AVAsset, track: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingReliabilityError.invalid("audio decoder setup failed") }
        reader.add(output)
        guard reader.startReading() else {
            throw RecordingReliabilityError.invalid(reader.error?.localizedDescription ?? "audio could not be opened")
        }
        var samples = 0
        while let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            guard sample.isValid, CMSampleBufferGetNumSamples(sample) > 0 else {
                reader.cancelReading()
                throw RecordingReliabilityError.invalid("invalid decoded audio samples")
            }
            samples += 1
        }
        guard reader.status == .completed, samples > 0 else {
            throw RecordingReliabilityError.invalid(reader.error?.localizedDescription ?? "audio decoding did not complete")
        }
    }

    private static func decodeFirstVideoFrame(asset: AVAsset, track: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingReliabilityError.invalid("video decoder setup failed") }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil else {
            throw RecordingReliabilityError.invalid(reader.error?.localizedDescription ?? "video could not be decoded")
        }
        reader.cancelReading()
    }

    static func stagingURL(for final: URL) -> URL {
        final.deletingLastPathComponent()
            .appendingPathComponent(".\(final.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).in-progress")
            .appendingPathExtension(final.pathExtension)
    }

    @discardableResult
    static func publish(_ candidate: URL, to final: URL,
                        expectation: RecordingMediaExpectation) async throws -> RecordingMediaSummary {
        let summary = try await validate(candidate, expectation: expectation)
        guard !FileManager.default.fileExists(atPath: final.path) else {
            throw RecordingReliabilityError.destinationExists(final.path)
        }
        // Staging is in the destination directory. moveItem does not overwrite an
        // existing file if another process creates it after the check.
        try FileManager.default.moveItem(at: candidate, to: final)
        return summary
    }

    static func availableBytes(at url: URL) -> Int64? {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        return (try? FileManager.default.attributesOfFileSystem(forPath: existing.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static func requireSpace(at url: URL, bytes: Int64) throws {
        if let available = availableBytes(at: url), available < bytes {
            throw RecordingReliabilityError.lowSpace(available)
        }
    }
}
