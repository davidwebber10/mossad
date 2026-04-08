// MossadService/AudioCaptureManager.swift
import AVFoundation
import Foundation
import ScreenCaptureKit
import os.log

private let audioLog = Logger(subsystem: "com.mossad.app", category: "AudioCapture")

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureAppAudio data: Data)
    func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureMicAudio data: Data)
    func audioCaptureManager(_ manager: AudioCaptureManager, didEncounterError error: Error)
}

public final class AudioCaptureManager: NSObject {
    public weak var delegate: AudioCaptureDelegate?

    private var scStream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?

    // Target: 16kHz mono 16-bit PCM
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    /// The URL of the recorded WAV file (available after stopCapture)
    public var recordedFileURL: URL? { audioFileURL }

    public override init() {
        super.init()
    }

    public func startCapture(appProcessID: pid_t) async throws {
        // Create WAV file for recording
        let fileURL = try createAudioFile()
        self.audioFileURL = fileURL
        audioLog.notice("Recording to: \(fileURL.lastPathComponent, privacy: .public)")

        // Start mic capture
        try startMicCapture()
        audioLog.notice("Mic capture started")

        // Start app audio capture for remote participants
        do {
            try await startAppAudioCapture(processID: appProcessID)
            audioLog.notice("App audio capture started")
        } catch {
            audioLog.error("App audio capture failed (continuing with mic only): \(error.localizedDescription)")
        }
    }

    public func stopCapture() {
        scStream?.stopCapture()
        scStream = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Close the audio file
        audioFile = nil
        if let url = audioFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            audioLog.notice("Recording saved: \(url.lastPathComponent, privacy: .public) (\(size / 1024)KB)")
        }
    }

    // MARK: - WAV file creation

    private func createAudioFile() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mossad/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "recording-\(formatter.string(from: Date())).wav"
        let fileURL = dir.appendingPathComponent(filename)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatError
        }

        audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        return fileURL
    }

    // MARK: - Write audio to file

    private func writeToFile(_ data: Data) {
        guard let audioFile else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else { return }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuf in
            if let src = rawBuf.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, src, data.count)
            }
        }

        do {
            try audioFile.write(from: buffer)
        } catch {
            audioLog.error("Failed to write audio: \(error.localizedDescription)")
        }
    }

    // MARK: - Mic capture (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        audioLog.notice("Mic input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatError
        }

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = self.convertBuffer(buffer, from: inputFormat, to: targetFormat) else { return }
            self.writeToFile(converted)
            self.delegate?.audioCaptureManager(self, didCaptureMicAudio: converted)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    // MARK: - App audio capture (ScreenCaptureKit)

    private func startAppAudioCapture(processID: pid_t) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let app = content.applications.first(where: { $0.processID == processID }) else {
            throw AudioCaptureError.appNotFound
        }
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let appFilter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = Int(targetChannels)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: appFilter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.scStream = stream
    }

    // MARK: - Audio conversion

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> Data? {
        if inputFormat.sampleRate == targetFormat.sampleRate &&
           inputFormat.channelCount == targetFormat.channelCount &&
           inputFormat.commonFormat == targetFormat.commonFormat {
            return buffer.int16Data
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return nil }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            audioLog.error("Audio conversion error: \(error.localizedDescription)")
            return nil
        }
        return outputBuffer.int16Data
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { return }

        let rawData = Data(bytes: ptr, count: length)

        let int16Data: Data
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatCount = length / MemoryLayout<Float32>.size
            var converted = Data(count: floatCount * MemoryLayout<Int16>.size)
            rawData.withUnsafeBytes { rawBuf in
                converted.withUnsafeMutableBytes { outBuf in
                    let floats = rawBuf.bindMemory(to: Float32.self)
                    let ints = outBuf.bindMemory(to: Int16.self)
                    for i in 0..<floatCount {
                        let clamped = max(-1.0, min(1.0, floats[i]))
                        ints[i] = Int16(clamped * Float32(Int16.max))
                    }
                }
            }
            int16Data = converted
        } else {
            int16Data = rawData
        }

        writeToFile(int16Data)
        delegate?.audioCaptureManager(self, didCaptureAppAudio: int16Data)
    }
}

// MARK: - Helpers

enum AudioCaptureError: Error {
    case appNotFound
    case noDisplay
    case formatError
    case converterError
}

extension AVAudioPCMBuffer {
    var int16Data: Data? {
        guard let ptr = int16ChannelData else { return nil }
        let count = Int(frameLength)
        guard count > 0 else { return nil }
        return Data(bytes: ptr[0], count: count * MemoryLayout<Int16>.size)
    }
}
