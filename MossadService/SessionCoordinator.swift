// MossadService/SessionCoordinator.swift
import Foundation
import MossadShared
import os.log

private let coordLog = Logger(subsystem: "com.mossad.app", category: "SessionCoordinator")

public protocol SessionCoordinatorDelegate: AnyObject {
    func coordinator(_ coordinator: SessionCoordinator, didChangeState snapshot: ServiceSnapshot)
    func coordinator(_ coordinator: SessionCoordinator, didReceiveUtterance utteranceData: Data)
    func coordinator(_ coordinator: SessionCoordinator, didTranscribe text: String, speaker: String, timestamp: Double)
    func coordinator(_ coordinator: SessionCoordinator, didReceivePartial text: String)
}

public final class SessionCoordinator {
    public weak var delegate: SessionCoordinatorDelegate?

    private let processMonitor = ProcessMonitor()
    private let calendarMatcher = CalendarMatcher()
    private let audioCaptureManager = AudioCaptureManager()
    private var appAudioClient: AssemblyAIClient?
    private var micAudioClient: AssemblyAIClient?
    private let store: ConversationStore
    private let dbManager: DatabaseManager

    private var currentConversationId: String?
    public private(set) var currentSnapshot = ServiceSnapshot()
    private var conversationStartTime: Date?
    private var speakerMap: [String: String] = [:] // diarization label → speaker ID
    private var meSpeaker: Speaker?

    public init() throws {
        self.dbManager = try DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
    }

    public func startMonitoring() {
        // Ensure we have the "me" speaker
        meSpeaker = try? store.getOrCreateMeSpeaker(
            name: UserDefaults.standard.string(forKey: "userName") ?? "Me"
        )

        NSLog("[Mossad] Starting process monitor...")

        processMonitor.startMonitoring(
            onDetected: { [weak self] meeting in
                NSLog("[Mossad] Meeting detected: %@ (pid: %d, url: %@)", meeting.platform.rawValue, meeting.processIdentifier, meeting.meetingUrl ?? "none")
                self?.handleMeetingDetected(meeting)
            },
            onEnded: { [weak self] in
                NSLog("[Mossad] Meeting ended")
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
        appAudioClient?.terminateSession()
        micAudioClient?.terminateSession()
        updateState { $0.recordingState = .paused }
    }

    public func resumeRecording() {
        guard let convId = currentConversationId else { return }
        // Re-poll to find the meeting process and restart capture
        // We need to re-detect the meeting app to get its process ID
        processMonitor.stopMonitoring()
        processMonitor.startMonitoring(
            onDetected: { [weak self] meeting in
                guard let self = self else { return }
                // Restart audio capture for the existing conversation
                Task {
                    try? await self.audioCaptureManager.startCapture(appProcessID: meeting.processIdentifier)
                    self.audioCaptureManager.delegate = self
                    self.startTranscriptionClients()
                }
                self.updateState { $0.recordingState = .recording }
            },
            onEnded: { [weak self] in
                self?.handleMeetingEnded()
            }
        )
        updateState { $0.recordingState = .detecting }
    }

    // MARK: - Meeting Lifecycle

    private func handleMeetingDetected(_ meeting: DetectedMeeting) {
        // Don't create a new conversation if we're already recording
        if currentConversationId != nil { return }

        // Match against calendar
        let matchedEvent = calendarMatcher.findMatchingEvent(
            platform: meeting.platform,
            detectedURL: meeting.meetingUrl
        )

        // Use calendar title if matched, otherwise extract Meet ID from URL
        let title: String
        if let eventTitle = matchedEvent?.title {
            title = eventTitle
        } else if let url = meeting.meetingUrl,
                  let meetCode = url.components(separatedBy: "meet.google.com/").last?.components(separatedBy: "?").first {
            title = meetCode
        } else {
            title = "Ad-hoc \(meeting.platform.rawValue.capitalized) Call"
        }
        let calendarEventId = matchedEvent?.calendarEventId
        let meetingUrl = meeting.meetingUrl ?? matchedEvent?.meetingUrl

        // Create conversation record
        guard let conversation = try? store.createConversation(
            title: title,
            platform: meeting.platform.rawValue,
            calendarEventId: calendarEventId,
            meetingUrl: meetingUrl
        ) else { return }

        currentConversationId = conversation.id
        conversationStartTime = conversation.startedAt

        // Add "me" as a conversation speaker
        if let me = meSpeaker {
            try? store.addConversationSpeaker(
                conversationId: conversation.id,
                speakerId: me.id,
                diarizationLabel: "me"
            )
        }

        // Start audio capture
        coordLog.notice("Starting audio capture for pid \(meeting.processIdentifier)")
        Task {
            do {
                try await audioCaptureManager.startCapture(appProcessID: meeting.processIdentifier)
                audioCaptureManager.delegate = self
                coordLog.notice("Audio capture started, connecting to AssemblyAI...")
                startTranscriptionClients()
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

        // Start elapsed time ticker
        startElapsedTimer()
    }

    private func handleMeetingEnded() {
        guard let convId = currentConversationId else { return }

        // Stop everything
        audioCaptureManager.stopCapture()
        appAudioClient?.terminateSession()
        appAudioClient?.disconnect()
        micAudioClient?.terminateSession()
        micAudioClient?.disconnect()

        // Finalize conversation
        try? store.finalizeConversation(id: convId)

        currentConversationId = nil
        conversationStartTime = nil
        speakerMap = [:]

        updateState {
            $0.recordingState = .detecting
            $0.currentConversationId = nil
            $0.currentMeetingTitle = nil
            $0.currentPlatform = nil
            $0.elapsedSeconds = nil
            $0.speakerCount = nil
        }
    }

    // MARK: - Transcription

    private func startTranscriptionClients() {
        guard let apiKey = try? KeychainManager.retrieve(account: "assemblyai-api-key") else {
            coordLog.error("No AssemblyAI API key configured")
            return
        }

        coordLog.notice("Connecting to AssemblyAI (single mixed stream)...")

        // Single stream for both mic and app audio
        let client = AssemblyAIClient(apiKey: apiKey)
        client.delegate = self
        client.connect()
        self.appAudioClient = client
        self.micAudioClient = client  // same client receives both streams
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
            guard let self = self, let start = self.conversationStartTime else { return }
            self.updateState {
                $0.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }
}

// MARK: - AudioCaptureDelegate

extension SessionCoordinator: AudioCaptureDelegate {
    private static var appAudioLogCount = 0
    private static var micAudioLogCount = 0

    public func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureAppAudio data: Data) {
        Self.appAudioLogCount += 1
        if Self.appAudioLogCount <= 3 {
            coordLog.notice("App audio chunk received: \(data.count) bytes")
        }
        appAudioClient?.sendAudio(data)
    }

    public func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureMicAudio data: Data) {
        Self.micAudioLogCount += 1
        if Self.micAudioLogCount <= 3 {
            coordLog.notice("Mic audio chunk received: \(data.count) bytes")
        }
        micAudioClient?.sendAudio(data)
    }

    public func audioCaptureManager(_ manager: AudioCaptureManager, didEncounterError error: Error) {
        coordLog.error("Audio capture error: \(error.localizedDescription)")
    }
}

// MARK: - AssemblyAIClientDelegate

extension SessionCoordinator: AssemblyAIClientDelegate {
    public func client(_ client: AssemblyAIClient, didReceiveFinalTranscript transcript: FinalTranscriptData) {
        coordLog.notice("Transcript: \(transcript.text)")
        guard let convId = currentConversationId else { return }

        let startOffset = Double(transcript.audioStartMs) / 1000.0
        let endOffset = Double(transcript.audioEndMs) / 1000.0

        // Use "me" speaker for now — single mixed stream can't distinguish speakers
        // TODO: when AssemblyAI v3 adds speaker diarization to Turn messages, use that
        let speakerId = meSpeaker?.id ?? "unknown"

        try? store.insertUtterance(
            conversationId: convId,
            speakerId: speakerId,
            text: transcript.text,
            startedAt: startOffset,
            endedAt: endOffset
        )

        delegate?.coordinator(self, didTranscribe: transcript.text, speaker: "", timestamp: startOffset)
    }

    public func client(_ client: AssemblyAIClient, didReceivePartialTranscript text: String) {
        delegate?.coordinator(self, didReceivePartial: text)
    }

    public func clientDidConnect(_ client: AssemblyAIClient) {
        let source = (client === micAudioClient) ? "mic" : "app"
        coordLog.notice("AssemblyAI connected (\(source) stream)")
    }

    public func clientDidDisconnect(_ client: AssemblyAIClient) {
        let source = (client === micAudioClient) ? "mic" : "app"
        coordLog.notice("AssemblyAI disconnected (\(source) stream)")
    }

    public func client(_ client: AssemblyAIClient, didEncounterError error: Error) {
        coordLog.error("AssemblyAI error: \(error.localizedDescription)")
    }
}
