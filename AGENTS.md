# AGENTS.md

Guidelines for AI agents working on this repository.

## Project Overview

**Terminatab** is a Chrome extension that puts a terminal in your browser. A
lightweight local server written in Zig manages PTY sessions and exposes them
over WebSocket. The Chrome extension renders the terminal using
[xterm.js](https://xtermjs.org/) and connects to that local server. On macOS,
the backend runs as a menu bar app.

## Repository Layout

```
terminatab/
├── backend/          # Zig backend server
│   ├── build.zig     # Zig build configuration
│   ├── build.zig.zon # Package manifest & dependency hashes
│   ├── resources/    # Menu bar icon template PNGs (macOS)
│   └── src/
│       ├── main.zig        # Server entry point; WebSocket listener
│       ├── macos_app.m     # macOS menu bar app (ObjC; NSStatusItem)
│       ├── protocol.zig    # Wire message definitions
│       ├── pty.zig         # PTY session lifecycle
│       ├── session.zig     # Session manager (maps connection → PTY)
│       └── ws_handler.zig  # WebSocket upgrade & frame handling
└── extension/        # Chrome extension (Manifest v3)
    ├── manifest.json
    ├── background.js       # Service worker; routes icon clicks
    ├── terminal.html       # Full-tab terminal page
    ├── sidepanel.html      # Side-panel terminal page
    ├── terminal.css
    ├── terminal.js         # Terminal + WebSocket logic
    ├── sidepanel-init.js   # Sidepanel bootstrap script
    ├── terminal-init.js    # Full-tab terminal bootstrap script
    ├── images/             # Extension icons (16/32/48/128 PNG + SVG)
    ├── test.html           # In-browser test runner
    ├── test.js             # Extension unit tests
    └── lib/                # Vendored dependencies (xterm.js, etc.)
```

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Zig 0.14.x |
| Backend dependency | [websocket.zig](https://github.com/karlseguin/websocket.zig) (zig-0.14 branch) |
| System dependency | `libutil` (Linux) / `util.h` (macOS) — provides `forkpty()` |
| macOS GUI | Objective-C (AppKit) — compiled conditionally via `build.zig` |
| Frontend | Vanilla JavaScript, Chrome Manifest v3 |
| Terminal renderer | xterm.js (vendored in `extension/lib/`) |

## Building

### Backend

```bash
cd backend
zig build
```

The binary is placed at `backend/zig-out/bin/terminatab-server`.

> **Upgrading websocket.zig**: Run `zig fetch --save "git+https://github.com/karlseguin/websocket.zig#zig-0.14"` to update the pinned hash in `build.zig.zon`.

### Extension

No build step. Load the `extension/` directory directly into Chrome (see below).

## Running

### Backend server

```bash
./backend/zig-out/bin/terminatab-server
```

Listens on `ws://localhost:7681`.

On macOS the server daemonizes into a menu bar app (no dock icon). The `>_` icon
appears in the menu bar; click it and choose **Quit Terminatab** to stop. On
Linux it runs in the foreground; stop it with `Ctrl+C`.

### Chrome extension

1. Open `chrome://extensions`.
2. Enable **Developer mode** (toggle, top-right).
3. Click **Load unpacked** and select the `extension/` directory.
4. Click the **Terminatab** icon in the toolbar — side panel opens on
   `http://https://` pages, a new terminal tab opens on everything else.

## Testing

### Backend unit tests

```bash
cd backend
zig build test
```

Tests are defined inline (Zig `test` blocks) in each `src/*.zig` file. The build
system runs them all via `zig build test`.

### Extension tests

Open `extension/test.html` in Chrome **after** loading the extension. The results
are displayed inline on the page.

## Code Conventions

- **Zig**: Follow the style already in `src/`. Prefer explicit error handling (`try`
  / `catch`); avoid `unreachable` except where truly invariant.
- **JavaScript**: Vanilla ES modules; no transpilation step. Keep logic in
  `terminal.js`; keep `background.js` minimal (service-worker constraints).
- **No linter configuration exists** for the extension. Match the surrounding code
  style when editing JS files.
- Keep vendored libraries in `extension/lib/` untouched unless upgrading them
  intentionally.

## Making Changes

- Backend changes almost always require `zig build` and `zig build test` to verify.
- Extension changes can be tested by reloading the unpacked extension in Chrome
  (`chrome://extensions` → reload button) and opening `extension/test.html`.
- Protocol changes (`protocol.zig`) must be reflected in both the backend handler
  and the extension's `terminal.js`.
- The `build.zig.zon` file contains a pinned hash for the `websocket.zig`
  dependency. Re-run `zig fetch --save ...` if you need to change the dependency
  version; commit the updated `build.zig.zon`.

## Architecture Notes

### WebSocket server (`main.zig`)

The server uses [websocket.zig](https://github.com/karlseguin/websocket.zig)'s
`websocket.Server(WsHandler)`. The `WsHandler` struct must implement:

- `init(handshake, conn, ctx) !WsHandler` — called on each new WebSocket connection
- `clientMessage(self, data) !void` — called for each incoming text frame
- `close(self) void` — called when the connection closes

A shared `Context` struct (holding `*SessionManager` and `allocator`) is passed to
`server.listen(&ctx)` and forwarded to each handler's `init`.

### PTY read loop

Each WebSocket connection spawns a dedicated thread (`ptyReadLoop`) after a
`new_session` or `attach` message creates/binds a session. The thread:

1. Reads from `session.pty.read()` in a loop
2. Serializes output via `protocol.serializeServerMessage(.output, ...)`
3. Sends it over the WebSocket via `conn.write(json)`
4. Exits when the session ends, WebSocket closes, or `should_stop` is set

### Handler generics

`ws_handler.Handler(Conn)` is generic over the connection type. Any type with a
`write([]const u8) !void` method works. In production it uses `websocket.Conn`;
tests use `MockConn` (an `ArrayList`-backed stub defined in `ws_handler.zig`).

### macOS menu bar app (`macos_app.m`)

On macOS, `main()` calls `macos_app_main()` (defined in `macos_app.m`) instead of
running the server directly. The ObjC code:

1. Forks and daemonizes (parent exits, child detaches from terminal)
2. Creates an `NSApplication` with accessory activation policy (no dock icon)
3. Sets up an `NSStatusItem` with a programmatically-drawn `>_` template icon
4. Starts the WebSocket server on a background thread via `dispatch_async`

The `.m` file is only compiled on macOS targets (`build.zig` conditional). On
Linux, `main()` falls through to `serverMain()` which runs the server directly.

### macOS PTY support

`forkpty()` lives in different headers per platform: `util.h` on macOS, `pty.h` on
Linux. This is handled via a compile-time `@cImport` conditional in `pty.zig`.

### Extension icon click behavior

`background.js` routes the toolbar icon click: on `http://`/`https://` pages it
opens the side panel; on all other pages (new tab, `chrome://`, etc.) it opens a
new terminal tab.
