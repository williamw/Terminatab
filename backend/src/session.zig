const std = @import("std");
const Pty = @import("pty.zig").Pty;

pub const Session = struct {
    id: [16]u8,
    pty: Pty,
    connected: bool,
    last_activity: i64,
    mutex: std.Thread.Mutex,

    pub fn idStr(self: *const Session) []const u8 {
        return &self.id;
    }
};

pub const SessionManager = struct {
    sessions: std.StringHashMap(*Session),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = std.StringHashMap(*Session).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        // Clean up all sessions
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            var session = entry.value_ptr.*;
            session.pty.close();
            self.allocator.destroy(session);
        }
        self.sessions.deinit();
    }

    /// Create a new session with a PTY. Returns the session ID.
    pub fn createSession(self: *SessionManager, cols: u16, rows: u16) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Spawn the PTY
        const pty_inst = try Pty.spawn(null, cols, rows);

        // Generate random session ID (8 random bytes → 16 hex chars)
        var random_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        // Create session on the heap
        const session = try self.allocator.create(Session);
        session.* = .{
            .id = std.fmt.bytesToHex(random_bytes, .lower),
            .pty = pty_inst,
            .connected = true,
            .last_activity = std.time.timestamp(),
            .mutex = .{},
        };

        // Store in map — key is the id slice from the session itself
        try self.sessions.put(session.idStr(), session);

        return session.idStr();
    }

    /// Get a session by ID.
    pub fn getSession(self: *SessionManager, session_id: []const u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.sessions.get(session_id);
    }

    /// Remove and clean up a session.
    pub fn removeSession(self: *SessionManager, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.fetchRemove(session_id)) |entry| {
            var session = entry.value;
            session.pty.close();
            self.allocator.destroy(session);
        }
    }

    /// Mark a session as disconnected.
    pub fn markDisconnected(self: *SessionManager, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |session| {
            session.connected = false;
            session.last_activity = std.time.timestamp();
        }
    }

    /// Remove sessions that have been disconnected longer than timeout_secs.
    pub fn cleanup(self: *SessionManager, timeout_secs: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Collect IDs to remove (can't remove during iteration)
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            if (!session.connected and (now - session.last_activity) > timeout_secs) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |id| {
            if (self.sessions.fetchRemove(id)) |entry| {
                var session = entry.value;
                session.pty.close();
                self.allocator.destroy(session);
            }
        }
    }

    /// Get the count of active sessions.
    pub fn count(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.sessions.count();
    }
};

// ── Helper ─────────────────────────────────────────────────────────────

fn currentTimestamp() i64 {
    return std.time.timestamp();
}

// ── Tests ──────────────────────────────────────────────────────────────

test "create session returns unique id" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const id1 = try manager.createSession(80, 24);
    const id2 = try manager.createSession(80, 24);

    // IDs should be different
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    // IDs should be 16 hex chars
    try std.testing.expectEqual(@as(usize, 16), id1.len);
    try std.testing.expectEqual(@as(usize, 16), id2.len);
}

test "get session returns created session" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createSession(80, 24);
    const session = manager.getSession(id);
    try std.testing.expect(session != null);
    try std.testing.expectEqualStrings(id, session.?.idStr());
}

test "get nonexistent session returns null" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const session = manager.getSession("nonexistent12345");
    try std.testing.expect(session == null);
}

test "remove session deletes it" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createSession(80, 24);
    manager.removeSession(id);
    const session = manager.getSession(id);
    try std.testing.expect(session == null);
}

test "cleanup removes expired disconnected sessions" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createSession(80, 24);
    manager.markDisconnected(id);

    if (manager.getSession(id)) |session| {
        session.last_activity = currentTimestamp() - 31;
    }

    manager.cleanup(30);
    try std.testing.expect(manager.getSession(id) == null);
}

test "cleanup preserves connected sessions" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createSession(80, 24);

    if (manager.getSession(id)) |session| {
        session.last_activity = currentTimestamp() - 60;
    }

    manager.cleanup(30);
    try std.testing.expect(manager.getSession(id) != null);
}

test "cleanup preserves recently disconnected sessions" {
    var manager = SessionManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createSession(80, 24);
    manager.markDisconnected(id);

    if (manager.getSession(id)) |session| {
        session.last_activity = currentTimestamp() - 5;
    }

    manager.cleanup(30);
    try std.testing.expect(manager.getSession(id) != null);
}
