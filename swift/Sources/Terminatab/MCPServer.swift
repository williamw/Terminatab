import Foundation
import Network
import Synchronization

/// Minimal MCP server over HTTP (streamable HTTP transport).
/// Listens on port 7682 and routes tool calls to the Chrome extension via WebSocket.
final class MCPServer: Sendable {
    let listener: NWListener
    let webSocketServer: WebSocketServer
    private let requestCounter = Mutex<Int>(0)

    init(port: UInt16, webSocketServer: WebSocketServer) throws {
        self.webSocketServer = webSocketServer

        let params = NWParameters.tcp
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("MCP server listening on http://127.0.0.1:%d/mcp",
                      self.listener.port?.rawValue ?? 0)
            case .failed(let error):
                NSLog("MCP server failed: %@", error.localizedDescription)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [self] nwConnection in
            nwConnection.start(queue: .global())
            handleHTTPConnection(nwConnection)
        }

        listener.start(queue: .global())
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - HTTP Handling

    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            Task {
                await self.processHTTPRequest(connection, data: data)
            }
        }
    }

    private func processHTTPRequest(_ connection: NWConnection, data: Data) async {
        guard let request = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection, status: 400, body: #"{"error":"Invalid request"}"#)
            return
        }

        // Parse HTTP request
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection, status: 400, body: #"{"error":"Invalid request"}"#)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(connection, status: 400, body: #"{"error":"Invalid request"}"#)
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Only accept POST /mcp
        guard method == "POST" && path == "/mcp" else {
            sendHTTPResponse(connection, status: 404, body: #"{"error":"Not found"}"#)
            return
        }

        // Find the body (after empty line)
        var body = ""
        var foundEmptyLine = false
        for line in lines {
            if foundEmptyLine {
                if !body.isEmpty { body += "\r\n" }
                body += line
            } else if line.isEmpty {
                foundEmptyLine = true
            }
        }

        // Handle Content-Length for partial reads — if the body seems incomplete,
        // try to read more data. For simplicity, we assume single-read for now.
        guard !body.isEmpty else {
            sendHTTPResponse(connection, status: 400, body: #"{"error":"Empty body"}"#)
            return
        }

        // Parse JSON-RPC request
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method_name = json["method"] as? String else {
            sendHTTPResponse(connection, status: 400, body: #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"},"id":null}"#)
            return
        }

        let requestId = json["id"]
        let params = json["params"] as? [String: Any]

        let responseBody = await handleJSONRPC(method: method_name, params: params, id: requestId)
        sendHTTPResponse(connection, status: 200, body: responseBody)
    }

    private func sendHTTPResponse(_ connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"

        var fullData = response.data(using: .utf8) ?? Data()
        fullData.append(bodyData)

        connection.send(content: fullData, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON-RPC Handling

    private func handleJSONRPC(method: String, params: [String: Any]?, id: Any?) async -> String {
        let idJSON = formatJSONValue(id)

        switch method {
        case "initialize":
            return """
            {"jsonrpc":"2.0","id":\(idJSON),"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"terminatab","version":"0.1.0"}}}
            """

        case "notifications/initialized":
            // Notification — no response needed, but we return empty for HTTP
            return """
            {"jsonrpc":"2.0","id":\(idJSON),"result":{}}
            """

        case "tools/list":
            return """
            {"jsonrpc":"2.0","id":\(idJSON),"result":{"tools":\(toolSchemas)}}
            """

        case "tools/call":
            return await handleToolCall(params: params, id: idJSON)

        default:
            return """
            {"jsonrpc":"2.0","id":\(idJSON),"error":{"code":-32601,"message":"Method not found"}}
            """
        }
    }

    private func handleToolCall(params: [String: Any]?, id: String) async -> String {
        guard let params,
              let toolName = params["name"] as? String else {
            return """
            {"jsonrpc":"2.0","id":\(id),"error":{"code":-32602,"message":"Invalid params: missing tool name"}}
            """
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        // Check MCP is enabled
        let enabled = webSocketServer.mcpEnabledState.withLock { $0 }
        guard enabled else {
            return """
            {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"DevTools MCP is not enabled. Enable it from the Terminatab menu bar."}],"isError":true}}
            """
        }

        // Generate a unique request ID
        let reqId = requestCounter.withLock { val -> String in
            val += 1
            return "mcp-\(val)"
        }

        // Serialize arguments to JSON
        let argsJSON: String
        if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
           let argsStr = String(data: argsData, encoding: .utf8) {
            argsJSON = argsStr
        } else {
            argsJSON = "{}"
        }

        do {
            let resultJSON = try await webSocketServer.sendMCPRequest(id: reqId, tool: toolName, params: argsJSON)

            // Parse the response to check for errors
            if let resultData = resultJSON.data(using: .utf8),
               let resultObj = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {

                if let errorMsg = resultObj["error"] as? String {
                    return """
                    {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"\(escapeJSON(errorMsg))"}],"isError":true}}
                    """
                }

                // For screenshot, return as image content
                if toolName == "screenshot", let imgData = resultObj["data"] as? String {
                    return """
                    {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"image","data":"\(imgData)","mimeType":"image/png"}]}}
                    """
                }

                // For other results, serialize as text
                let resultText: String
                if let content = resultObj["content"] as? String {
                    resultText = content
                } else if let value = resultObj["value"] {
                    if let str = value as? String {
                        resultText = str
                    } else if JSONSerialization.isValidJSONObject(value),
                              let valueData = try? JSONSerialization.data(withJSONObject: value),
                              let valueStr = String(data: valueData, encoding: .utf8) {
                        resultText = valueStr
                    } else {
                        resultText = "\(value)"
                    }
                } else {
                    resultText = resultJSON
                }
                return """
                {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"\(escapeJSON(resultText))"}]}}
                """
            }

            // Result is not a dict (e.g. list_tabs returns an array) — return as text
            return """
            {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"\(escapeJSON(resultJSON))"}]}}
            """

        } catch let error as MCPError {
            return """
            {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"\(escapeJSON(error.errorDescription ?? "Unknown error"))"}],"isError":true}}
            """
        } catch {
            return """
            {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"\(escapeJSON(error.localizedDescription))"}],"isError":true}}
            """
        }
    }

    // MARK: - Tool Schemas

    private var toolSchemas: String {
        """
        [{"name":"list_tabs","description":"List all open Chrome tabs across all windows. Returns tab ID, title, URL, window ID, whether it's the active tab, and whether the debugger is attached.","inputSchema":{"type":"object","properties":{},"required":[]}},{"name":"screenshot","description":"Capture a screenshot of a Chrome tab. Returns a base64-encoded PNG image.","inputSchema":{"type":"object","properties":{"tabId":{"type":"integer","description":"The tab ID to screenshot (from list_tabs)"},"format":{"type":"string","description":"Image format: png or jpeg","default":"png"}},"required":["tabId"]}},{"name":"evaluate_javascript","description":"Execute JavaScript code in a Chrome tab's page context and return the result.","inputSchema":{"type":"object","properties":{"tabId":{"type":"integer","description":"The tab ID to run JavaScript in (from list_tabs)"},"expression":{"type":"string","description":"JavaScript expression to evaluate"}},"required":["tabId","expression"]}},{"name":"get_page_content","description":"Get the full HTML content of a Chrome tab's page.","inputSchema":{"type":"object","properties":{"tabId":{"type":"integer","description":"The tab ID to get content from (from list_tabs)"}},"required":["tabId"]}}]
        """
    }

    // MARK: - Helpers

    private func formatJSONValue(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let num = value as? Int { return "\(num)" }
        if let num = value as? Double { return "\(num)" }
        if let str = value as? String { return "\"\(escapeJSON(str))\"" }
        return "null"
    }

    private func escapeJSON(_ str: String) -> String {
        var result = ""
        for char in str {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(char)
            }
        }
        return result
    }
}
