const container = document.getElementById('terminal-container');
const status = document.getElementById('connection-status');

const titleEl = document.querySelector('.panel-header .title');

const manager = new TerminalManager(container, status, {
  mode: 'sidepanel',
  onTitleChange: (title) => { titleEl.textContent = title; },
});
manager.init();

document.getElementById('btn-popout').addEventListener('click', () => {
  manager.popOut();
});

document.getElementById('btn-new').addEventListener('click', () => {
  manager.destroy();
  titleEl.textContent = 'Terminatab';
  const newManager = new TerminalManager(container, status, {
    mode: 'sidepanel',
    onTitleChange: (title) => { titleEl.textContent = title; },
  });
  newManager.init();
});
