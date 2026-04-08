// MossadService/SessionCoordinator.swift
import Foundation
import MossadShared
import os.log

private let coordLog = Logger(subsystem: "com.mossad.app", category: "SessionCoordinator")

public protocol SessionCoordinatorDelegate: AnyObject {
    func coordinator(_ coordinator: SessionCoordinator, didChangeState snapshot: ServiceSnapshot)
    func coordinator(_ coordinator: SessionCoordinator, didFinishTranscription conversationId: String)
}

public final class SessionCoordinator {
    public weak var delegate: SessionCoordinatorDelegate?

    private let processMonitor = ProcessMonitor()
    private let calendarMatcher = CalendarMatcher()
    private let audioCaptureManager = AudioCaptureManager()
    private let store: ConversationStore
    private let dbManager: DatabaseManager

    private var currentConversationId: String?
    public private(set) var currentSnapshot = ServiceSnapshot()
    private var conversationStartTime: Date?
    private var meSpeaker: Speaker?

    public init() throws {
        self.dbManager = try DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
    }

    public func startMonitoring() {
        meSpeaker = try? store.getOrCreateMeSpeaker(
            name: UserDefaults.standard.string(forKey: "userName") ?? "Me"
        )

        coordLog.notice("Starting process monitor...")

        processMonitor.startMonitoring(
            onDetected: { [weak self] meeting in
                coordLog.notice("Meeting detected: \(meeting.platform.rawValue)")
                self?.handleMeetingDetected(meeting)
            },
            onEnded: { [weak self] in
                coordLog.notice("Meeting ended")
                self?.handleMeetingEnded()
            }
        )

        updateState { $0.recordingState = .detecting }
    }

    public func stopMonitoring() {
        processMonitor.stopMonitoring()
        if currentConversationId != nil {
            handleMeetingEnded()
        }
        updateState { $0.recordingState = .idle }
    }

    public func pauseRecording() {
        audioCaptureManager.stopCapture()
        updateState { $0.recordingState = .paused }
    }

    public func resumeRecording() {
        updateState { $0.recordingState = .detecting }
    }

    // MARK: - Meeting Lifecycle

    private func handleMeetingDetected(_ meeting: DetectedMeeting) {
        if currentConversationId != nil { return }

        let matchedEvent = calendarMatcher.findMatchingEvent(
            platform: meeting.platform,
            detectedURL: meeting.meetingUrl
        )

        let title: String
        if let eventTitle = matchedEvent?.title {
            title = eventTitle
        } else if let url = meeting.meetingUrl,
                  let meetCode = url.components(separatedBy: "meet.google.com/").last?.components(separatedBy: "?").first {
            title = meetCode
        } else {
            title = "Ad-hoc \(meeting.platform.rawValue.capitalized) Call"
        }

        guard let conversation = try? store.createConversation(
            title: title,
            platform: meeting.platform.rawValue,
            calendarEventId: matchedEvent?.calendarEventId,
            meetingUrl: meeting.meetingUrl ?? matchedEvent?.meetingUrl
        ) else { return }

        currentConversationId = conversation.id
        conversationStartTime = conversation.startedAt

        // Start audio capture (records to WAV file)
        coordLog.notice("Starting audio capture for pid \(meeting.processIdentifier)")
        Task {
            do {
                try await audioCaptureManager.startCapture(appProcessID: meeting.processIdentifier)
                audioCaptureManager.delegate = self
                coordLog.notice("Recording started")
            } catch {
                coordLog.error("Audio capture failed: \(error.localizedDescription)")
            }
        }

        updateState {
            $0.recordingState = .recording
            $0.currentConversationId = conversation.id
            $0.currentMeetingTitle = title
            $0.currentPlatform = meeting.platform.rawValue
            $0.elapsedSeconds = 0
        }

        startElapsedTimer()
    }

    private func handleMeetingEnded() {
        guard let convId = currentConversationId else { return }

        // Stop recording
        audioCaptureManager.stopCapture()
        elapsedTimer?.invalidate()

        // Finalize conversation
        try? store.finalizeConversation(id: convId)

        let audioFileURL = audioCaptureManager.recordedFileURL

        // Update state
        let savedConvId = convId
        currentConversationId = nil
        conversationStartTime = nil

        updateState {
            $0.recordingState = .detecting
            $0.currentConversationId = nil
            $0.currentMeetingTitle = nil
            $0.currentPlatform = nil
            $0.elapsedSeconds = nil
            $0.speakerCount = nil
        }

        // Submit for batch transcription
        if let audioFileURL {
            submitForTranscription(conversationId: savedConvId, audioFileURL: audioFileURL)
        }
    }

    // MARK: - Batch Transcription

    private func submitForTranscription(conversationId: String, audioFileURL: URL) {
        guard let apiKey = try? KeychainManager.retrieve(account: "assemblyai-api-key") else {
            coordLog.error("No AssemblyAI API key — cannot transcribe")
            return
        }

        coordLog.notice("Submitting recording for batch transcription...")

        let transcriber = BatchTranscriber(apiKey: apiKey)
        transcriber.transcribe(audioFileURL: audioFileURL) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let utterances):
                coordLog.notice("Transcription complete: \(utterances.count) utterances")
                self.saveTranscription(conversationId: conversationId, utterances: utterances)
                self.delegate?.coordinator(self, didFinishTranscription: conversationId)

            case .failure(let error):
                coordLog.error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func saveTranscription(conversationId: String, utterances: [TranscribedUtterance]) {
        var speakerMap: [String: String] = [:]

        for utterance in utterances {
            // Get or create speaker for this diarization label
            let speakerId: String
            if let existingId = speakerMap[utterance.speaker] {
                speakerId = existingId
            } else {
                let name = "Speaker \(utterance.speaker)"
                let speaker = try? store.getOrCreateSpeaker(name: name)
                speakerId = speaker?.id ?? "unknown"
                speakerMap[utterance.speaker] = speakerId
                try? store.addConversationSpeaker(
                    conversationId: conversationId,
                    speakerId: speakerId,
                    diarizationLabel: utterance.speaker
                )
            }

            try? store.insertUtterance(
                conversationId: conversationId,
                speakerId: speakerId,
                text: utterance.text,
                startedAt: Double(utterance.startMs) / 1000.0,
                endedAt: Double(utterance.endMs) / 1000.0
            )
        }

        coordLog.notice("Saved \(utterances.count) utterances with \(speakerMap.count) speakers")
    }

    // MARK: - State Management

    private func updateState(_ modify: (inout ServiceSnapshot) -> Void) {
        modify(&currentSnapshot)
        delegate?.coordinator(self, didChangeState: currentSnapshot)
    }

    private var elapsedTimer: Timer?

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.conversationStartTime else { return }
            self.updateState { $0.elapsedSeconds = Int(Date().timeIntervalSince(start)) }
        }
    }
}

// MARK: - AudioCaptureDelegate

extension SessionCoordinator: AudioCaptureDelegate {
    public func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureAppAudio data: Data) {
        // Audio is written to file by AudioCaptureManager — nothing to do here
    }

    public func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureMicAudio data: Data) {
        // Audio is written to file by AudioCaptureManager — nothing to do here
    }

    public func audioCaptureManager(_ manager: AudioCaptureManager, didEncounterError error: Error) {
        coordLog.error("Audio capture error: \(error.localizedDescription)")
    }
}
