// Terminatab — Background Service Worker
// Opens a terminal tab when the extension icon is clicked.

chrome.action.onClicked.addListener(() => {
  chrome.tabs.create({ url: chrome.runtime.getURL('terminal.html') });
});
