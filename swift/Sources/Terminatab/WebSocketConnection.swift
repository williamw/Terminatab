import Foundation
import Network

enum ConnectionType {
    case terminal
    case mcpControl
}

final class WebSocketConnection: @unchecked Sendable {
    let connection: NWConnection
    let sessionManager: SessionManager
    var currentSessionId: String?
    var readTask: Task<Void, Never>?
    var onClose: (() -> Void)?
    var connectionType: ConnectionType = .terminal
    weak var server: WebSocketServer?

    init(connection: NWConnection, sessionManager: SessionManager) {
        self.connection = connection
        self.sessionManager = sessionManager
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
            case .failed, .cancelled:
                self?.handleDisconnect()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }

            if let error {
                NSLog("WebSocket receive error: %@", error.localizedDescription)
                handleDisconnect()
                return
            }

            guard let content,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text,
                  let text = String(data: content, encoding: .utf8)
            else {
                // Continue receiving even if this message was not text
                if error == nil { receiveLoop() }
                return
            }

            handleMessage(text)
            receiveLoop()
        }
    }

    private func handleMessage(_ json: String) {
        let msg: ClientMessage
        do {
            msg = try parseClientMessage(json)
        } catch {
            if connectionType == .terminal {
                sendMessage(.error(message: "Invalid message"))
            }
            return
        }

        switch msg {
        case .mcpControl:
            connectionType = .mcpControl
            server?.setMCPControlConnection(self)
        case .mcpEnabled(let tabCount):
            server?.handleMCPEnabled(tabCount: tabCount)
        case .mcpDisabled:
            server?.handleMCPDisabled()
        case .mcpResponse(let id, let result):
            server?.handleMCPResponse(id: id, rawJSON: result)
        case .ping:
            break // keepalive, no response needed
        case .newSession:
            handleNewSession()
        case .attach(let sessionId):
            handleAttach(sessionId)
        case .input(let sessionId, let data):
            Task { await sessionManager.writeToSession(sessionId, data: data) }
        case .resize(let sessionId, let cols, let rows):
            Task { try? await sessionManager.resizeSession(sessionId, cols: cols, rows: rows) }
        }
    }

    private func handleNewSession() {
        Task {
            do {
                let sessionId = try await sessionManager.createSession(cols: 80, rows: 24)
                currentSessionId = sessionId
                sendMessage(.sessionCreated(sessionId: sessionId))
                startPTYReadLoop(sessionId: sessionId)
            } catch {
                sendMessage(.error(message: "Failed to create session"))
            }
        }
    }

    private func handleAttach(_ sessionId: String) {
        Task {
            if await sessionManager.getSession(sessionId) != nil {
                await sessionManager.markConnected(sessionId)
                currentSessionId = sessionId
                sendMessage(.sessionCreated(sessionId: sessionId))
                startPTYReadLoop(sessionId: sessionId)
            } else {
                sendMessage(.error(message: "Session not found"))
            }
        }
    }

    private func startPTYReadLoop(sessionId: String) {
        readTask?.cancel()
        readTask = Task {
            guard let stream = await sessionManager.outputStream(for: sessionId) else { return }
            var utf8Remainder = Data()
            for await chunk in stream {
                if Task.isCancelled { break }
                var data = utf8Remainder + chunk
                utf8Remainder = Data()
                let tail = incompleteUTF8Tail(data)
                if tail > 0 {
                    utf8Remainder = data.suffix(tail)
                    data = data.prefix(data.count - tail)
                }
                if !data.isEmpty {
                    sendRawJSON(serializeOutputData(sessionId: sessionId, data: data))
                }
            }
            // Flush any remaining bytes
            if !utf8Remainder.isEmpty {
                sendRawJSON(serializeOutputData(sessionId: sessionId, data: utf8Remainder))
            }
            // PTY closed — notify client
            sendMessage(.sessionEnded(sessionId: sessionId))
        }
    }

    private func handleDisconnect() {
        readTask?.cancel()
        readTask = nil
        if connectionType == .mcpControl {
            server?.clearMCPControlConnection(self)
        }
        if let sid = currentSessionId {
            Task { await sessionManager.markDisconnected(sid) }
        }
        onClose?()
    }

    /// Send pre-built JSON Data directly, bypassing String conversion.
    private func sendRawJSON(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in
            if let error { NSLog("WebSocket send error: %@", error.localizedDescription) }
        })
    }

    func sendMessage(_ msg: ServerMessage) {
        let json = serializeServerMessage(msg)
        guard let data = json.data(using: .utf8) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "text",
            metadata: [metadata]
        )

        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    NSLog("WebSocket send error: %@", error.localizedDescription)
                }
            }
        )
    }

    func sendMCPMessage(_ msg: MCPServerMessage) {
        let json = serializeMCPServerMessage(msg)
        guard let data = json.data(using: .utf8) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "text",
            metadata: [metadata]
        )

        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    NSLog("WebSocket send error: %@", error.localizedDescription)
                }
            }
        )
    }
}
