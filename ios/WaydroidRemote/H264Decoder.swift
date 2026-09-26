import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public final class H264Decoder {
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    public var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?

    private var spsData: Data?
    private var ppsData: Data?

    public init() {}

    deinit {
        invalidateSession()
    }

    public func invalidateSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        spsData = nil
        ppsData = nil
    }

    /// Ingests a raw H.264 packet received from scrcpy stream.
    public func decodePacket(data: Data, pts: Int64, isConfig: Bool, isKeyFrame: Bool) {
        // Split packet into NAL units (delimited by 0x00000001 or 0x000001)
        let nalUnits = extractNalUnits(from: data)

        var convertedSliceData = Data()

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F

            switch nalType {
            case 7: // SPS
                spsData = nal
                checkAndInitFormatDescription()
            case 8: // PPS
                ppsData = nal
                checkAndInitFormatDescription()
            case 5, 1: // IDR or Non-IDR Slice
                // Convert to AVCC format (4-byte big-endian length prefix + NAL data)
                var length = UInt32(nal.count).bigEndian
                convertedSliceData.append(Data(bytes: &length, count: 4))
                convertedSliceData.append(nal)
            default:
                // Other NAL types (SEI, etc.)
                var length = UInt32(nal.count).bigEndian
                convertedSliceData.append(Data(bytes: &length, count: 4))
                convertedSliceData.append(nal)
            }
        }

        guard !convertedSliceData.isEmpty, let formatDesc = formatDescription else {
            return
        }

        createSampleBufferAndDecode(from: convertedSliceData, formatDesc: formatDesc, pts: pts)
    }

    private func checkAndInitFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]

                var newFormatDesc: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDesc
                )

                if status == noErr, let desc = newFormatDesc {
                    self.formatDescription = desc
                    self.createDecompressionSession(formatDesc: desc)
                }
            }
        }
    }

    private func createDecompressionSession(formatDesc: CMVideoFormatDescription) {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { outputCallbackRefCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer = imageBuffer, let refCon = outputCallbackRefCon else { return }
                let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.onPixelBuffer?(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            videoDecoderSpecification: nil,
            destinationImageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        guard status == noErr, let session = newSession else { return }

        // Configure ultra-low-latency real-time properties
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_OutputPoolPreroll, value: 0 as CFNumber)

        self.decompressionSession = session
    }

    private func createSampleBufferAndDecode(from avccData: Data, formatDesc: CMVideoFormatDescription, pts: Int64) {
        var blockBuffer: CMBlockBuffer?
        let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: avccData.count, alignment: 4)
        avccData.copyBytes(to: memoryBlock.assumingMemoryBound(to: UInt8.self), count: avccData.count)

        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else {
            memoryBlock.deallocate()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else { return }

        // Dispatch sample buffer directly to display layer
        onSampleBuffer?(sample)

        // Also decode to pixel buffer if callback registered
        if let session = decompressionSession, onPixelBuffer != nil {
            var flagsOut: VTDecodeInfoFlags = []
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flagsOut
            )
        }
    }

    private func extractNalUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var i = 0
        let count = data.count
        var lastStart: Int? = nil

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress!

            while i < count - 3 {
                // Check 4-byte prefix 0x00000001
                if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    if let start = lastStart {
                        nalUnits.append(data.subdata(in: start..<i))
                    }
                    i += 4
                    lastStart = i
                    continue
                }
                // Check 3-byte prefix 0x000001
                if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                    if let start = lastStart {
                        nalUnits.append(data.subdata(in: start..<i))
                    }
                    i += 3
                    lastStart = i
                    continue
                }
                i += 1
            }

            if let start = lastStart, start < count {
                nalUnits.append(data.subdata(in: start..<count))
            }
        }

        return nalUnits
    }
}
