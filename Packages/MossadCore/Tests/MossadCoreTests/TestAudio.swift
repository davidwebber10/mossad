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

/// A stereo file with silence on channel 1 and a 440 Hz tone on channel 2: a call with one person on each side.
func writeSecondChannelTone(_ url: URL, seconds: Double, sampleRate: Double = 16_000, amplitude: Double = 0.5, both: Bool = false) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) {
        let v = Float(sin(2 * .pi * 440 * Double(i) / sampleRate) * amplitude)
        buffer.floatChannelData![0][i] = both ? v : 0
        buffer.floatChannelData![1][i] = v
    }
    try file.write(from: buffer)
}

/// The largest sample of a file's first channel.
func peak(of file: AVAudioFile) throws -> Float {
    file.framePosition = 0
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(buffer.floatChannelData![0][$1])) }
}
