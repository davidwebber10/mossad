// MossadService/MossadServiceImpl.swift
import Foundation
import MossadShared

class MossadServiceImpl: NSObject, MossadServiceProtocol {
    var appProxy: MossadAppProtocol?
    private var coordinator: SessionCoordinator?

    override init() {
        super.init()
        coordinator = try? SessionCoordinator()
        coordinator?.delegate = self
    }

    func startMonitoring() {
        coordinator?.startMonitoring()
    }

    func stopMonitoring() {
        coordinator?.stopMonitoring()
    }

    func pauseRecording() {
        coordinator?.pauseRecording()
    }

    func resumeRecording() {
        coordinator?.resumeRecording()
    }

    func getState(reply: @escaping (Data) -> Void) {
        if let snapshot = coordinator?.currentSnapshot {
            reply(snapshot.encoded())
        } else {
            reply(ServiceSnapshot().encoded())
        }
    }
}

extension MossadServiceImpl: SessionCoordinatorDelegate {
    func coordinator(_ coordinator: SessionCoordinator, didChangeState snapshot: ServiceSnapshot) {
        appProxy?.stateDidChange(snapshot.encoded())
    }

    func coordinator(_ coordinator: SessionCoordinator, didReceiveUtterance utteranceData: Data) {
        appProxy?.utteranceReceived(utteranceData)
    }

    func coordinator(_ coordinator: SessionCoordinator, didTranscribe text: String, speaker: String, timestamp: Double) {}
    func coordinator(_ coordinator: SessionCoordinator, didReceivePartial text: String) {}
}
