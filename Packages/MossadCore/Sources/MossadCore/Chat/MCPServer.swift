import Foundation

/// A Model Context Protocol server over stdio, so Claude Code, Claude Desktop, and other agents can
/// search and read the meetings with the same tools as the Chat tab. One JSON-RPC message per line.
public struct MCPServer: Sendable {
    static let fallbackVersion = "2025-06-18"
    /// Everything Chat can read; not `remember`, so other apps cannot change what the coach knows. The one write is
    /// `add_next_time_point`, the owner's own list, which they asked another app to add to.
    static var tools: [ToolSpec] { ChatTools.allDefinitions.filter { $0.name != "remember" } }

    let paths: Paths
    let owner: String
    /// The coach's reads of how each person thinks, in the `people` tool. The owner can turn it off in Settings.
    let personaTraits: Bool

    /// The reads go to other AI apps only when the coach, the reads, and the setting for other apps are all on.
    public static func showsPersonas(coachEnabled: Bool, personaEnabled: Bool, personaInMCP: Bool) -> Bool {
        coachEnabled && personaEnabled && personaInMCP
    }

    /// The owner's settings, read again at each call: a switch turned off reaches a process that runs for days.
    let settings: (@Sendable () -> ToolSettings)?

    public init(paths: Paths, owner: String, settings: @escaping @Sendable () -> ToolSettings) {
        self.paths = paths
        self.owner = owner
        personaTraits = false
        self.settings = settings
    }

    public init(paths: Paths, owner: String, personaTraits: Bool = true) {
        self.paths = paths
        self.owner = owner
        self.personaTraits = personaTraits
        settings = nil
    }

    /// Reads requests from stdin until it closes; replies go to stdout, logs to stderr.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// The reply to one line, or nil for a notification.
    public func handle(_ line: String) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch message["method"] as? String ?? "" {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? Self.fallbackVersion,
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "mossad", "version": "1.0"],
                      "instructions": "Search and read \(owner)'s recorded meetings and everything Mossad shows about them: transcripts, summaries, decisions, action items, people (read_person), upcoming meetings and their prep, recurring meetings, points for next time, tasks, bookmarks, the coach, and analytics. Read a meeting before saying what someone agreed to."]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema,
                                                 "annotations": ["readOnlyHint": $0.readOnly]] as [String: Any] }]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard Self.tools.contains(where: { $0.name == name }) else {
                result = ["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true]
                break
            }
            // Fresh records on every call: the app may have written a new meeting since the last one.
            let now = settings?()
            let traits = now.map { Self.showsPersonas(coachEnabled: $0.coach, personaEnabled: $0.personaReads, personaInMCP: $0.personaInMCP) } ?? personaTraits
            let tools = ChatTools(records: ProcessingQueue(paths: paths).allRecords(), owner: owner, paths: paths, personaTraits: traits, settings: now)
            let input = params["arguments"] as? [String: Any] ?? [:]
            var content: [[String: Any]] = [["type": "text", "text": tools.run(name, input: input)]]
            // The picture of a shared screen goes out only when the caller asks for it.
            if name == "get_screen", input["include_image"] as? Bool == true,
               let image = tools.screenImageURL(input).flatMap({ FrameImage.jpeg(at: $0) }) {
                content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            result = ["content": content]
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension ToolSpec {
    /// False for the tools that change something: the MCP marks the rest as reads for the apps that ask.
    public var readOnly: Bool { !ChatTools.writes.contains(name) }
}
