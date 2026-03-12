# Terminatab

A Chrome extension that puts a terminal in your browser. Powered by a
lightweight local Zig server that manages PTY sessions over WebSocket.

## Prerequisites

- [Zig 0.14.x](https://ziglang.org/download/) (for building the backend)
- Google Chrome (for the extension)

## Quick Start

### 1. Clone the repo

```
git clone https://github.com/williamw/terminatab.git
cd terminatab
```

### 2. Build and run the backend

```
cd backend
zig build
./zig-out/bin/terminatab-server
```

The server starts on `ws://localhost:7681`.

On macOS, the server runs as a menu bar app — look for the **>_** icon in the
menu bar. It daemonizes automatically (the shell returns immediately). Click the
icon and choose **Quit Terminatab** to stop it.

On Linux, the server runs as a foreground process — it logs to stdout and you
stop it with Ctrl+C.

### 3. Load the Chrome extension

1. Open Chrome and navigate to `chrome://extensions`
2. Enable **Developer mode** (toggle in the top-right)
3. Click **Load unpacked**
4. Select the `extension/` directory from this repo

### 4. Use it

- **Side panel**: Click the Terminatab icon on any `http://` or `https://` page.
  The terminal opens in Chrome's side panel alongside your current tab.
- **Full tab**: Click the icon on any other page (new tab, `chrome://` pages,
  etc.) to open a terminal in a new tab.
- **Pop out**: Click the pop-out button in the side panel to move the terminal
  to its own full tab.

Each tab/panel gets its own independent shell session.

## Development

### Run backend tests

```
cd backend
zig build test
```

### Run extension tests

Open `extension/test.html` in Chrome after loading the extension.

## Architecture

```
┌─────────────────────┐       WebSocket        ┌──────────────────────┐
│   Chrome Extension   │ ◄──────────────────► │   Zig Backend         │
│  • xterm.js UI       │    localhost:7681     │  • PTY management     │
│  • Side panel        │                       │  • WebSocket server   │
│  • Full tab          │                       │  • Shell spawning     │
│                      │                       │  • Menu bar app (mac) │
└─────────────────────┘                        └──────────────────────┘
```

The Zig backend spawns PTY sessions and serves them over WebSocket. The Chrome
extension renders the terminal using xterm.js and connects to the backend. Each
tab or panel gets its own independent shell session. On macOS, the backend runs
as a menu bar app with no dock icon.

## License

MIT
