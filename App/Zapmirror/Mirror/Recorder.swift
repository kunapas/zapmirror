import AVFoundation
import CoreMedia
import Foundation

/// Saves what's being mirrored to an MP4 file.
///
/// The video is the phone's own H.264 stream, written as it arrives: nothing is re-encoded, so recording costs almost
/// no CPU and loses no quality. The sound (raw PCM from the phone) is compressed to AAC.
///
/// An MP4's picture size is fixed, so when the phone rotates the recording carries on in a new file, numbered
/// " (2)", " (3)"…
final class Recorder: @unchecked Sendable {
    enum Event: Sendable {
        /// A file was finished and is ready to open.
        case saved(URL)
        case failed(String)
    }

    /// Called off the main thread when a file is finished or recording fails.
    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "Zapmirror recorder")
    /// The file the user asked for; nil when not recording. Parts after a rotation derive their names from it.
    private var requested: URL?
    private var part = 1
    private var audioRate: Double?
    /// Set between Stop and the last frame.
    private var stopping = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    /// The phone's timestamp of the file's first frame, which becomes time zero.
    private var firstPTS: UInt64 = 0
    private var lastVideoTime = CMTime.invalid
    /// When the file's first frame arrived, by the Mac's clock: the file ends this long after its start.
    private var startedAt = Date()
    /// Where in the file the sound starts, and how many frames of it have been written since.
    private var audioStart = CMTime.invalid
    private var audioFrames: Int64 = 0

    // MARK: - Control

    /// Starts recording into `url`. The file begins at the next key frame; ask the phone for one to start at once.
    func start(to url: URL) {
        queue.async {
            self.stopping = false
            self.requested = url
            self.part = 1
        }
    }

    /// Stops and saves. With `afterNextFrame`, the file is closed once one more frame has arrived (or shortly after,
    /// if none does): ask the phone for a frame first, so a recording of a still screen ends when it was stopped, not
    /// at its last change.
    func stop(afterNextFrame: Bool = false) {
        queue.async {
            guard afterNextFrame, self.writer != nil else {
                self.requested = nil
                self.stopping = false
                self.finish()
                return
            }
            self.stopping = true
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                guard self.stopping else { return }
                self.stopping = false
                self.requested = nil
                self.finish()
            }
        }
    }

    /// The phone's sound is flowing at `rate` Hz (stereo), or nil: it stopped, or there is none.
    func soundAvailable(rate: Double?) {
        queue.async { self.audioRate = rate }
    }

    // MARK: - Data

    /// One frame (AVCC), with the phone's timestamp in microseconds. Called for every frame, recording or not.
    func video(_ avcc: Data, pts: UInt64, keyFrame: Bool, format: CMVideoFormatDescription) {
        queue.async {
            guard let requested = self.requested else { return }
            if self.writer != nil, let current = self.videoFormat, !CFEqual(current, format) {
                self.finish() // the phone rotated: continue in a new file
                self.part += 1
            }
            if self.writer == nil {
                guard keyFrame else { return } // a file has to start with a key frame
                self.begin(Self.url(requested, part: self.part), format: format, firstPTS: pts)
            }
            guard let input = self.videoInput, self.writer?.status == .writing, pts >= self.firstPTS else { return }
            let time = CMTime(value: CMTimeValue(pts - self.firstPTS), timescale: 1_000_000)
            // Times must increase; a frame that can't be taken right now is dropped rather than queued without limit.
            guard !self.lastVideoTime.isValid || time > self.lastVideoTime, input.isReadyForMoreMediaData,
                  let sample = VideoRenderer.sampleBuffer(avcc: avcc, format: format, time: time, keyFrame: keyFrame)
            else { return }
            if input.append(sample) {
                self.lastVideoTime = time
                if self.stopping { // that was the closing frame
                    self.stopping = false
                    self.requested = nil
                    self.finish()
                }
            } else {
                self.fail()
            }
        }
    }

    /// Interleaved 16-bit little-endian stereo samples, as they arrive from the phone.
    func audio(_ pcm: Data) {
        queue.async {
            guard let input = self.audioInput, let format = self.audioFormat, let rate = self.audioRate,
                  self.writer?.status == .writing, self.lastVideoTime.isValid else { return }
            let frames = pcm.count / 4
            guard frames > 0 else { return }
            // The sound carries no timestamps: it starts where the picture is now, then runs on its own sample count.
            if !self.audioStart.isValid { self.audioStart = self.lastVideoTime }
            let time = self.audioStart + CMTime(value: self.audioFrames, timescale: CMTimeScale(rate))
            self.audioFrames += Int64(frames)
            guard input.isReadyForMoreMediaData,
                  let sample = Self.audioBuffer(pcm.prefix(frames * 4), frames: frames, time: time, format: format) else { return }
            if !input.append(sample) { self.fail() }
        }
    }

    // MARK: - Files

    /// "Recording.mp4" for the first part, "Recording (2).mp4" for the next…
    static func url(_ base: URL, part: Int) -> URL {
        guard part > 1 else { return base }
        let name = base.deletingPathExtension().lastPathComponent + " (\(part))"
        return base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(base.pathExtension)
    }

    private func begin(_ url: URL, format: CMVideoFormatDescription, firstPTS: UInt64) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // No output settings: the frames are stored as they are.
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(video)

            var audio: AVAssetWriterInput?
            if let rate = audioRate, let description = Self.pcmFormat(rate: rate) {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audio = input
                    audioFormat = description
                }
            }
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            mirrorLog.notice("Recording started\(audio == nil ? " (no sound)" : "", privacy: .public)")
            videoInput = video
            audioInput = audio
            videoFormat = format
            self.firstPTS = firstPTS
            startedAt = Date()
            lastVideoTime = .invalid
            audioStart = .invalid
            audioFrames = 0
        } catch {
            requested = nil
            onEvent?(.failed(error.localizedDescription))
        }
    }

    private func finish() {
        guard let writer else { return }
        let hadFrames = lastVideoTime.isValid
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        self.writer = nil
        videoInput = nil
        audioInput = nil
        videoFormat = nil
        let url = writer.outputURL
        let report = onEvent
        // A still screen sends few frames. End the file at the moment recording stopped, so the last frame stays up
        // until then and the picture is as long as the sound.
        let end = CMTime(seconds: Date().timeIntervalSince(startedAt), preferredTimescale: 1_000_000)
        if hadFrames, writer.status == .writing, end > lastVideoTime { writer.endSession(atSourceTime: end) }
        guard hadFrames, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url) // nothing was recorded
            return
        }
        nonisolated(unsafe) let finished = writer // only read again inside its own completion handler
        finished.finishWriting {
            if finished.status == .completed {
                report?(.saved(url))
            } else {
                report?(.failed(finished.error?.localizedDescription ?? "The recording couldn't be saved."))
            }
        }
    }

    private func fail() {
        let message = writer?.error?.localizedDescription ?? "The recording couldn't be written."
        requested = nil
        writer?.cancelWriting()
        writer = nil
        videoInput = nil
        audioInput = nil
        videoFormat = nil
        onEvent?(.failed(message))
    }

    // MARK: - Sound buffers

    private static func pcmFormat(rate: Double) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format
    }

    private static func audioBuffer(_ pcm: Data, frames: Int, time: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pcm.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: pcm.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = pcm.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
