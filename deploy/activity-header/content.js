(() => {
  if (window.top !== window || location.hostname === "127.0.0.1") return;

  const installHeader = () => {
    if (!document.documentElement || document.getElementById("family-kiosk-header")) {
      return;
    }

    const host = document.createElement("div");
    host.id = "family-kiosk-header";
    host.style.cssText = [
      "position:fixed",
      "top:0",
      "left:0",
      "right:0",
      "height:48px",
      "z-index:2147483647",
      "display:flex",
      "align-items:center",
      "justify-content:space-between",
      "padding:0 14px",
      "box-sizing:border-box",
      "background:#10282c",
      "color:#fffaf3",
      "font:600 15px system-ui,sans-serif",
      "box-shadow:0 2px 10px rgba(0,0,0,.35)",
    ].join(";");

    const label = document.createElement("span");
    label.textContent = "Family Computer";

    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Back to picker";
    button.setAttribute("aria-label", "Close this activity and return to picker");
    button.style.cssText = [
      "border:1px solid rgba(255,255,255,.45)",
      "border-radius:999px",
      "padding:7px 14px",
      "background:rgba(255,255,255,.12)",
      "color:#fff",
      "font:700 14px system-ui,sans-serif",
      "cursor:pointer",
    ].join(";");

    button.addEventListener("click", () => {
      button.disabled = true;
      button.textContent = "Returning…";
      chrome.runtime.sendMessage({ action: "returnToPicker" }, (response) => {
        if (chrome.runtime.lastError || !response?.closed) {
          // Fallback if Chromium refuses to close the app window.
          location.href = "http://127.0.0.1:8787/";
        }
      });
    });

    host.append(label, button);
    document.documentElement.appendChild(host);

    // Reserve room so the site's own header is not hidden underneath ours.
    document.documentElement.style.setProperty(
      "padding-top",
      "48px",
      "important"
    );
    document.documentElement.style.setProperty(
      "box-sizing",
      "border-box",
      "important"
    );
  };

  installHeader();
  document.addEventListener("DOMContentLoaded", installHeader, { once: true });
})();
