(() => {
  const loginPanel = document.getElementById("login-panel");
  const dashPanel = document.getElementById("dash-panel");
  const logoutBtn = document.getElementById("logout-btn");
  const loginError = document.getElementById("login-error");
  const pendingList = document.getElementById("pending-list");
  const pendingEmpty = document.getElementById("pending-empty");
  const hoursLine = document.getElementById("hours-line");
  const sessionLine = document.getElementById("session-line");
  const eventsList = document.getElementById("events-list");
  const manualDurations = document.getElementById("manual-durations");

  let authenticated = window.__PARENT_AUTH__ === true;

  function showAuth(isAuthed) {
    authenticated = isAuthed;
    loginPanel.classList.toggle("hidden", isAuthed);
    dashPanel.classList.toggle("hidden", !isAuthed);
    logoutBtn.classList.toggle("hidden", !isAuthed);
  }

  async function api(path, options = {}) {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json", ...(options.headers || {}) },
      ...options,
    });
    const data = await res.json().catch(() => ({}));
    if (res.status === 401) {
      showAuth(false);
      throw new Error("PIN required");
    }
    if (!res.ok) {
      throw new Error(data.detail || "Request failed");
    }
    return data;
  }

  function formatRemaining(seconds) {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}:${String(s).padStart(2, "0")}`;
  }

  function renderDashboard(data) {
    hoursLine.textContent = data.hours.open
      ? `Computer open · ${data.hours.message}`
      : `Computer closed · ${data.hours.message}`;

    if (data.session.active) {
      sessionLine.textContent = `Internet on · ${formatRemaining(
        data.session.remaining_seconds
      )} remaining`;
    } else {
      sessionLine.textContent = "Internet is off";
    }

    pendingList.innerHTML = "";
    const pending = data.pending_requests || [];
    pendingEmpty.classList.toggle("hidden", pending.length > 0);
    for (const req of pending) {
      const item = document.createElement("div");
      item.className = "request-item";
      item.innerHTML = `
        <div>
          <strong>${req.minutes} minutes</strong>
          <div class="muted">${req.note || "No note"} · ${req.created_at}</div>
        </div>
        <div class="request-actions">
          <button type="button" class="approve-btn" data-id="${req.id}">Approve</button>
          <button type="button" class="deny-btn" data-id="${req.id}">Deny</button>
        </div>`;
      pendingList.appendChild(item);
    }

    pendingList.querySelectorAll(".approve-btn").forEach((btn) => {
      btn.addEventListener("click", async () => {
        await api(`/api/parent/requests/${btn.dataset.id}/approve`, { method: "POST" });
        await refresh();
      });
    });
    pendingList.querySelectorAll(".deny-btn").forEach((btn) => {
      btn.addEventListener("click", async () => {
        await api(`/api/parent/requests/${btn.dataset.id}/deny`, { method: "POST" });
        await refresh();
      });
    });

    manualDurations.innerHTML = "";
    for (const mins of data.session_durations || [15, 30, 60]) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "duration-btn";
      b.textContent = `Grant ${mins}m`;
      b.addEventListener("click", async () => {
        await api("/api/parent/session/start", {
          method: "POST",
          body: JSON.stringify({ minutes: mins }),
        });
        await refresh();
      });
      manualDurations.appendChild(b);
    }

    eventsList.innerHTML = "";
    for (const ev of data.recent_events || []) {
      const li = document.createElement("li");
      li.textContent = `${ev.created_at} · ${ev.kind}${ev.detail ? " — " + ev.detail : ""}`;
      eventsList.appendChild(li);
    }
  }

  async function refresh() {
    if (!authenticated) return;
    try {
      const data = await api("/api/parent/dashboard");
      renderDashboard(data);
    } catch (err) {
      // stay on login if unauthorized
    }
  }

  document.getElementById("login-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    loginError.classList.add("hidden");
    try {
      await api("/api/parent/login", {
        method: "POST",
        body: JSON.stringify({ pin: document.getElementById("login-pin").value }),
      });
      showAuth(true);
      await refresh();
    } catch (err) {
      loginError.textContent = err.message || "Wrong PIN";
      loginError.classList.remove("hidden");
    }
  });

  logoutBtn.addEventListener("click", async () => {
    await api("/api/parent/logout", { method: "POST" });
    showAuth(false);
  });

  document.getElementById("end-session-btn").addEventListener("click", async () => {
    await api("/api/parent/session/end", { method: "POST" });
    await refresh();
  });

  const exitKioskBtn = document.getElementById("exit-kiosk-btn");
  if (exitKioskBtn) {
    exitKioskBtn.addEventListener("click", async () => {
      if (!window.confirm("Exit the kiosk and return to the login screen?")) return;
      try {
        await api("/api/parent/exit-kiosk", { method: "POST" });
        exitKioskBtn.textContent = "Signing out…";
        exitKioskBtn.disabled = true;
      } catch (err) {
        alert(err.message || "Could not exit kiosk");
      }
    });
  }

  showAuth(authenticated);
  refresh();
  setInterval(refresh, 4000);
})();
