import Foundation

@objc public protocol MossadServiceProtocol {
    func startMonitoring()
    func stopMonitoring()
    func pauseRecording()
    func resumeRecording()
    func getState(reply: @escaping (Data) -> Void)
}

@objc public protocol MossadAppProtocol {
    func stateDidChange(_ stateData: Data)
    func utteranceReceived(_ utteranceData: Data)
}
