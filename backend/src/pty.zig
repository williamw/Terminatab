const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const c = @cImport({
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,

    /// Spawn a new PTY with the given shell as a login shell.
    /// If shell is null, uses $SHELL or falls back to /bin/sh.
    pub fn spawn(shell: ?[]const u8, initial_cols: u16, initial_rows: u16) !Pty {
        const shell_path = if (shell) |s| s else (std.posix.getenv("SHELL") orelse "/bin/sh");

        var ws: c.winsize = .{
            .ws_col = initial_cols,
            .ws_row = initial_rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = undefined;
        const pid = c.forkpty(&master_fd, null, null, &ws);

        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // ── Child process ──────────────────────────────────────
            // Build login shell name: prefix basename with '-'
            var login_name_buf: [257]u8 = undefined;
            var shell_path_z: [256:0]u8 = undefined;

            // Copy shell path to null-terminated buffer
            for (shell_path, 0..) |byte, i| {
                shell_path_z[i] = byte;
            }
            shell_path_z[shell_path.len] = 0;

            // Find basename
            var base_start: usize = 0;
            for (shell_path, 0..) |byte, i| {
                if (byte == '/') base_start = i + 1;
            }
            const basename = shell_path[base_start..];

            // Build "-basename"
            login_name_buf[0] = '-';
            for (basename, 0..) |byte, i| {
                login_name_buf[1 + i] = byte;
            }
            login_name_buf[1 + basename.len] = 0;

            const login_name_z: [*:0]const u8 = @ptrCast(&login_name_buf);
            const shell_z: [*:0]const u8 = @ptrCast(&shell_path_z);

            const argv = [_:null]?[*:0]const u8{ login_name_z, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

            _ = std.c.execve(shell_z, &argv, envp);
            // If execve returns, it failed
            std.c._exit(127);
        }

        // ── Parent process ─────────────────────────────────────
        return .{
            .master_fd = @intCast(master_fd),
            .child_pid = @intCast(pid),
        };
    }

    /// Read available output from the PTY master.
    pub fn read(self: *Pty, buf: []u8) !usize {
        return std.posix.read(self.master_fd, buf) catch |err| {
            if (err == error.InputOutput) return 0;
            return err;
        };
    }

    /// Write input to the PTY master. Handles partial writes.
    pub fn write(self: *Pty, data: []const u8) !void {
        var total: usize = 0;
        while (total < data.len) {
            const n = std.posix.write(self.master_fd, data[total..]) catch |err| {
                if (err == error.InputOutput) return;
                return err;
            };
            total += n;
        }
    }

    /// Resize the PTY to new dimensions.
    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var ws: c.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        const ret = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
        if (ret < 0) return error.ResizeFailed;
    }

    /// Close the PTY: kill child process and close file descriptor.
    pub fn close(self: *Pty) void {
        _ = c.kill(self.child_pid, c.SIGHUP);
        std.posix.close(self.master_fd);
        _ = c.waitpid(self.child_pid, null, c.WNOHANG);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

fn getDefaultShell() []const u8 {
    return std.posix.getenv("SHELL") orelse "/bin/sh";
}

test "spawn creates valid pty" {
    var pty_inst = try Pty.spawn(getDefaultShell(), 80, 24);
    defer pty_inst.close();

    try std.testing.expect(pty_inst.master_fd > 0);
    try std.testing.expect(pty_inst.child_pid > 0);
}

test "pty read returns shell output" {
    var pty_inst = try Pty.spawn(getDefaultShell(), 80, 24);
    defer pty_inst.close();

    std.time.sleep(500 * std.time.ns_per_ms);

    var buf: [4096]u8 = undefined;
    const n = try pty_inst.read(&buf);
    try std.testing.expect(n > 0);
}

test "pty write sends input" {
    var pty_inst = try Pty.spawn(getDefaultShell(), 80, 24);
    defer pty_inst.close();

    std.time.sleep(500 * std.time.ns_per_ms);

    var buf: [4096]u8 = undefined;
    _ = pty_inst.read(&buf) catch {};

    try pty_inst.write("echo hello_test_marker\n");
    std.time.sleep(500 * std.time.ns_per_ms);

    const n = try pty_inst.read(&buf);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "hello_test_marker") != null);
}

test "pty resize updates dimensions" {
    var pty_inst = try Pty.spawn(getDefaultShell(), 80, 24);
    defer pty_inst.close();

    try pty_inst.resize(120, 40);

    var ws: c.winsize = undefined;
    const ret = c.ioctl(pty_inst.master_fd, c.TIOCGWINSZ, &ws);
    try std.testing.expect(ret == 0);
    try std.testing.expectEqual(@as(u16, 120), ws.ws_col);
    try std.testing.expectEqual(@as(u16, 40), ws.ws_row);
}

test "pty close kills child process" {
    var pty_inst = try Pty.spawn(getDefaultShell(), 80, 24);
    const child_pid = pty_inst.child_pid;

    pty_inst.close();
    std.time.sleep(100 * std.time.ns_per_ms);

    const ret = c.kill(child_pid, 0);
    try std.testing.expect(ret != 0);
}

test "spawn uses login shell prefix" {
    var pty_inst = try Pty.spawn(getDefaultShell(), 80, 24);
    defer pty_inst.close();

    std.time.sleep(500 * std.time.ns_per_ms);

    var buf: [4096]u8 = undefined;
    _ = pty_inst.read(&buf) catch {};

    try pty_inst.write("echo $0\n");
    std.time.sleep(500 * std.time.ns_per_ms);

    const n = try pty_inst.read(&buf);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "-") != null);
}
