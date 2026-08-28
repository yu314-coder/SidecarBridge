(function () {
  "use strict";

  const elements = {
    statusCard: document.getElementById("statusCard"),
    statusIcon: document.getElementById("statusIcon"),
    statusHeadline: document.getElementById("statusHeadline"),
    statusDetail: document.getElementById("statusDetail"),
    statusPill: document.getElementById("statusPill"),
    pairingCode: document.getElementById("pairingCode"),
    connectButton: document.getElementById("connectButton"),
    disconnectButton: document.getElementById("disconnectButton"),
    inlineError: document.getElementById("inlineError")
  };

  const hasNativeWebView = Boolean(window.chrome && window.chrome.webview);

  function post(message) {
    if (!hasNativeWebView) {
      return;
    }
    window.chrome.webview.postMessage(JSON.stringify(message));
  }

  function formatPairingCode(value) {
    const digits = String(value || "").replace(/[^0-9]/g, "").slice(0, 16);
    const groups = digits.match(/.{1,4}/g);
    return groups ? groups.join("-") : "";
  }

  function setError(message) {
    elements.inlineError.textContent = message || "";
    elements.inlineError.hidden = !message;
  }

  function applyState(payload) {
    if (!payload || typeof payload !== "object") {
      return;
    }

    if (payload.type === "error") {
      setError(payload.message || "Something went wrong.");
      elements.statusCard.dataset.state = "error";
      elements.statusIcon.textContent = "!";
      elements.statusPill.textContent = "CHECK INPUT";
      return;
    }

    if (payload.type !== "state") {
      return;
    }

    setError("");
    elements.statusCard.dataset.state = payload.state || "idle";
    elements.statusHeadline.textContent = payload.headline || "Session status";
    elements.statusDetail.textContent = payload.detail || "";
    elements.statusIcon.textContent = payload.connected ? "✓" : payload.state === "ready" ? "⌁" : "↗";
    elements.statusPill.textContent = payload.connected ? "CONNECTED" : payload.state === "ready" ? "READY" : "READY";
    elements.disconnectButton.hidden = !payload.connected;
    elements.connectButton.disabled = Boolean(payload.connected);
  }

  elements.pairingCode.addEventListener("input", function () {
    const formatted = formatPairingCode(elements.pairingCode.value);
    elements.pairingCode.value = formatted;
    setError("");
  });

  elements.connectButton.addEventListener("click", function () {
    const digits = elements.pairingCode.value.replace(/[^0-9]/g, "");
    if (digits.length !== 16) {
      setError("Enter all 16 digits before connecting.");
      elements.pairingCode.focus();
      return;
    }
    setError("");
    post({ type: "connect", pairingCode: digits });
    if (!hasNativeWebView) {
      applyState({
        type: "state",
        state: "ready",
        headline: "Preview pairing accepted",
        detail: "The native Windows transport is not attached in this browser preview.",
        connected: false
      });
    }
  });

  elements.disconnectButton.addEventListener("click", function () {
    post({ type: "disconnect" });
    if (!hasNativeWebView) {
      applyState({
        type: "state",
        state: "idle",
        headline: "Ready for a Windows transport",
        detail: "Choose Connect after entering the 16-digit pairing code.",
        connected: false
      });
    }
  });

  if (hasNativeWebView) {
    window.chrome.webview.addEventListener("message", function (event) {
      let payload;
      try {
        payload = typeof event.data === "string" ? JSON.parse(event.data) : event.data;
      } catch (error) {
        setError("Received an invalid message from the native host.");
        return;
      }
      applyState(payload);
    });
    post({ type: "ready" });
  } else {
    applyState({
      type: "state",
      state: "idle",
      headline: "Web preview — native host not attached",
      detail: "Open the copied web folder through the Windows WebView2 host to enable pairing messages.",
      connected: false
    });
  }
})();
