import MossadCore
import SwiftUI

/// The Chat tab of one meeting: the latest chat about it, saved with the other chats so the Chat section shows it too.
struct MeetingChatView: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let horizontalPadding: CGFloat
    let maxWidth: CGFloat
    @State private var chat: Chat?
    @State private var question = ""
    @State private var running = false
    @State private var steps: [String] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    private var messages: [ChatMessage] { chat?.messages ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if messages.isEmpty && !running { welcome }
                    ForEach(messages) { MessageView(message: $0).id($0.id) }
                    if running {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                Label(s, systemImage: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .id("running")
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.recording) }
                }
                .padding(.horizontal, horizontalPadding).padding(.vertical, 16)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id, anchor: .top) } }
            .onChange(of: steps.count) { _, _ in withAnimation { proxy.scrollTo("running", anchor: .bottom) } }
        }
        .safeAreaBar(edge: .bottom) {
            composer
                .padding(.horizontal, horizontalPadding).padding(.bottom, 10).padding(.top, 6)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in controller.openLink(url) ? .handled : .systemAction })
        .onAppear(perform: load)
        .onChange(of: record.id) { _, _ in load() }
        .onChange(of: controller.chatsVersion) { _, _ in if !running { load() } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this meeting").font(.title3.weight(.semibold))
            Text("Claude reads this meeting's summary and transcript, and can look at your other meetings when that helps.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(examples, id: \.self) { e in
                    Button { question = e; send() } label: {
                        Text(e).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private let examples = [
        "What did I agree to, and by when?",
        "What did the others push back on?",
        "Write a short follow-up email from me.",
    ]

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if chat != nil {
                Button(action: newChat) { Image(systemName: "square.and.pencil").frame(width: 18, height: 18) }
                    .buttonStyle(.borderless)
                    .help("New chat about this meeting")
                    .accessibilityLabel("New chat")
            }
            TextField(messages.isEmpty ? "Ask about this meeting" : "Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || running)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    /// The newest chat about this meeting, if there is one.
    private func load() {
        chat = controller.chats.all().first { $0.callID == record.id }
    }

    private func newChat() {
        chat = nil
        error = nil
        focused = true
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        var current = chat ?? {
            var c = Chat(title: Chat.title(from: q))
            c.callID = record.id
            return c
        }()
        let history = current.messages
        current.messages.append(ChatMessage(role: .user, text: q))
        current.updated = Date()
        save(current)
        question = ""
        error = nil
        steps = []
        running = true
        let sink = StepSink { step in Task { @MainActor in steps.append(step) } }
        Task {
            do {
                let answer = try await controller.chatAnswer(q, history: history, about: record.id, onStep: sink.add)
                current.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                current.updated = Date()
                save(current)
                controller.summarizeChat(current.id)
                controller.syncToICloud()
            } catch {
                self.error = "\(error)"
            }
            running = false
            focused = true
        }
    }

    private func save(_ c: Chat) {
        do { try controller.chats.save(c) } catch { Log.error("Saving the chat failed: \(error)") }
        chat = c
    }
}
