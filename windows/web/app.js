(function () {
  "use strict";

  const elements = {
    statusCard: document.getElementById("statusCard"),
    statusIcon: document.getElementById("statusIcon"),
    statusHeadline: document.getElementById("statusHeadline"),
    statusDetail: document.getElementById("statusDetail"),
    statusPill: document.getElementById("statusPill"),
    pairingCodeValue: document.getElementById("pairingCodeValue"),
    copyCodeButton: document.getElementById("copyCodeButton"),
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
    if (payload.pairingCode) {
      elements.pairingCodeValue.textContent = payload.pairingCode;
    }
  }

  elements.copyCodeButton.addEventListener("click", async function () {
    const code = elements.pairingCodeValue.textContent || "";
    try {
      await navigator.clipboard.writeText(code);
      elements.copyCodeButton.textContent = "Copied";
      setTimeout(() => { elements.copyCodeButton.textContent = "Copy code"; }, 1400);
    } catch (error) {
      setError("Copy is unavailable; enter the code shown here on the iPad.");
    }
  });

  elements.disconnectButton.addEventListener("click", function () {
    post({ type: "disconnect" });
    if (!hasNativeWebView) {
      applyState({
        type: "state",
        state: "idle",
        headline: "Windows host preview",
        detail: "The native host listens on TCP 45454 and shows a one-time code here.",
        pairingCode: "1234-5678-9012-3456",
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
      detail: "Open the copied web folder through the Windows WebView2 host to enable the encrypted LAN listener.",
      pairingCode: "1234-5678-9012-3456",
      connected: false
    });
  }
})();
