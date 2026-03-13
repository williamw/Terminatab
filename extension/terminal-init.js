const container = document.getElementById('terminal-container');
const status = document.getElementById('connection-status');

// Check for session ID in URL params (for bookmarked sessions)
const params = new URLSearchParams(window.location.search);
const sessionId = params.get('session') || null;

const manager = new TerminalManager(container, status, {
  sessionId: sessionId,
  onTitleChange: (title) => { document.title = title; },
});
manager.init();
