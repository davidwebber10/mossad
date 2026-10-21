import AVFoundation
import CoreAudio
import Foundation
import MossadCore
import SwiftUI

/// Owns detection and recording and exposes app state to the menu.
@MainActor
final class AppController: ObservableObject {
    enum Status: Equatable {
        case idle
        case recording(Platform, since: Date)
    }

    @Published private(set) var status: Status = .idle

    let paths = Paths.live
    private let detection = DetectionService(mic: MicUsageProbe(), tabs: BrowserTabProbe(), windows: WindowTitleProbe())
    private lazy var recorder = CallRecorder(
        paths: paths,
        makeThem: { ProcessTap(processObjectIDs: $0) },
        makeMe: { MicCapture() }
    )

    init() {
        try? paths.ensureDirectories()
        Log.directory = paths.logs
        WindowTitleProbe.requestAccess()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Log.error("Microphone access denied") }
        }
        ProcessingQueue(paths: paths).recoverInterrupted()

        let detection = detection
        detection.onEvent = { [weak self] event in
            // Read the call's audio processes on the detection queue, where they were just computed.
            let ids = detection.audioProcessIDs
            Task { @MainActor in self?.handle(event, processIDs: ids) }
        }
        detection.onCallProcesses = { [weak self] ids in
            Task { @MainActor in self?.recorder.updateThemProcesses(ids) }
        }
        detection.start()
        Log.info("Mossad started")
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    func skipCurrentCall() {
        recorder.skip()
        status = .idle
    }

    private func handle(_ event: DetectorEvent, processIDs: [AudioObjectID]) {
        switch event {
        case .started(let platform, let bundleID, let at):
            Log.info("Call started: \(platform.displayName) (\(bundleID))")
            do {
                try recorder.begin(platform: platform, bundleID: bundleID, processIDs: processIDs, at: at)
                status = .recording(platform, since: at)
            } catch {
                Log.error("Could not start recording: \(error)")
            }
        case .ended(let at, let trimTo):
            Log.info("Call ended")
            status = .idle
            if let record = recorder.end(at: at, trimTo: trimTo) {
                callRecorded(record)
            }
        }
    }

    private func callRecorded(_ record: CallRecord) {
        Log.info("Queued \(record.id) for processing")
    }
}
