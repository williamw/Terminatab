import Foundation
import Network
import Synchronization

final class WebSocketServer: Sendable {
    let listener: NWListener
    let sessionManager: SessionManager
    private let connections = Mutex<[ObjectIdentifier: WebSocketConnection]>([:])
    private let _mcpControlConnection = Mutex<WebSocketConnection?>(nil)
    private let _mcpPendingRequests = Mutex<[String: CheckedContinuation<String, Error>]>([:])
    let mcpEnabledState = Mutex<Bool>(false)
    let mcpEnabledTabCount = Mutex<Int>(0)
    // Callback for when MCP enabled state changes
    let _mcpStateCallback = Mutex<(@Sendable (Bool, Int) -> Void)?>(nil)

    init(port: UInt16, sessionManager: SessionManager) throws {
        self.sessionManager = sessionManager

        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

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
                NSLog("terminatab-server listening on ws://127.0.0.1:%d",
                      self.listener.port?.rawValue ?? 0)
            case .failed(let error):
                NSLog("Server failed: %@", error.localizedDescription)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [self] nwConnection in
            let conn = WebSocketConnection(
                connection: nwConnection,
                sessionManager: sessionManager
            )
            conn.server = self
            let id = ObjectIdentifier(conn)
            connections.withLock { $0[id] = conn }
            conn.onClose = { [weak self] in
                self?.connections.withLock { _ = $0.removeValue(forKey: id) }
            }
            conn.start()
        }

        listener.start(queue: .global())

        // Start cleanup timer
        Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
                await sessionManager.cleanup()
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - MCP Control Connection

    func setMCPControlConnection(_ conn: WebSocketConnection) {
        _mcpControlConnection.withLock { $0 = conn }
        NSLog("MCP control connection established")
    }

    func clearMCPControlConnection(_ conn: WebSocketConnection) {
        _mcpControlConnection.withLock { current in
            if current === conn {
                current = nil
            }
        }
        mcpEnabledState.withLock { $0 = false }
        NSLog("MCP control connection lost")
        _mcpStateCallback.withLock { $0 }?(false, 0)
    }

    var hasMCPControlConnection: Bool {
        _mcpControlConnection.withLock { $0 != nil }
    }

    func onMCPStateChange(_ callback: @escaping @Sendable (Bool, Int) -> Void) {
        _mcpStateCallback.withLock { $0 = callback }
    }

    func sendMCPEnable() {
        _mcpControlConnection.withLock { $0 }?.sendMCPMessage(.mcpEnable)
    }

    func sendMCPDisable() {
        _mcpControlConnection.withLock { $0 }?.sendMCPMessage(.mcpDisable)
    }

    func handleMCPEnabled(tabCount: Int) {
        mcpEnabledState.withLock { $0 = true }
        mcpEnabledTabCount.withLock { $0 = tabCount }
        NSLog("MCP enabled, attached to %d tabs", tabCount)
        _mcpStateCallback.withLock { $0 }?(true, tabCount)
    }

    func handleMCPDisabled() {
        mcpEnabledState.withLock { $0 = false }
        mcpEnabledTabCount.withLock { $0 = 0 }
        NSLog("MCP disabled")
        _mcpStateCallback.withLock { $0 }?(false, 0)
    }

    // MARK: - MCP Request Routing

    func sendMCPRequest(id: String, tool: String, params: String) async throws -> String {
        let conn = _mcpControlConnection.withLock { $0 }
        guard let conn else {
            throw MCPError.noControlConnection
        }

        return try await withCheckedThrowingContinuation { continuation in
            _mcpPendingRequests.withLock { $0[id] = continuation }
            conn.sendMCPMessage(.mcpRequest(id: id, tool: tool, params: params))

            // Timeout after 30 seconds
            Task {
                try await Task.sleep(for: .seconds(30))
                let pending = self._mcpPendingRequests.withLock { $0.removeValue(forKey: id) }
                pending?.resume(throwing: MCPError.timeout)
            }
        }
    }

    func handleMCPResponse(id: String, rawJSON: String) {
        let continuation = _mcpPendingRequests.withLock { $0.removeValue(forKey: id) }
        continuation?.resume(returning: rawJSON)
    }
}

enum MCPError: Error, LocalizedError {
    case noControlConnection
    case timeout
    case extensionError(String)

    var errorDescription: String? {
        switch self {
        case .noControlConnection: return "No Chrome extension connected"
        case .timeout: return "Request timed out"
        case .extensionError(let msg): return msg
        }
    }
}
