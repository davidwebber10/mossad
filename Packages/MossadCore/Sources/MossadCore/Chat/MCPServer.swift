import Foundation

/// A read-only Model Context Protocol server over stdio, so Claude Code, Claude Desktop, and other agents can
/// search and read the meetings with the same tools as the Chat tab. One JSON-RPC message per line.
public struct MCPServer: Sendable {
    static let fallbackVersion = "2025-06-18"
    /// Everything Chat can read; not `remember`, so other apps cannot change what the coach knows.
    static var tools: [ToolSpec] { ChatTools.allDefinitions.filter { $0.name != "remember" } }

    let paths: Paths
    let owner: String

    public init(paths: Paths, owner: String) {
        self.paths = paths
        self.owner = owner
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
                      "instructions": "Search and read \(owner)'s recorded meetings: transcripts, summaries, decisions, and action items. Read a meeting before saying what someone agreed to."]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] as [String: Any] }]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard Self.tools.contains(where: { $0.name == name }) else {
                result = ["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true]
                break
            }
            // Fresh records on every call: the app may have written a new meeting since the last one.
            let tools = ChatTools(records: ProcessingQueue(paths: paths).allRecords(), owner: owner, paths: paths)
            result = ["content": [["type": "text", "text": tools.run(name, input: params["arguments"] as? [String: Any] ?? [:])]]]
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
