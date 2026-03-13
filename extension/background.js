// Terminatab — Background Service Worker
// Opens a side panel on web pages, or a full terminal tab otherwise.
// Also handles MCP DevTools control channel via WebSocket.

chrome.action.onClicked.addListener(async (tab) => {
  const url = tab.url || '';
  if (url.startsWith('http://') || url.startsWith('https://')) {
    chrome.sidePanel.open({ tabId: tab.id });
  } else {
    chrome.tabs.update(tab.id, { url: chrome.runtime.getURL('terminal.html') });
  }
});

// --- MCP DevTools Control Channel ---

let mcpSocket = null;
let mcpEnabled = false;
let mcpReconnectTimer = null;
const attachedTabs = new Set();

function connectMCPControl() {
  if (mcpSocket && mcpSocket.readyState <= WebSocket.OPEN) return;

  try {
    mcpSocket = new WebSocket('ws://127.0.0.1:7681');
  } catch {
    scheduleMCPReconnect();
    return;
  }

  mcpSocket.onopen = () => {
    mcpSocket.send(JSON.stringify({ type: 'mcp_control' }));
  };

  mcpSocket.onmessage = (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    handleMCPMessage(msg);
  };

  mcpSocket.onclose = () => {
    mcpSocket = null;
    scheduleMCPReconnect();
  };

  mcpSocket.onerror = () => {
    // onclose will fire after this
  };
}

function scheduleMCPReconnect() {
  if (mcpReconnectTimer) return;
  mcpReconnectTimer = setTimeout(() => {
    mcpReconnectTimer = null;
    connectMCPControl();
  }, 3000);
}

// Keep service worker alive and reconnect WebSocket on alarm
chrome.alarms.create('mcp-keepalive', { periodInMinutes: 0.25 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'mcp-keepalive') {
    // Reconnect if needed
    if (!mcpSocket || mcpSocket.readyState > WebSocket.OPEN) {
      connectMCPControl();
    } else if (mcpSocket.readyState === WebSocket.OPEN) {
      mcpSocket.send(JSON.stringify({ type: 'ping' }));
    }
  }
});

function sendMCPMessage(msg) {
  if (mcpSocket && mcpSocket.readyState === WebSocket.OPEN) {
    mcpSocket.send(JSON.stringify(msg));
  }
}

async function handleMCPMessage(msg) {
  switch (msg.type) {
    case 'mcp_enable':
      await enableDevToolsMCP();
      break;
    case 'mcp_disable':
      await disableDevToolsMCP();
      break;
    case 'mcp_request':
      await handleMCPRequest(msg);
      break;
  }
}

// --- Enable/Disable DevTools MCP ---

function isAttachable(url) {
  if (!url) return false;
  if (url.startsWith('chrome://')) return false;
  if (url.startsWith('chrome-extension://')) return false;
  if (url.startsWith('devtools://')) return false;
  if (url.startsWith('about:')) return false;
  return true;
}

async function enableDevToolsMCP() {
  mcpEnabled = true;

  // Attach to all eligible tabs across all windows
  const tabs = await chrome.tabs.query({});
  let attachCount = 0;
  for (const tab of tabs) {
    if (isAttachable(tab.url)) {
      try {
        await chrome.debugger.attach({ tabId: tab.id }, '1.3');
        attachedTabs.add(tab.id);
        attachCount++;
      } catch {
        // Tab may already have debugger attached or be otherwise ineligible
      }
    }
  }

  // Listen for new tabs
  chrome.tabs.onCreated.addListener(onTabCreatedForMCP);
  chrome.tabs.onUpdated.addListener(onTabUpdatedForMCP);
  chrome.debugger.onDetach.addListener(onDebuggerDetach);

  sendMCPMessage({ type: 'mcp_enabled', tab_count: attachCount });
}

async function disableDevToolsMCP() {
  mcpEnabled = false;

  // Remove listeners
  chrome.tabs.onCreated.removeListener(onTabCreatedForMCP);
  chrome.tabs.onUpdated.removeListener(onTabUpdatedForMCP);
  chrome.debugger.onDetach.removeListener(onDebuggerDetach);

  // Detach all debuggers
  for (const tabId of attachedTabs) {
    try {
      await chrome.debugger.detach({ tabId });
    } catch {
      // Tab may have been closed
    }
  }
  attachedTabs.clear();

  sendMCPMessage({ type: 'mcp_disabled' });
}

function onTabCreatedForMCP(tab) {
  // New tabs often start with about:blank, wait for update
}

function onTabUpdatedForMCP(tabId, changeInfo, tab) {
  if (!mcpEnabled) return;
  if (changeInfo.status !== 'complete') return;
  if (!isAttachable(tab.url)) return;
  if (attachedTabs.has(tabId)) return;

  chrome.debugger.attach({ tabId }, '1.3').then(() => {
    attachedTabs.add(tabId);
  }).catch(() => {});
}

function onDebuggerDetach(source, reason) {
  if (source.tabId) {
    attachedTabs.delete(source.tabId);
  }
}

// --- MCP Tool Handlers ---

async function handleMCPRequest(msg) {
  const { id, tool, params } = msg;
  try {
    let result;
    switch (tool) {
      case 'list_tabs':
        result = await toolListTabs();
        break;
      case 'screenshot':
        result = await toolScreenshot(params);
        break;
      case 'evaluate_javascript':
        result = await toolEvaluateJavascript(params);
        break;
      case 'get_page_content':
        result = await toolGetPageContent(params);
        break;
      default:
        sendMCPMessage({ type: 'mcp_response', id, error: `Unknown tool: ${tool}` });
        return;
    }
    sendMCPMessage({ type: 'mcp_response', id, result });
  } catch (err) {
    sendMCPMessage({ type: 'mcp_response', id, error: err.message || String(err) });
  }
}

async function toolListTabs() {
  const [tabs, targets] = await Promise.all([
    chrome.tabs.query({}),
    chrome.debugger.getTargets(),
  ]);
  const attachedTabIds = new Set(targets.filter(t => t.attached).map(t => t.tabId));
  return tabs.map(t => ({
    id: t.id,
    title: t.title,
    url: t.url,
    windowId: t.windowId,
    active: t.active,
    attached: attachedTabIds.has(t.id),
  }));
}

// Ensure debugger is attached to a tab, auto-attaching if needed.
// Handles service worker restarts where in-memory Set is lost but Chrome
// still has the debugger attached — or needs to re-attach.
async function ensureAttached(tabId) {
  tabId = Number(tabId);
  if (attachedTabs.has(tabId)) return;
  // Check if Chrome already has it attached (e.g. from before SW restart)
  const targets = await chrome.debugger.getTargets();
  const alreadyAttached = targets.some(t => t.tabId === tabId && t.attached);
  if (alreadyAttached) {
    attachedTabs.add(tabId);
    return;
  }
  // Try to attach
  await chrome.debugger.attach({ tabId }, '1.3');
  attachedTabs.add(tabId);
}

async function toolScreenshot(params) {
  const tabId = Number(params.tabId);
  await ensureAttached(tabId);
  const result = await chrome.debugger.sendCommand({ tabId }, 'Page.captureScreenshot', {
    format: params.format || 'png',
  });
  return { data: result.data };
}

async function toolEvaluateJavascript(params) {
  const tabId = Number(params.tabId);
  await ensureAttached(tabId);
  const result = await chrome.debugger.sendCommand({ tabId }, 'Runtime.evaluate', {
    expression: params.expression,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || 'JavaScript evaluation error');
  }
  return { value: result.result.value, type: result.result.type };
}

async function toolGetPageContent(params) {
  const tabId = Number(params.tabId);
  await ensureAttached(tabId);
  const result = await chrome.debugger.sendCommand({ tabId }, 'Runtime.evaluate', {
    expression: 'document.documentElement.outerHTML',
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || 'Failed to get page content');
  }
  return { content: result.result.value };
}

// --- Start MCP control connection ---
connectMCPControl();
