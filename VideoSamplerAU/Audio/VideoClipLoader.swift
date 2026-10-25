@preconcurrency import AVFoundation
import Foundation

struct DecodedAudioClip {
    var left: [Float]
    var right: [Float]
    var sampleRate: Double
}

enum VideoClipLoaderError: LocalizedError {
    case inaccessibleFile
    case noAudioTrack
    case cannotCreateReader
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .inaccessibleFile: return "The video file cannot be accessed."
        case .noAudioTrack: return "This video does not contain an audio track."
        case .cannotCreateReader: return "The audio decoder could not be created."
        case let .decodingFailed(message): return "Audio decoding failed: \(message)"
        }
    }
}

private extension Error {
    var diagnosticDescription: String {
        let error = self as NSError
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            " | \($0.domain) \($0.code): \($0.localizedDescription)"
        } ?? ""
        return "\(error.domain) \(error.code): \(error.localizedDescription)\(underlying)"
    }
}

enum VideoClipLoader {
    // copyNextSampleBuffer is blocking, and CoreMedia itself schedules decode
    // work. Running many readers on Swift's cooperative executor can starve
    // that work when a host restores all pads at once. Use a dedicated GCD
    // queue; serial readers also keep decoder/memory pressure bounded.
    private static let pcmDecodeQueue = DispatchQueue(
        label: "com.fingersonic.video-sampler.pcm-decode",
        qos: .userInitiated
    )

    static func decode(url: URL, start: Double, end: Double) async throws -> DecodedAudioClip {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw VideoClipLoaderError.decodingFailed(error.diagnosticDescription)
        }
        guard let track = tracks.first else { throw VideoClipLoaderError.noAudioTrack }

        let duration: Double
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            throw VideoClipLoaderError.decodingFailed(error.diagnosticDescription)
        }
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let clipStart = min(max(0, start), safeDuration)
        let clipEnd = min(max(clipStart + 0.05, end), safeDuration)
        guard clipEnd > clipStart else { throw VideoClipLoaderError.noAudioTrack }

        return try await withCheckedThrowingContinuation { continuation in
            pcmDecodeQueue.async {
                continuation.resume(with: Result {
                    try decodePCM(asset: asset, track: track, start: clipStart, end: clipEnd)
                })
            }
        }
    }

    private static func decodePCM(
        asset: AVURLAsset, track: AVAssetTrack, start clipStart: Double, end clipEnd: Double
    ) throws -> DecodedAudioClip {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoClipLoaderError.decodingFailed(error.diagnosticDescription)
        }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: clipStart, preferredTimescale: 60_000),
            duration: CMTime(seconds: clipEnd - clipStart, preferredTimescale: 60_000)
        )

        // Decode only the selected range. Unlike AVAudioFile, AVAssetReader is
        // reliable for AAC inside both MP4 and QuickTime MOV containers.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoClipLoaderError.cannotCreateReader }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoClipLoaderError.decodingFailed(
                reader.error?.diagnosticDescription ?? "The reader could not start."
            )
        }

        var left: [Float] = []
        var right: [Float] = []
        var sampleRate = 0.0
        let estimatedFrames = Int((clipEnd - clipStart) * 48_000)
        left.reserveCapacity(estimatedFrames)
        right.reserveCapacity(estimatedFrames)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            let stream = streamDescription.pointee
            let channelCount = max(1, Int(stream.mChannelsPerFrame))
            if sampleRate == 0 { sampleRate = stream.mSampleRate }

            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Int16>.size * channelCount else { continue }
            var samples = [Int16](
                repeating: 0,
                count: byteCount / MemoryLayout<Int16>.size
            )
            let copyStatus = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw VideoClipLoaderError.decodingFailed(
                    "PCM buffer copy failed with status \(copyStatus)."
                )
            }

            let frameCount = min(
                CMSampleBufferGetNumSamples(sampleBuffer),
                samples.count / channelCount
            )
            for frame in 0..<frameCount {
                let base = frame * channelCount
                let first = Float(samples[base]) / 32_768.0
                left.append(first)
                right.append(
                    channelCount > 1
                        ? Float(samples[base + 1]) / 32_768.0
                        : first
                )
            }
        }

        if reader.status == .failed {
            throw VideoClipLoaderError.decodingFailed(
                reader.error?.diagnosticDescription ?? "The reader stopped unexpectedly."
            )
        }
        guard !left.isEmpty, sampleRate > 0 else { throw VideoClipLoaderError.noAudioTrack }
        return DecodedAudioClip(left: left, right: right, sampleRate: sampleRate)
    }
}
