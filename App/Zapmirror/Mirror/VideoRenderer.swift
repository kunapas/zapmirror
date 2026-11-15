import AVFoundation
import CoreMedia
import Foundation
import ZapmirrorPhone

/// Turns the phone's H.264 packets into sample buffers for an AVSampleBufferDisplayLayer, which decodes them in hardware.
/// The phone's encoder emits Annex B (start codes); Core Media wants each NAL unit prefixed by its 4-byte length.
final class VideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private let queue = DispatchQueue(label: "Zapmirror video")
    /// Gets every frame as well, and saves them while a recording is on.
    let recorder = Recorder()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Called on the video thread for every packet.
    func handle(_ packet: VideoPacket) {
        queue.sync {
            switch packet {
            case .size:
                break // the config packet that follows carries the new size's SPS/PPS
            case .config(let data):
                format = Self.formatDescription(fromAnnexB: data)
                if format == nil { mirrorLog.error("Couldn't read the video configuration (\(data.count) bytes)") }
            case .frame(let data, let pts, let keyFrame):
                guard let format, let avcc = Self.avcc(fromAnnexB: data) else { return }
                recorder.video(avcc, pts: pts, keyFrame: keyFrame, format: format)
                guard let sample = Self.sampleBuffer(avcc: avcc, format: format) else { return }
                let renderer = layer.sampleBufferRenderer
                if renderer.status == .failed {
                    mirrorLog.error("Video decoding failed: \(String(describing: renderer.error), privacy: .public); flushing")
                    renderer.flush()
                }
                renderer.enqueue(sample)
            }
        }
    }

    func clear() {
        queue.sync {
            format = nil
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    // MARK: - H.264

    /// NAL units in an Annex B buffer, without their start codes.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].code : bytes.count
            return end > start.payload ? Data(bytes[start.payload..<end]) : nil
        }
    }

    static func formatDescription(fromAnnexB data: Data) -> CMVideoFormatDescription? {
        let units = nalUnits(data)
        guard let sps = units.first(where: { $0.first.map { $0 & 0x1F == 7 } ?? false }),
              let pps = units.first(where: { $0.first.map { $0 & 0x1F == 8 } ?? false }) else { return nil }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// The frame's NAL units with 4-byte lengths in place of start codes, which is what Core Media and MP4 use.
    static func avcc(fromAnnexB data: Data) -> Data? {
        var avcc = Data()
        for unit in nalUnits(data) {
            let type = unit[unit.startIndex] & 0x1F
            if type == 7 || type == 8 || type == 9 { continue } // parameter sets come from config packets; drop delimiters
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        return avcc.isEmpty ? nil : avcc
    }

    /// A sample buffer for one frame. For the screen, pass no time: it's shown as soon as it's decoded. For a
    /// recording, pass the frame's time in the file and whether it's a key frame.
    static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription, time: CMTime? = nil,
                             keyFrame: Bool = true) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time ?? .invalid, decodeTimeStamp: .invalid)
        let status: OSStatus
        if time == nil {
            status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                               sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        } else {
            status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                               sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        }
        guard status == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if time == nil {
                // Show each frame as soon as it's decoded: lowest latency, no clock to drift.
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            } else if !keyFrame {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
