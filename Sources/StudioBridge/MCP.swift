import Foundation

/// A minimal MCP server over stdio: newline-delimited JSON-RPC on stdin and stdout.
///
/// Deliberately hand-written rather than SDK-backed. Claude Code needs exactly four
/// methods — `initialize`, `notifications/initialized`, `tools/list`, `tools/call` —
/// plus `ping`, and a dependency-free helper is something the app can ship inside its
/// own bundle with no npm or Python on the user's machine.
///
/// One rule governs everything here: **stdout carries protocol traffic only**. Any
/// stray print corrupts the stream, so all logging goes to stderr.
struct MCPServer {
    /// Versions Claude Code accepts. We echo the client's when it is one of these,
    /// which is what Claude Code's own `mcp serve` does.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26",
                                    "2024-11-05", "2024-10-07"]
    static let fallbackVersion = "2025-06-18"

    let name: String
    let version: String
    let instructions: String
    let tools: [Tool]

    struct Tool {
        let name: String
        let title: String
        let description: String
        /// JSON Schema for the arguments; must be an object schema.
        let inputSchema: [String: Any]
        /// Returns the text to hand back, or throws `ToolError` for a tool-level failure.
        let run: ([String: Any]) throws -> String
    }

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Loop

    func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                log("could not parse a line as JSON, ignoring it")
                continue
            }
            handle(message)
        }
        // stdin closed: the client is done with us.
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // A notification has no id and must never be answered.
        guard let id else {
            if method == "notifications/initialized" { log("client initialized") }
            return
        }

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any] ?? [:]
            let requested = params["protocolVersion"] as? String ?? ""
            let agreed = Self.supportedVersions.contains(requested) ? requested : Self.fallbackVersion
            reply(id: id, result: [
                "protocolVersion": agreed,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ])

        case "ping":
            reply(id: id, result: [:])

        case "tools/list":
            reply(id: id, result: ["tools": tools.map {
                ["name": $0.name, "title": $0.title,
                 "description": $0.description, "inputSchema": $0.inputSchema]
            }])

        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard let toolName = params["name"] as? String,
                  let tool = tools.first(where: { $0.name == toolName })
            else {
                fail(id: id, code: -32602, message: "Unknown tool: \(params["name"] ?? "")")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try tool.run(arguments)
                reply(id: id, result: content(text))
            } catch let error as ToolError {
                // A tool failure is a RESULT, not a protocol error: the model should
                // see the reason and be able to react to it.
                reply(id: id, result: content(error.message, isError: true))
            } catch {
                reply(id: id, result: content("Failed: \(error)", isError: true))
            }

        default:
            fail(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Writing

    private func content(_ text: String, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        return result
    }

    private func reply(id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: data, encoding: .utf8)
        else {
            log("could not serialise a reply")
            return
        }
        // One message per line, flushed immediately: the client reads line by line.
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("[claude-studio-bridge] \(message)\n".utf8))
    }
}

// MARK: - JSON helpers

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }
}

/// Pretty JSON, which is what a model reads best.
func jsonText(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
}
