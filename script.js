// =====================================================================
//  script.js - browser side.
//  This file does NOT calculate any cricket score. Every click is sent
//  to backend.py, which gives it to the Verilog simulation (Icarus
//  Verilog). The numbers shown here are the numbers the Verilog engine
//  returned.
// =====================================================================

const $ = (id) => document.getElementById(id);

let lastScoreText = null;
let lastBallCount = 0;
let busy = false;
let lastInningsOver = false;     // used by the Next Innings confirm box

// ---------------------------------------------------------------
//  Talking to backend.py
// ---------------------------------------------------------------
async function api(path, body) {
  const options = body === undefined
    ? { method: "GET" }
    : { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body) };
  const response = await fetch(path, options);
  return response.json();
}

async function send(path, body) {
  if (busy) return;
  busy = true;
  try {
    const data = await api(path, body || {});
    showEngine(true);
    if (data.error) showError(data.error); else showError("");
    if (data.state) render(data);
  } catch (err) {
    showEngine(false);
    showError("Cannot reach backend.py. Start it with: python backend.py");
  } finally {
    busy = false;
  }
}

function showEngine(ok) {
  const badge = $("engineBadge");
  badge.textContent = ok ? "Scoring by Verilog (Icarus Verilog)" : "Backend offline";
  badge.className = "badge " + (ok ? "badge-on" : "badge-off");
}

function showError(message) {
  const banner = $("errorBanner");
  banner.textContent = message;
  banner.hidden = !message;
}

// ---------------------------------------------------------------
//  Drawing the page
// ---------------------------------------------------------------
function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function ordinal(n) { return n === 1 ? "1st" : "2nd"; }

function render(d) {
  const s = d.state;
  lastInningsOver = d.innings_over;

  // headline
  $("inningsTag").textContent = ordinal(d.innings_no) + " Innings";
  $("battingTeam").textContent = d.batting;
  $("vsLine").textContent = "vs " + d.bowling + " - " + d.max_overs + " over match";
  $("runRate").textContent = d.run_rate.toFixed(2);

  const scoreText = s.runs + "/" + s.wkts;
  const led = $("scoreLed");
  led.textContent = scoreText;
  if (lastScoreText !== null && lastScoreText !== scoreText) {
    led.classList.remove("bump");
    void led.offsetWidth;            // restart the animation
    led.classList.add("bump");
  }
  lastScoreText = scoreText;

  $("oversText").textContent = d.overs_text;
  $("oversMax").textContent = "of " + d.max_overs;
  $("foursNum").textContent = s.fours;
  $("sixesNum").textContent = s.sixes;
  $("extrasNum").textContent = s.extras;
  $("targetNum").textContent = d.target ? d.target : "-";

  const status = $("statusLine");
  status.textContent = d.status;
  status.className = "status" + (d.match_complete ? " final" : "");

  renderOver(d);
  renderSummaries(d);
  renderBatters(d);
  renderBowlers(d);

  $("extrasLine").textContent =
    "Extras " + s.extras + "  (wides " + s.wides + ", no balls " + s.noballs +
    ", byes " + s.byes + ", leg byes " + s.legbyes + ")";

  // enable / disable buttons
  const locked = d.innings_over || d.match_complete;
  document.querySelectorAll("[data-type]").forEach((b) => { b.disabled = locked; });
  $("undoBtn").disabled = !d.can_undo;
  $("nextBtn").disabled = !d.can_next_innings;
}

function ballClass(label) {
  if (label === "4") return "ball b-four";
  if (label === "6") return "ball b-six";
  if (label === "W") return "ball b-wkt";
  if (label === "0" || /^[123]$/.test(label)) return "ball";
  return "ball b-extra";
}

function renderOver(d) {
  $("overTitle").textContent = d.this_over_title;
  const box = $("overBalls");
  box.innerHTML = "";
  if (d.this_over.length === 0) {
    box.innerHTML = '<span class="empty-note">No deliveries yet</span>';
  }
  d.this_over.forEach((label, i) => {
    const el = document.createElement("span");
    const isNewest = i === d.this_over.length - 1 && d.this_over.length > lastBallCount;
    el.className = ballClass(label) + (isNewest ? " pop" : "");
    el.textContent = label;
    box.appendChild(el);
  });
  lastBallCount = d.this_over.length;
}

function renderSummaries(d) {
  const box = $("summaries");
  box.innerHTML = d.summaries.map((x, i) =>
    '<div class="summary-row"><span>' + ordinal(i + 1) + " innings - " +
    escapeHtml(x.team) + "</span><b>" + x.runs + "/" + x.wickets +
    " (" + x.overs + " ov)</b></div>").join("");
}

function renderBatters(d) {
  const body = $("batBody");
  if (d.batters.length === 0) {
    body.innerHTML = '<tr class="empty-row"><td colspan="7">No batters yet</td></tr>';
    return;
  }
  body.innerHTML = d.batters.map((b) => {
    const cls = b.status === "out" ? "st-out" : (b.status === "batting" ? "st-bat" : "st-no");
    const live = b.status === "batting" ? ' class="live"' : "";
    return "<tr" + live + "><td>" + escapeHtml(b.name) +
      (b.on_strike ? ' <span class="dot">*</span>' : "") + "</td>" +
      '<td class="' + cls + '">' + b.status + "</td>" +
      '<td class="num"><b>' + b.runs + "</b></td>" +
      '<td class="num">' + b.balls + "</td>" +
      '<td class="num">' + b.fours + "</td>" +
      '<td class="num">' + b.sixes + "</td>" +
      '<td class="num">' + b.sr.toFixed(1) + "</td></tr>";
  }).join("");
}

function renderBowlers(d) {
  const body = $("bowlBody");
  if (d.bowlers.length === 0) {
    body.innerHTML = '<tr class="empty-row"><td colspan="5">No bowlers yet</td></tr>';
    return;
  }
  body.innerHTML = d.bowlers.map((b) =>
    "<tr" + (b.bowling ? ' class="live"' : "") + "><td>" + escapeHtml(b.name) +
    (b.bowling ? ' <span class="dot">*</span>' : "") + "</td>" +
    '<td class="num">' + b.overs + "</td>" +
    '<td class="num">' + b.runs + "</td>" +
    '<td class="num"><b>' + b.wickets + "</b></td>" +
    '<td class="num">' + b.econ.toFixed(2) + "</td></tr>").join("");
}

// ---------------------------------------------------------------
//  Button handlers
// ---------------------------------------------------------------
document.querySelectorAll("[data-type]").forEach((button) => {
  button.addEventListener("click", () => {
    const type = button.dataset.type;
    let value = Number(button.dataset.value || 0);
    if (type === "bye" || type === "legbye") value = Number($("extraRuns").value);
    send("/api/event", { type: type, value: value });
  });
});

$("undoBtn").addEventListener("click", () => send("/api/undo"));

$("nextBtn").addEventListener("click", () => {
  const needsConfirm = !lastInningsOver;
  if (needsConfirm && !confirm("The innings is not finished yet. End it now?")) return;
  send("/api/next_innings");
});

function matchSetup() {
  return {
    team_a: $("teamA").value,
    team_b: $("teamB").value,
    overs: Number($("oversInput").value) || 5,
  };
}

$("startBtn").addEventListener("click", () => send("/api/reset", matchSetup()));

$("resetBtn").addEventListener("click", () => {
  if (confirm("Reset the whole match?")) send("/api/reset", matchSetup());
});

// ---------------------------------------------------------------
//  First load: ask the backend for the current match
// ---------------------------------------------------------------
(async function init() {
  try {
    const data = await api("/api/state");
    showEngine(true);
    $("teamA").value = data.teams[0];
    $("teamB").value = data.teams[1];
    $("oversInput").value = data.max_overs;
    render(data);
  } catch (err) {
    showEngine(false);
    showError("Cannot reach backend.py. Start it with: python backend.py");
  }
})();
