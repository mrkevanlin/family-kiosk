(() => {
  const clockEl = document.getElementById("clock");
  const sessionChip = document.getElementById("session-chip");
  const closedPanel = document.getElementById("closed-panel");
  const pickerPanel = document.getElementById("picker-panel");
  const closedMessage = document.getElementById("closed-message");
  const hoursMessage = document.getElementById("hours-message");
  const tilesEl = document.getElementById("tiles");
  const pendingNote = document.getElementById("pending-note");
  const requestDialog = document.getElementById("request-dialog");
  const pinDialog = document.getElementById("pin-dialog");
  const durationChoices = document.getElementById("duration-choices");
  const requestError = document.getElementById("request-error");
  const pinError = document.getElementById("pin-error");

  let selectedMinutes = null;
  let lastStatus = null;

  function formatClock(now = new Date()) {
    return now.toLocaleString(undefined, {
      weekday: "short",
      hour: "numeric",
      minute: "2-digit",
    });
  }

  function formatRemaining(seconds) {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}:${String(s).padStart(2, "0")} left`;
  }

  async function fetchStatus() {
    const res = await fetch("/api/status");
    if (!res.ok) throw new Error("status failed");
    return res.json();
  }

  function renderTiles(status) {
    tilesEl.innerHTML = "";
    for (const activity of status.activities || []) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `tile tile-${activity.id}`;
      btn.disabled = !activity.enabled;
      btn.innerHTML = `<span class="tile-title">${activity.title}</span><span class="tile-sub">${activity.subtitle}</span>`;
      btn.addEventListener("click", () => handleAction(activity, status));
      tilesEl.appendChild(btn);
    }
  }

  function handleAction(activity, status) {
    if (activity.action === "request_internet") {
      openRequestSheet(status.session_durations || [15, 30, 60]);
      return;
    }
    const map = {
      launch_homework: "homework",
      launch_mblock: "mblock",
      launch_apple_music: "apple_music",
      launch_typesy: "typesy",
      launch_web: "web",
    };
    const name = map[activity.action];
    if (!name) return;

    fetch(`/api/launch/${name}`, { method: "POST" })
      .then(async (res) => {
        const data = await res.json().catch(() => ({}));
        if (!res.ok) {
          console.warn(data.detail || "launch failed");
          return;
        }
        // Browser preview fallback when no kiosk wrapper is watching launch flags.
        if (name === "mblock") {
          window.open(data.mblock_url || status.mblock_url || "https://ide.mblock.cc", "_blank");
        } else if (name === "apple_music") {
          window.open(
            data.apple_music_url || status.apple_music_url || "https://music.apple.com/us/browse",
            "_blank"
          );
        } else if (name === "typesy") {
          window.open(
            data.typesy_url || status.typesy_url || "https://www.typesy.com/type/",
            "_blank"
          );
        } else if (name === "homework") {
          const start =
            data.homework_start_url ||
            status.homework_start_url ||
            "https://www.google.com/?safe=active&ssui=on";
          window.open(start, "_blank");
        } else if (name === "web") {
          window.open("https://www.wikipedia.org", "_blank");
        }
      })
      .catch((err) => console.warn(err));
  }

  function openRequestSheet(durations) {
    selectedMinutes = durations[0] || 30;
    durationChoices.innerHTML = "";
    requestError.classList.add("hidden");
    for (const mins of durations) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "duration-btn" + (mins === selectedMinutes ? " selected" : "");
      b.textContent = `${mins} min`;
      b.addEventListener("click", () => {
        selectedMinutes = mins;
        [...durationChoices.children].forEach((c) => c.classList.remove("selected"));
        b.classList.add("selected");
      });
      durationChoices.appendChild(b);
    }
    requestDialog.showModal();
  }

  async function render() {
    clockEl.textContent = formatClock();
    try {
      lastStatus = await fetchStatus();
    } catch (err) {
      hoursMessage.textContent = "Waiting for familyd…";
      return;
    }

    const { computer_open, hours, session, pending_request } = lastStatus;

    if (session.active) {
      sessionChip.textContent = `Internet · ${formatRemaining(session.remaining_seconds)}`;
      sessionChip.classList.remove("hidden");
    } else {
      sessionChip.classList.add("hidden");
    }

    if (!computer_open) {
      closedPanel.classList.remove("hidden");
      pickerPanel.classList.add("hidden");
      closedMessage.textContent = hours.message;
      return;
    }

    closedPanel.classList.add("hidden");
    pickerPanel.classList.remove("hidden");
    hoursMessage.textContent = hours.message;
    renderTiles(lastStatus);

    if (pending_request) {
      pendingNote.textContent = `Request for ${pending_request.minutes} minutes is waiting for a parent.`;
      pendingNote.classList.remove("hidden");
    } else {
      pendingNote.classList.add("hidden");
    }
  }

  document.getElementById("request-form").addEventListener("submit", async (e) => {
    const submitter = e.submitter;
    if (!submitter || submitter.value !== "send") return;
    e.preventDefault();
    requestError.classList.add("hidden");
    try {
      const res = await fetch("/api/requests", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          minutes: selectedMinutes,
          note: document.getElementById("request-note").value || null,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        requestError.textContent = data.detail || "Could not send request";
        requestError.classList.remove("hidden");
        return;
      }
      requestDialog.close();
      await render();
    } catch (err) {
      requestError.textContent = "Network error";
      requestError.classList.remove("hidden");
    }
  });

  document.getElementById("parent-btn").addEventListener("click", () => {
    pinError.classList.add("hidden");
    document.getElementById("parent-pin").value = "";
    pinDialog.showModal();
  });

  document.getElementById("pin-form").addEventListener("submit", async (e) => {
    const submitter = e.submitter;
    if (!submitter || submitter.value !== "unlock") return;
    e.preventDefault();
    const pin = document.getElementById("parent-pin").value;
    try {
      const res = await fetch("/api/parent/exit-kiosk", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pin }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        pinError.textContent = data.detail || "Wrong PIN";
        pinError.classList.remove("hidden");
        return;
      }
      pinDialog.close();
      pinError.classList.add("hidden");
      // Browser preview: go to parent dashboard. On device, kiosk wrapper logs out.
      window.location.href = "/parent";
    } catch (err) {
      pinError.textContent = "Network error";
      pinError.classList.remove("hidden");
    }
  });

  setInterval(render, 5000);
  setInterval(() => {
    clockEl.textContent = formatClock();
    if (lastStatus?.session?.active) {
      lastStatus.session.remaining_seconds = Math.max(
        0,
        (lastStatus.session.remaining_seconds || 0) - 1
      );
      sessionChip.textContent = `Internet · ${formatRemaining(
        lastStatus.session.remaining_seconds
      )}`;
    }
  }, 1000);

  render();
})();
