import Foundation
import Testing

@testable import Terminatab

@Suite struct ProtocolTests {
    @Test func parseNewSessionMessage() throws {
        let msg = try parseClientMessage("{\"type\":\"new_session\"}")
        guard case .newSession = msg else {
            Issue.record("Expected newSession, got \(msg)")
            return
        }
    }

    @Test func parseAttachMessage() throws {
        let msg = try parseClientMessage("{\"type\":\"attach\",\"session_id\":\"abc123\"}")
        guard case .attach(let sessionId) = msg else {
            Issue.record("Expected attach")
            return
        }
        #expect(sessionId == "abc123")
    }

    @Test func parseInputMessage() throws {
        let msg = try parseClientMessage("{\"type\":\"input\",\"session_id\":\"abc123\",\"data\":\"ls\\r\"}")
        guard case .input(let sessionId, let data) = msg else {
            Issue.record("Expected input")
            return
        }
        #expect(sessionId == "abc123")
        #expect(data == "ls\r")
    }

    @Test func parseResizeMessage() throws {
        let msg = try parseClientMessage("{\"type\":\"resize\",\"session_id\":\"abc123\",\"cols\":120,\"rows\":40}")
        guard case .resize(let sessionId, let cols, let rows) = msg else {
            Issue.record("Expected resize")
            return
        }
        #expect(sessionId == "abc123")
        #expect(cols == 120)
        #expect(rows == 40)
    }

    @Test func parseInvalidMessageType() {
        #expect(throws: ProtocolError.unknownMessageType) {
            try parseClientMessage("{\"type\":\"unknown\"}")
        }
    }

    @Test func parseMalformedJSON() {
        #expect(throws: ProtocolError.invalidJSON) {
            try parseClientMessage("not json at all")
        }
    }

    @Test func serializeSessionCreated() throws {
        let json = serializeServerMessage(.sessionCreated(sessionId: "abc123"))
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["type"] as? String == "session_created")
        #expect(obj["session_id"] as? String == "abc123")
    }

    @Test func serializeSessionEnded() throws {
        let json = serializeServerMessage(.sessionEnded(sessionId: "abc123"))
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["type"] as? String == "session_ended")
        #expect(obj["session_id"] as? String == "abc123")
    }

    @Test func serializeError() throws {
        let json = serializeServerMessage(.error(message: "not found"))
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["type"] as? String == "error")
        #expect(obj["message"] as? String == "not found")
    }
}
