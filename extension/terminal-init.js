const container = document.getElementById('terminal-container');
const status = document.getElementById('connection-status');

// Check for session ID in URL params (for pop-out / attach)
const params = new URLSearchParams(window.location.search);
const sessionId = params.get('session') || null;

const manager = new TerminalManager(container, status, {
  mode: 'fulltab',
  sessionId: sessionId,
});
manager.init();
