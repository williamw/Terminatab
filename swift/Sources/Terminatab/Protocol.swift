import Foundation

// MARK: - Client → Server Messages

enum ClientMessage {
    case newSession
    case attach(sessionId: String)
    case input(sessionId: String, data: String)
    case resize(sessionId: String, cols: UInt16, rows: UInt16)
    // MCP control messages from extension
    case mcpControl
    case mcpEnabled(tabCount: Int)
    case mcpDisabled
    case mcpResponse(id: String, result: String) // raw JSON
    case ping
}

// MARK: - Server → Client Messages

enum ServerMessage: Sendable {
    case sessionCreated(sessionId: String)
    case sessionEnded(sessionId: String)
    case error(message: String)
}

// MARK: - Parsing

enum ProtocolError: Error {
    case unknownMessageType
    case missingField
    case invalidJSON
}

private struct RawMessage: Decodable {
    let type: String
    let session_id: String?
    let data: String?
    let cols: UInt16?
    let rows: UInt16?
    let message: String?
    // MCP fields
    let tab_count: Int?
    let id: String?
    let result: AnyCodable?
    let error: String?
}

/// Type-erased Codable wrapper for passing through raw JSON values.
struct AnyCodable: Decodable, Sendable {
    let rawJSON: String

    init(from decoder: Decoder) throws {
        // We don't use this path — we extract raw JSON manually
        rawJSON = "{}"
    }

    init(rawJSON: String) {
        self.rawJSON = rawJSON
    }
}

func parseClientMessage(_ json: String) throws -> ClientMessage {
    guard let data = json.data(using: .utf8) else {
        throw ProtocolError.invalidJSON
    }

    let raw: RawMessage
    do {
        raw = try JSONDecoder().decode(RawMessage.self, from: data)
    } catch {
        throw ProtocolError.invalidJSON
    }

    switch raw.type {
    case "new_session":
        return .newSession
    case "attach":
        guard let sessionId = raw.session_id else { throw ProtocolError.missingField }
        return .attach(sessionId: sessionId)
    case "input":
        guard let sessionId = raw.session_id, let inputData = raw.data else {
            throw ProtocolError.missingField
        }
        return .input(sessionId: sessionId, data: inputData)
    case "resize":
        guard let sessionId = raw.session_id, let cols = raw.cols, let rows = raw.rows else {
            throw ProtocolError.missingField
        }
        return .resize(sessionId: sessionId, cols: cols, rows: rows)
    case "mcp_control":
        return .mcpControl
    case "mcp_enabled":
        return .mcpEnabled(tabCount: raw.tab_count ?? 0)
    case "mcp_disabled":
        return .mcpDisabled
    case "mcp_response":
        guard let id = raw.id else { throw ProtocolError.missingField }
        // Extract the raw JSON for result/error — re-serialize from original data
        let rawJSON = extractMCPResponsePayload(from: data)
        return .mcpResponse(id: id, result: rawJSON)
    case "ping":
        return .ping
    default:
        throw ProtocolError.unknownMessageType
    }
}

// MARK: - Serialization

func serializeServerMessage(_ msg: ServerMessage) -> String {
    switch msg {
    case .sessionCreated(let sessionId):
        return "{\"type\":\"session_created\",\"session_id\":\(jsonString(sessionId))}"
    case .sessionEnded(let sessionId):
        return "{\"type\":\"session_ended\",\"session_id\":\(jsonString(sessionId))}"
    case .error(let message):
        return "{\"type\":\"error\",\"message\":\(jsonString(message))}"
    }
}

/// JSON-encode a Swift String value with proper escaping.
private func jsonString(_ s: String) -> String {
    var result = "\""
    for char in s {
        switch char {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if char.asciiValue != nil && char.asciiValue! < 0x20 {
                result += String(format: "\\u%04x", char.asciiValue!)
            } else {
                result.append(char)
            }
        }
    }
    result += "\""
    return result
}

/// Extract the result/error payload from an mcp_response message as raw JSON string.
/// This avoids deeply parsing the result — we just pass it through.
private func extractMCPResponsePayload(from data: Data) -> String {
    // Re-parse as dictionary to extract result/error fields
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "{}"
    }
    if let error = obj["error"] as? String {
        return "{\"error\":\(jsonString(error))}"
    }
    if let result = obj["result"] {
        guard let resultData = try? JSONSerialization.data(withJSONObject: result) else {
            return "{}"
        }
        return String(data: resultData, encoding: .utf8) ?? "{}"
    }
    return "{}"
}

// MARK: - MCP Messages (Server → Extension)

enum MCPServerMessage: Sendable {
    case mcpEnable
    case mcpDisable
    case mcpRequest(id: String, tool: String, params: String) // params is raw JSON
}

func serializeMCPServerMessage(_ msg: MCPServerMessage) -> String {
    switch msg {
    case .mcpEnable:
        return #"{"type":"mcp_enable"}"#
    case .mcpDisable:
        return #"{"type":"mcp_disable"}"#
    case .mcpRequest(let id, let tool, let params):
        return "{\"type\":\"mcp_request\",\"id\":\(jsonString(id)),\"tool\":\(jsonString(tool)),\"params\":\(params)}"
    }
}
