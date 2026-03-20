// Mossad/AppState.swift
import Foundation
import MossadShared
import SwiftUI

@MainActor
public final class AppState: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var currentMeetingTitle: String?
    @Published var currentPlatform: String?
    @Published var elapsedSeconds: Int = 0
    @Published var speakerCount: Int = 0
    @Published var currentConversationId: String?

    private var xpcConnection: NSXPCConnection?
    private var service: MossadServiceProtocol?
    let store: ConversationStore

    override init() {
        let dbManager = try! DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
        super.init()
        setupXPCConnection()
    }

    private func setupXPCConnection() {
        let connection = NSXPCConnection(serviceName: "com.mossad.MossadService")
        connection.remoteObjectInterface = NSXPCInterface(with: MossadServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MossadAppProtocol.self)
        connection.exportedObject = self
        connection.resume()

        self.xpcConnection = connection
        self.service = connection.remoteObjectProxyWithErrorHandler { error in
            print("XPC error: \(error)")
        } as? MossadServiceProtocol

        // Start monitoring immediately
        service?.startMonitoring()
    }

    func pauseRecording() {
        service?.pauseRecording()
    }

    func resumeRecording() {
        service?.resumeRecording()
    }

    func stopMonitoring() {
        service?.stopMonitoring()
    }

    var elapsedFormatted: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension AppState: MossadAppProtocol {
    nonisolated public func stateDidChange(_ stateData: Data) {
        guard let snapshot = ServiceSnapshot.decoded(from: stateData) else { return }
        Task { @MainActor in
            self.recordingState = snapshot.recordingState
            self.currentMeetingTitle = snapshot.currentMeetingTitle
            self.currentPlatform = snapshot.currentPlatform
            self.elapsedSeconds = snapshot.elapsedSeconds ?? 0
            self.speakerCount = snapshot.speakerCount ?? 0
            self.currentConversationId = snapshot.currentConversationId
        }
    }

    nonisolated public func utteranceReceived(_ utteranceData: Data) {
        // Could use this for live transcript display
    }
}
