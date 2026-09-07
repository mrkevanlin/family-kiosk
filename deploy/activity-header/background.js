chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.action !== "returnToPicker" || !sender.tab?.windowId) return;

  chrome.windows.remove(sender.tab.windowId, () => {
    const error = chrome.runtime.lastError;
    sendResponse({ closed: !error, error: error?.message || null });
  });
  return true;
});
