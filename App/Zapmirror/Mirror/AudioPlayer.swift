import AVFoundation
import Foundation
import os

/// Plays the phone's sound: 16-bit stereo PCM from the audio channel, through a small jitter buffer.
/// Latency stays low: playback starts once 50 ms are buffered, and anything beyond 150 ms is dropped.
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let buffer = OSAllocatedUnfairLock(initialState: SampleRing(capacity: 48_000 * 2)) // 1 s of stereo

    static let startFrames = 2_400  // 50 ms
    static let maxFrames = 7_200    // 150 ms
    static let keepFrames = 3_600   // 75 ms, after trimming

    var isMuted = false {
        didSet { engine.mainMixerNode.outputVolume = isMuted ? 0 : 1 }
    }

    /// `rate` in Hz; the samples are stereo (the phone component always sends two channels).
    func start(rate: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = buffer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let outputs = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard outputs.count >= 2, let left = outputs[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = outputs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            buffer.withLockUnchecked { $0.render(left: left, right: right, frames: Int(frameCount)) }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        source = node
    }

    /// Called on the audio thread with interleaved little-endian Int16 samples.
    func enqueue(_ pcm: Data) {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            buffer.withLockUnchecked { $0.write(samples) }
        }
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        buffer.withLock { $0.reset() }
    }
}

/// Interleaved stereo samples, written by the socket thread and read by the audio render thread.
struct SampleRing {
    private var samples: [Int16]
    private var readIndex = 0
    private var count = 0
    private var playing = false

    init(capacity: Int) { samples = [Int16](repeating: 0, count: capacity) }

    var frames: Int { count / 2 }

    mutating func reset() {
        readIndex = 0
        count = 0
        playing = false
    }

    mutating func write(_ input: UnsafeBufferPointer<Int16>) {
        for sample in input {
            if count == samples.count { // full: drop the oldest
                readIndex = (readIndex + 1) % samples.count
                count -= 1
            }
            samples[(readIndex + count) % samples.count] = Int16(littleEndian: sample)
            count += 1
        }
        if frames > AudioPlayer.maxFrames { // running behind: skip ahead rather than drift
            let drop = (frames - AudioPlayer.keepFrames) * 2
            readIndex = (readIndex + drop) % samples.count
            count -= drop
        }
    }

    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames wanted: Int) {
        if !playing, frames >= AudioPlayer.startFrames { playing = true }
        for i in 0..<wanted {
            guard playing, count >= 2 else {
                left[i] = 0
                right[i] = 0
                playing = false // ran dry: wait for the buffer to refill before playing again
                continue
            }
            left[i] = Float(samples[readIndex]) / 32_768
            right[i] = Float(samples[(readIndex + 1) % samples.count]) / 32_768
            readIndex = (readIndex + 2) % samples.count
            count -= 2
        }
    }
}
