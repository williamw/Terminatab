const std = @import("std");
const builtin = @import("builtin");
const websocket = @import("websocket");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const ws_handler = @import("ws_handler.zig");

extern fn macos_app_main() void;

const PORT: u16 = 7681;
const ADDRESS = "127.0.0.1";

const Context = struct {
    session_manager: *session_mod.SessionManager,
    allocator: std.mem.Allocator,
};

const WsHandler = struct {
    conn: *websocket.Conn,
    handler: ws_handler.Handler(websocket.Conn),
    pty_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    pub fn init(_: *websocket.Handshake, conn: *websocket.Conn, ctx: *Context) !WsHandler {
        return .{
            .conn = conn,
            .handler = ws_handler.Handler(websocket.Conn).init(conn, ctx.session_manager, ctx.allocator),
            .pty_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn clientMessage(self: *WsHandler, data: []const u8) !void {
        const had_session = self.handler.current_session_id != null;

        try self.handler.handleMessage(data);

        // If we just attached/created a session and don't have a read thread yet, start one
        if (!had_session and self.handler.current_session_id != null and self.pty_thread == null) {
            self.pty_thread = try std.Thread.spawn(.{}, ptyReadLoop, .{self});
        }
    }

    pub fn close(self: *WsHandler) void {
        self.should_stop.store(true, .release);
        self.handler.handleClose();
        if (self.pty_thread) |t| {
            t.join();
        }
    }

    fn ptyReadLoop(self: *WsHandler) void {
        var buf: [4096]u8 = undefined;
        const allocator = self.handler.allocator;

        while (!self.should_stop.load(.acquire)) {
            const session_id = self.handler.current_session_id orelse break;

            const session = self.handler.session_manager.getSession(session_id) orelse break;

            const n = session.pty.read(&buf) catch break;
            if (n == 0) {
                // PTY closed / EOF
                break;
            }

            const json = protocol.serializeServerMessage(allocator, .{
                .output = .{ .session_id = session_id, .data = buf[0..n] },
            }) catch break;
            defer allocator.free(json);

            self.conn.write(json) catch break;
        }
    }
};

pub fn main() !void {
    if (builtin.os.tag == .macos) {
        macos_app_main();
    } else {
        try serverMain();
    }
}

export fn terminatab_server_start() void {
    serverMain() catch |err| {
        std.log.err("Server failed: {}", .{err});
    };
}

fn serverMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("terminatab-server starting on ws://{s}:{d}", .{ ADDRESS, PORT });

    var manager = session_mod.SessionManager.init(allocator);
    defer manager.deinit();

    // Start cleanup thread
    const cleanup_thread = try std.Thread.spawn(.{}, cleanupLoop, .{&manager});
    defer cleanup_thread.detach();

    var ctx = Context{
        .session_manager = &manager,
        .allocator = allocator,
    };

    var server = try websocket.Server(WsHandler).init(allocator, .{
        .port = PORT,
        .address = ADDRESS,
    });
    defer server.deinit();

    std.log.info("Listening on ws://{s}:{d}", .{ ADDRESS, PORT });

    server.listen(&ctx) catch |err| {
        std.log.err("Server error: {}", .{err});
    };
}

fn cleanupLoop(manager: *session_mod.SessionManager) void {
    while (true) {
        std.time.sleep(5 * std.time.ns_per_s);
        manager.cleanup(30);
    }
}
