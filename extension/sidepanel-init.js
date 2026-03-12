const container = document.getElementById('terminal-container');
const status = document.getElementById('connection-status');

const manager = new TerminalManager(container, status, { mode: 'sidepanel' });
manager.init();

document.getElementById('btn-popout').addEventListener('click', () => {
  manager.popOut();
});

document.getElementById('btn-new').addEventListener('click', () => {
  manager.sessionId = null;
  manager.destroy();
  const newManager = new TerminalManager(container, status, { mode: 'sidepanel' });
  newManager.init();
});
