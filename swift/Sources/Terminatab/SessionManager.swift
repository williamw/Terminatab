import Foundation

struct Session: Sendable {
    let id: String
    let pty: TerminalProcess
    var connected: Bool
    var lastActivity: Date
}

actor SessionManager {
    private var sessions: [String: Session] = [:]

    /// Create a new session with a PTY. Returns the session ID.
    func createSession(cols: UInt16, rows: UInt16) throws -> String {
        let pty = try TerminalProcess.spawn(cols: cols, rows: rows)

        // Generate random session ID (8 random bytes → 16 hex chars)
        var randomBytes = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&randomBytes, 8)
        let sessionId = randomBytes.map { String(format: "%02x", $0) }.joined()

        let session = Session(
            id: sessionId,
            pty: pty,
            connected: true,
            lastActivity: Date()
        )
        sessions[sessionId] = session
        return sessionId
    }

    /// Get a session by ID.
    func getSession(_ sessionId: String) -> Session? {
        sessions[sessionId]
    }

    /// Write data to a session's PTY.
    func writeToSession(_ sessionId: String, data: String) {
        sessions[sessionId]?.pty.write(data)
        sessions[sessionId]?.lastActivity = Date()
    }

    /// Resize a session's PTY.
    func resizeSession(_ sessionId: String, cols: UInt16, rows: UInt16) throws {
        try sessions[sessionId]?.pty.resize(cols: cols, rows: rows)
    }

    /// Mark a session as connected and update activity.
    func markConnected(_ sessionId: String) {
        sessions[sessionId]?.connected = true
        sessions[sessionId]?.lastActivity = Date()
    }

    /// Mark a session as disconnected.
    func markDisconnected(_ sessionId: String) {
        sessions[sessionId]?.connected = false
        sessions[sessionId]?.lastActivity = Date()
    }

    /// Remove and clean up a session.
    func removeSession(_ sessionId: String) {
        if let session = sessions.removeValue(forKey: sessionId) {
            session.pty.close()
        }
    }

    /// Remove sessions that have been disconnected longer than timeout.
    func cleanup(timeout: TimeInterval = 30) {
        let cutoff = Date().addingTimeInterval(-timeout)
        let expired = sessions.filter { !$0.value.connected && $0.value.lastActivity < cutoff }
        for (id, _) in expired {
            if let session = sessions.removeValue(forKey: id) {
                session.pty.close()
            }
        }
    }

    /// Get the count of active sessions.
    var count: Int { sessions.count }

    /// Create an output stream for a session's PTY.
    func outputStream(for sessionId: String) -> AsyncStream<Data>? {
        sessions[sessionId]?.pty.outputStream()
    }
}
