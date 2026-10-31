"use strict";

// The pairing link carries the token in its fragment, which never reaches a server. Keep it here
// and take it out of the address bar. Every URL below is relative: Funnel serves this page under
// /barestate/ and the gateway sees the paths without that prefix.
const KEY = "photon.token";
function takeToken() {
  if (!/^#t=/.test(location.hash)) return false;
  localStorage.setItem(KEY, decodeURIComponent(location.hash.slice(3)));
  history.replaceState(null, "", location.pathname + location.search);
  return true;
}
takeToken();

// The words the Mac shows after "Muse ·".
const LABEL = {
  pending: "connecting", running: "working", "waiting-approval": "waiting for approval",
  stopped: "stopped", completed: "completed", failed: "failed",
};
const LINK = {
  connecting: "Connecting…", on: "Connected", off: "Disconnected", lost: "Connection lost",
  unpaired: "Not paired",
};
const OFFLINE = {
  off: "This phone is disconnected. Reconnect to start or follow a task.",
  lost: "The connection to Photon dropped.",
  unpaired: "This phone is not paired. Scan the pairing code in Photon's Settings on your Mac.",
};

const $ = (id) => document.getElementById(id);
const runs = new Map();
let mine = null;
let approvals = [];
let link = "connecting";
let stream = null;
let frame = null;

const token = () => localStorage.getItem(KEY);
const live = () => link === "on";
const current = () =>
  runs.get(mine) ?? [...runs.values()].reverse().find((run) => run.origin === "phone");
const busy = (run) => run && ["pending", "running", "waiting-approval"].includes(run.state);

function setLink(next) {
  link = next;
  $("link-text").textContent = LINK[next];
  $("link-dot").parentElement.toggleAttribute("data-on", next === "on");
  render();
}

// Forgetting the stream first tells connect() the end was ours, not a lost connection.
function drop() {
  const old = stream;
  stream = null;
  old?.abort();
}

async function connect() {
  drop();
  const mineNow = (stream = new AbortController());
  if (!token()) return setLink("unpaired");
  setLink("connecting");
  try {
    const response = await fetch("api/events", {
      headers: { Authorization: "Bearer " + token() }, cache: "no-store", signal: mineNow.signal,
    });
    if (response.status === 401) {
      localStorage.removeItem(KEY);
      return setLink("unpaired");
    }
    if (!response.ok) return setLink("lost");
    await read(response.body.getReader());
    if (stream === mineNow && link !== "off") setLink("lost");
  } catch (error) {
    if (stream === mineNow) setLink("lost");
  }
}

async function read(reader) {
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return;
    buffer += decoder.decode(value, { stream: true });
    for (let end; (end = buffer.indexOf("\n\n")) >= 0; ) {
      dispatch(buffer.slice(0, end));
      buffer = buffer.slice(end + 2);
    }
  }
}

function dispatch(block) {
  let name = "message";
  let data = "";
  for (const line of block.split("\n")) {
    if (line.startsWith(": connected")) setLink("on");
    else if (line.startsWith("event:")) name = line.slice(6).trim();
    else if (line.startsWith("data:")) data += line.slice(5).trim();
  }
  if (name === "disconnected") return setLink("off");
  if (!data) return;
  const body = JSON.parse(data);
  if (name === "screencast.frame") return show(body);
  if (name === "run.update") runs.set(body.runId, body);
  else if (name === "approval.update") approvals = body.approvals;
  else return;
  render();
}

// Only the newest frame is drawn: the stream may deliver several between two paints.
function show(next) {
  const run = current();
  if (run?.tabId && next.tabId !== run.tabId) return;
  const first = frame === null;
  frame = next;
  if (first) requestAnimationFrame(draw);
}

function draw() {
  const image = $("screen");
  if (!image || !frame) return (frame = null);
  image.src = "data:image/jpeg;base64," + frame.data;
  if (frame.width && frame.height) image.style.aspectRatio = frame.width + " / " + frame.height;
  image.hidden = $("shot").hidden = false;
  $("shot-wait").hidden = true;
  frame = null;
}

async function api(name, body = {}) {
  let response;
  try {
    response = await fetch("api/" + name, {
      method: "POST", body: JSON.stringify(body),
      headers: { Authorization: "Bearer " + token(), "Content-Type": "application/json" },
    });
  } catch (error) {
    return { ok: false, error: "network" };
  }
  const reply = await response.json().catch(() => ({}));
  if (response.status === 409) {
    drop();
    setLink("off");
  }
  return { ok: response.ok, ...reply };
}

function leave(card) {
  card.classList.add("leaving");
  card.addEventListener("transitionend", () => card.remove(), { once: true });
  setTimeout(() => card.remove(), 400);
}

function renderApprovals() {
  const list = $("approvals");
  const ids = new Set(approvals.map((item) => item.approvalId));
  for (const card of list.children) {
    if (!ids.has(card.dataset.id) && !card.classList.contains("leaving")) leave(card);
  }
  for (const item of approvals) {
    if (list.querySelector(`[data-id="${CSS.escape(item.approvalId)}"]`)) continue;
    const card = document.createElement("section");
    card.className = "card";
    card.dataset.id = item.approvalId;
    card.setAttribute("aria-label", "Approval needed");
    const text = document.createElement("p");
    text.className = "approval-text";
    text.textContent = item.text;
    const row = document.createElement("div");
    row.className = "row";
    for (const [label, allow] of [["Allow once", true], ["Deny", false]]) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = label;
      button.className = allow ? "primary" : "";
      button.onclick = async () => {
        row.querySelectorAll("button").forEach((each) => (each.disabled = true));
        const reply = await api("approve", { approvalId: item.approvalId, allow });
        if (!reply.ok) row.querySelectorAll("button").forEach((each) => (each.disabled = false));
      };
      row.append(button);
    }
    card.append(text, row);
    list.append(card);
  }
}

function set(id, text) {
  const element = $(id);
  if (element.textContent !== text) element.textContent = text;
}

function renderRun() {
  const run = current();
  if (!run) return;
  if (!$("run-state")) {
    const card = $("run-card").content.firstElementChild.cloneNode(true);
    $("run-slot").append(card);
    $("stop").onclick = () => act("stop");
    $("takeover").onclick = () => act("takeover");
  }
  const text = "Muse · " + LABEL[run.state];
  if ($("run-state").textContent !== text) {
    $("run-state").textContent = text;
    $("run-state").animate({ opacity: [0, 1] }, { duration: 140, easing: "cubic-bezier(0.23, 1, 0.32, 1)" });
  }
  $("run-dot").classList.toggle("work", run.state === "running");
  set("run-prompt", run.prompt);
  set("run-id", run.runId);
  const reason = run.reason && run.reason !== run.state && !busy(run) ? "Ended: " + run.reason : "";
  set("run-reason", reason);
  $("run-reason").hidden = !reason;
  $("stop").disabled = $("takeover").disabled = !live() || !busy(run);
  const card = $("run-slot").firstElementChild;
  if (card.dataset.run !== run.runId) {
    card.dataset.run = run.runId;
    $("screen").removeAttribute("src");
    $("screen").hidden = true;
  }
  $("shot-wait").hidden = !$("screen").hidden || !busy(run);
  $("shot").hidden = $("screen").hidden && $("shot-wait").hidden;
}

async function act(name) {
  const run = current();
  if (run) await api(name, { runId: run.runId });
}

function render() {
  const off = !live() && link !== "connecting";
  $("offline").hidden = !off;
  set("offline-text", OFFLINE[link] ?? "");
  $("reconnect").hidden = link === "unpaired";
  $("start").disabled = !live() || sending;
  $("disconnect").hidden = !live();
  renderApprovals();
  renderRun();
}

let sending = false;
$("task").onsubmit = async (event) => {
  event.preventDefault();
  const prompt = $("prompt").value.trim();
  if (!prompt || !live() || sending) return;
  sending = true;
  render();
  set("task-note", "");
  const reply = await api("task", { prompt });
  sending = false;
  if (reply.runId) {
    // The stream may have reported this run already; its state is newer than the reply's.
    if (!runs.has(reply.runId)) runs.set(reply.runId, reply);
    mine = reply.runId;
    $("prompt").value = "";
  } else if (live()) {
    set("task-note", "Muse could not start that task.");
  }
  render();
};

$("reconnect").onclick = connect;
// A pairing link opened in a page that is already open only changes the hash.
addEventListener("hashchange", () => takeToken() && connect());
$("disconnect").onclick = async () => {
  await api("disconnect");
  drop();
  setLink("off");
};

connect();
