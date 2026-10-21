import AVFoundation
import Foundation

/// Writes `seconds` of a sine tone (or silence) as 16 kHz mono Float32 CAF.
func writeTestAudio(_ url: URL, seconds: Double, frequency: Double = 0, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) {
            buffer.floatChannelData![c][i] = frequency == 0 ? 0 : Float(sin(2 * .pi * frequency * Double(i) / sampleRate) * 0.5)
        }
    }
    try file.write(from: buffer)
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
