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
            case .frame(let data, _, _):
                guard let format, let sample = Self.sampleBuffer(fromAnnexB: data, format: format) else { return }
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

    static func sampleBuffer(fromAnnexB data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data()
        for unit in nalUnits(data) {
            let type = unit[unit.startIndex] & 0x1F
            if type == 7 || type == 8 || type == 9 { continue } // parameter sets come from config packets; drop delimiters
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        guard !avcc.isEmpty else { return nil }

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
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        // Show each frame as soon as it's decoded: lowest latency, no clock to drift.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
