// MossadService/AudioCaptureManager.swift
import AVFoundation
import Foundation
import ScreenCaptureKit

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureAppAudio data: Data)
    func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureMicAudio data: Data)
    func audioCaptureManager(_ manager: AudioCaptureManager, didEncounterError error: Error)
}

public final class AudioCaptureManager: NSObject {
    public weak var delegate: AudioCaptureDelegate?

    private var scStream: SCStream?
    private var audioEngine: AVAudioEngine?

    // Target format for AssemblyAI
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    public override init() {
        super.init()
    }

    /// Start capturing audio from a specific app (via ScreenCaptureKit) and the mic.
    public func startCapture(appProcessID: pid_t) async throws {
        try await startAppAudioCapture(processID: appProcessID)
        try startMicCapture()
    }

    public func stopCapture() {
        scStream?.stopCapture()
        scStream = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    // MARK: - ScreenCaptureKit (app audio)

    private func startAppAudioCapture(processID: pid_t) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let app = content.applications.first(where: { $0.processID == processID }) else {
            throw AudioCaptureError.appNotFound
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let appFilter = SCContentFilter(
            display: display,
            including: [app],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = Int(targetChannels)
        // We don't need video
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum

        let stream = SCStream(filter: appFilter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.scStream = stream
    }

    // MARK: - AVAudioEngine (mic)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to target format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatError
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterError
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error = error {
                self.delegate?.audioCaptureManager(self, didEncounterError: error)
                return
            }

            if let data = convertedBuffer.int16Data {
                self.delegate?.audioCaptureManager(self, didCaptureMicAudio: data)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let data = sampleBuffer.pcmData else { return }
        delegate?.audioCaptureManager(self, didCaptureAppAudio: data)
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
        return Data(bytes: ptr[0], count: count * MemoryLayout<Int16>.size)
    }
}

extension CMSampleBuffer {
    var pcmData: Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return nil }
        return Data(bytes: ptr, count: length)
    }
}
