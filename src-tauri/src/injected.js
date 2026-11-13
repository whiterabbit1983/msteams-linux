function (linkPolicy, windowLabel) {
  if (window.__msteamsHooked) return;
  window.__msteamsHooked = true;

  function shouldOpenExternally(url) {
    if (!['http:', 'https:', 'mailto:', 'tel:'].includes(url.protocol)) return false;
    const host = url.hostname.toLowerCase();
    return !linkPolicy.teamsHosts.concat(linkPolicy.authenticationHosts).some(
      suffix => host === suffix || host.endsWith('.' + suffix)
    );
  }

  function openClickedLink(event) {
    if (event.defaultPrevented || event.isTrusted === false) return;
    if (event.type === 'auxclick' ? event.button !== 1 : event.button !== 0) return;
    const anchor = event.composedPath().find(node =>
      node && typeof node.tagName === 'string' && node.tagName.toLowerCase() === 'a'
    );
    if (!anchor || !anchor.href || anchor.hasAttribute('download')) return;
    let url;
    try { url = new URL(anchor.href, location.href); } catch (_) { return; }
    if (!shouldOpenExternally(url)) return;
    const bridge = window.__TAURI_INTERNALS__;
    if (!bridge || typeof bridge.invoke !== 'function') return;
    let request;
    try {
      request = bridge.invoke('open_external_link', { url: url.href });
    } catch (error) {
      console.error('[msteams] Could not dispatch external link:', error);
      return; // Keep native navigation available when the bridge is absent.
    }
    // Handle the real click before Teams turns it into an asynchronous blank
    // popup. Do not leave both our handler and Teams opening the same link.
    event.preventDefault();
    event.stopImmediatePropagation();
    Promise.resolve(request).catch(error => {
      console.error('[msteams] Could not open external link:', error);
    });
  }
  const documentHost = new URL(location.href).hostname.toLowerCase();
  const teamsDocument = linkPolicy.teamsHosts.some(host => documentHost === host || documentHost.endsWith('.' + host));
  if (windowLabel === 'main' && teamsDocument) {
    window.addEventListener('click', openClickedLink, true);
    window.addEventListener('auxclick', openClickedLink, true);
  }

  let sessionCount = 0;
  let titleCount = 0;
  let last = -1;

  function current() { return Math.max(sessionCount, titleCount); }

  function report() {
    const count = current();
    if (count === last) return;
    last = count;
    try {
      Promise.resolve(window.__TAURI_INTERNALS__.invoke('set_unread_count', { count })).catch(() => {});
    } catch (_) {}
  }

  function notify(title, body) {
    try {
      Promise.resolve(window.__TAURI_INTERNALS__.invoke('show_notification', {
        title: String(title == null ? 'Microsoft Teams' : title),
        body: String(body == null ? '' : body)
      })).catch(() => {});
    } catch (_) {}
  }

  try {
    function TmsNotification(title, options) {
      options = options || {};
      sessionCount += 1;
      report();
      notify(title, options.body);
      this.title = title;
      this.body = options.body || '';
      this.onclick = null;
      this.close = function () {};
      this.addEventListener = function () {};
      this.removeEventListener = function () {};
      this.dispatchEvent = function () { return true; };
    }
    TmsNotification.permission = 'granted';
    TmsNotification.requestPermission = function (callback) {
      if (typeof callback === 'function') callback('granted');
      return Promise.resolve('granted');
    };
    window.Notification = TmsNotification;
  } catch (_) {}

  function scanTitle() {
    const match = /^\(\s*(\d+)\s*\)/.exec(document.title || '');
    const count = match ? parseInt(match[1], 10) : 0;
    if (count !== titleCount) { titleCount = count; report(); }
  }

  function watchTitle() {
    const head = document.head;
    if (!head) return;
    let watchedTitle = null;
    const titleObserver = new MutationObserver(scanTitle);
    function attachTitle() {
      const title = head.querySelector('title');
      if (title === watchedTitle) return;
      titleObserver.disconnect();
      watchedTitle = title;
      if (title) titleObserver.observe(title, { subtree: true, childList: true, characterData: true });
      scanTitle();
    }
    // Only direct changes to <head> can replace <title>. Never observe the
    // documentElement or body: Teams changes them on every keystroke/scroll.
    new MutationObserver(attachTitle).observe(head, { childList: true });
    attachTitle();
  }
  try {
    if (document.head) watchTitle();
    else document.addEventListener('DOMContentLoaded', watchTitle, { once: true });
  } catch (_) {}

  window.addEventListener('focus', function () { sessionCount = 0; report(); });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { sessionCount = 0; report(); }
  });
  // Fallback for pages that create/replace their title unusually; no DOM walk.
  setInterval(scanTitle, 3000);
  setTimeout(scanTitle, 1500);
}
