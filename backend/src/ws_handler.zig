const std = @import("std");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const SessionManager = session_mod.SessionManager;
const Session = session_mod.Session;

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

/// Mock connection interface for testing (matches websocket.Conn write API)
pub const MockConn = struct {
    messages: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockConn {
        return .{
            .messages = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockConn) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.messages.deinit();
    }

    pub fn write(self: *MockConn, data: []const u8) !void {
        const copy = try self.allocator.dupe(u8, data);
        try self.messages.append(copy);
    }
};

/// WebSocket handler generic over connection type.
/// In production, Conn is the websocket library's connection type.
/// For tests, use MockConn.
pub fn Handler(comptime Conn: type) type {
    return struct {
        const Self = @This();

        conn: *Conn,
        session_manager: *SessionManager,
        current_session_id: ?[]const u8,
        allocator: std.mem.Allocator,

        pub fn init(conn: *Conn, mgr: *SessionManager, allocator: std.mem.Allocator) Self {
            return .{
                .conn = conn,
                .session_manager = mgr,
                .current_session_id = null,
                .allocator = allocator,
            };
        }

        pub fn handleMessage(self: *Self, data: []const u8) !void {
            const msg = protocol.parseClientMessage(data) catch {
                try self.sendError("Invalid message");
                return;
            };

            switch (msg) {
                .new_session => try self.handleNewSession(),
                .attach => |payload| try self.handleAttach(payload.session_id),
                .input => |payload| try self.handleInput(payload.session_id, payload.data),
                .resize => |payload| try self.handleResize(payload.session_id, payload.cols, payload.rows),
            }
        }

        pub fn handleClose(self: *Self) void {
            if (self.current_session_id) |sid| {
                self.session_manager.markDisconnected(sid);
            }
        }

        fn handleNewSession(self: *Self) !void {
            const session_id = try self.session_manager.createSession(80, 24);
            self.current_session_id = session_id;

            const json = try protocol.serializeServerMessage(self.allocator, .{
                .session_created = .{ .session_id = session_id },
            });
            defer self.allocator.free(json);

            try self.conn.write(json);
        }

        fn handleAttach(self: *Self, session_id: []const u8) !void {
            if (self.session_manager.getSession(session_id)) |session| {
                session.connected = true;
                self.current_session_id = session.idStr();

                const json = try protocol.serializeServerMessage(self.allocator, .{
                    .session_created = .{ .session_id = session.idStr() },
                });
                defer self.allocator.free(json);

                try self.conn.write(json);
            } else {
                try self.sendError("Session not found");
            }
        }

        fn handleInput(self: *Self, session_id: []const u8, data: []const u8) !void {
            // Look up the session directly from the manager to get a mutable reference
            // We need to bypass the lock since getSession returns a pointer
            // This is safe because we only write to the PTY fd
            const mgr = self.session_manager;
            if (mgr.getSession(session_id)) |session| {
                try session.pty.write(data);
                session.last_activity = std.time.timestamp();
            }
        }

        fn handleResize(self: *Self, session_id: []const u8, cols: u16, rows: u16) !void {
            const mgr = self.session_manager;
            if (mgr.getSession(session_id)) |session| {
                try session.pty.resize(cols, rows);
            }
        }

        fn sendError(self: *Self, message: []const u8) !void {
            const json = try protocol.serializeServerMessage(self.allocator, .{
                .@"error" = .{ .message = message },
            });
            defer self.allocator.free(json);

            try self.conn.write(json);
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "new_session creates session and sends session_created" {
    const allocator = std.testing.allocator;
    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    var conn = MockConn.init(allocator);
    defer conn.deinit();

    var handler = Handler(MockConn).init(&conn, &manager, allocator);
    try handler.handleMessage("{\"type\":\"new_session\"}");

    try std.testing.expect(manager.count() == 1);

    try std.testing.expect(conn.messages.items.len > 0);
    const response = conn.messages.items[0];
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("session_created", parsed.value.object.get("type").?.string);
}

test "input message writes to correct pty" {
    const allocator = std.testing.allocator;
    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    var conn = MockConn.init(allocator);
    defer conn.deinit();

    var handler = Handler(MockConn).init(&conn, &manager, allocator);

    try handler.handleMessage("{\"type\":\"new_session\"}");
    const session_id = handler.current_session_id.?;

    var buf: [256]u8 = undefined;
    const input_msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"input\",\"session_id\":\"{s}\",\"data\":\"echo test\\n\"}}", .{session_id});

    try handler.handleMessage(input_msg);

    std.time.sleep(200 * std.time.ns_per_ms);

    if (manager.getSession(session_id)) |session| {
        var read_buf: [4096]u8 = undefined;
        const n = try session.pty.read(&read_buf);
        try std.testing.expect(n > 0);
    } else {
        return error.SessionNotFound;
    }
}

test "resize message resizes correct pty" {
    const allocator = std.testing.allocator;
    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    var conn = MockConn.init(allocator);
    defer conn.deinit();

    var handler = Handler(MockConn).init(&conn, &manager, allocator);

    try handler.handleMessage("{\"type\":\"new_session\"}");
    const session_id = handler.current_session_id.?;

    var buf: [256]u8 = undefined;
    const resize_msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"resize\",\"session_id\":\"{s}\",\"cols\":120,\"rows\":40}}", .{session_id});
    try handler.handleMessage(resize_msg);

    if (manager.getSession(session_id)) |session| {
        var ws: c.winsize = undefined;
        const ret = c.ioctl(session.pty.master_fd, c.TIOCGWINSZ, &ws);
        try std.testing.expect(ret == 0);
        try std.testing.expectEqual(@as(u16, 120), ws.ws_col);
        try std.testing.expectEqual(@as(u16, 40), ws.ws_row);
    }
}

test "attach to existing session succeeds" {
    const allocator = std.testing.allocator;
    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    var conn = MockConn.init(allocator);
    defer conn.deinit();

    var handler = Handler(MockConn).init(&conn, &manager, allocator);

    try handler.handleMessage("{\"type\":\"new_session\"}");
    const session_id = handler.current_session_id.?;
    handler.handleClose();

    var buf: [256]u8 = undefined;
    const attach_msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"attach\",\"session_id\":\"{s}\"}}", .{session_id});

    var conn2 = MockConn.init(allocator);
    defer conn2.deinit();
    var handler2 = Handler(MockConn).init(&conn2, &manager, allocator);
    try handler2.handleMessage(attach_msg);

    for (conn2.messages.items) |msg| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
        defer parsed.deinit();
        const msg_type = parsed.value.object.get("type").?.string;
        try std.testing.expect(!std.mem.eql(u8, msg_type, "error"));
    }
}

test "attach to nonexistent session returns error" {
    const allocator = std.testing.allocator;
    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    var conn = MockConn.init(allocator);
    defer conn.deinit();

    var handler = Handler(MockConn).init(&conn, &manager, allocator);
    try handler.handleMessage("{\"type\":\"attach\",\"session_id\":\"nonexistent12345\"}");

    try std.testing.expect(conn.messages.items.len > 0);
    const response = conn.messages.items[0];
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("error", parsed.value.object.get("type").?.string);
}

test "close handler marks session disconnected" {
    const allocator = std.testing.allocator;
    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    var conn = MockConn.init(allocator);
    defer conn.deinit();

    var handler = Handler(MockConn).init(&conn, &manager, allocator);
    try handler.handleMessage("{\"type\":\"new_session\"}");
    const session_id = handler.current_session_id.?;

    handler.handleClose();

    if (manager.getSession(session_id)) |session| {
        try std.testing.expect(!session.connected);
    } else {
        return error.SessionGone;
    }
}
