// Terminatab — Terminal + WebSocket Logic

const WS_URL = 'ws://127.0.0.1:7681';

// ── Protocol Helpers ─────────────────────────────────────────────────

function buildMessage(type, fields) {
  return JSON.stringify({ type, ...fields });
}

function parseServerMessage(json) {
  return JSON.parse(json);
}

// ── Reconnect Backoff ────────────────────────────────────────────────

class ReconnectBackoff {
  constructor(baseDelay = 1000, maxAttempts = 5) {
    this.baseDelay = baseDelay;
    this.maxAttempts = maxAttempts;
    this.attempt = 0;
  }

  nextDelay() {
    this.attempt++;
    return this.baseDelay * Math.pow(2, this.attempt - 1);
  }

  reset() {
    this.attempt = 0;
  }

  get exhausted() {
    return this.attempt >= this.maxAttempts;
  }
}

// ── Terminal Manager ─────────────────────────────────────────────────

class TerminalManager {
  constructor(containerEl, statusEl, options = {}) {
    this.container = containerEl;
    this.statusEl = statusEl;
    this.sessionId = options.sessionId || null;
    this.ws = null;
    this.term = null;
    this.fitAddon = null;
    this.backoff = new ReconnectBackoff();
    this._resizeObserver = null;
    this._reconnecting = false;
  }

  init() {
    // Create xterm.js terminal
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: '#1e1e1e',
        foreground: '#d4d4d4',
        cursor: '#d4d4d4',
        selectionBackground: '#264f78',
      },
    });

    // Load addons
    this.fitAddon = new FitAddon.FitAddon();
    this.term.loadAddon(this.fitAddon);

    if (typeof WebLinksAddon !== 'undefined') {
      this.term.loadAddon(new WebLinksAddon.WebLinksAddon());
    }

    // Mount terminal
    this.term.open(this.container);
    requestAnimationFrame(() => {
      this.fitAddon.fit();
    });

    // Handle terminal input → send to server
    this.term.onData((data) => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN && this.sessionId) {
        this.ws.send(buildMessage('input', {
          session_id: this.sessionId,
          data: data,
        }));
      }
    });

    // Handle resize → send to server
    this.term.onResize(({ cols, rows }) => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN && this.sessionId) {
        this.ws.send(buildMessage('resize', {
          session_id: this.sessionId,
          cols: cols,
          rows: rows,
        }));
      }
    });

    // Auto-fit on container resize
    this._resizeObserver = new ResizeObserver(() => {
      if (this.fitAddon) {
        this.fitAddon.fit();
      }
    });
    this._resizeObserver.observe(this.container);

    // Connect WebSocket
    this.connect();
  }

  connect() {
    this.showStatus('Connecting...');

    try {
      this.ws = new WebSocket(WS_URL);
    } catch (e) {
      this.showStatus('Start the Terminatab server', 'Could not connect to ' + WS_URL);
      this.scheduleReconnect();
      return;
    }

    this.ws.onopen = () => {
      this.backoff.reset();
      this.hideStatus();

      if (this.sessionId) {
        // Reattach to existing session
        this.ws.send(buildMessage('attach', { session_id: this.sessionId }));
      } else {
        // Create new session
        this.ws.send(buildMessage('new_session'));
      }
    };

    this.ws.onmessage = (event) => {
      const msg = parseServerMessage(event.data);

      switch (msg.type) {
        case 'session_created':
          this.sessionId = msg.session_id;
          break;

        case 'output':
          this.term.write(msg.data);
          break;

        case 'session_ended':
          this.term.write('\r\n\x1b[90m[Session ended]\x1b[0m\r\n');
          this.sessionId = null;
          break;

        case 'error':
          this.term.write('\r\n\x1b[31m[Error: ' + msg.message + ']\x1b[0m\r\n');
          break;
      }
    };

    this.ws.onclose = () => {
      this.showStatus('Disconnected', 'Attempting to reconnect...');
      this.scheduleReconnect();
    };

    this.ws.onerror = () => {
      // onclose will fire after this
    };
  }

  scheduleReconnect() {
    if (this._reconnecting) return;

    if (this.backoff.exhausted) {
      this.showStatus('Start the Terminatab server', 'Server not reachable at ' + WS_URL);
      return;
    }

    this._reconnecting = true;
    const delay = this.backoff.nextDelay();

    setTimeout(() => {
      this._reconnecting = false;
      this.connect();
    }, delay);
  }

  showStatus(message, detail) {
    if (this.statusEl) {
      this.statusEl.classList.add('visible');
      const msgEl = this.statusEl.querySelector('.status-message');
      const detailEl = this.statusEl.querySelector('.status-detail');
      if (msgEl) msgEl.textContent = message;
      if (detailEl) detailEl.textContent = detail || '';
    }
  }

  hideStatus() {
    if (this.statusEl) {
      this.statusEl.classList.remove('visible');
    }
  }

  destroy() {
    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
    }
    if (this.ws) {
      this.ws.close();
    }
    if (this.term) {
      this.term.dispose();
    }
  }
}
