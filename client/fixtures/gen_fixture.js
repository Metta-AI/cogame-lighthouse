// Generates client/fixtures/sample_replay.json: a hand-consistent
// Lighthouse replay payload (lighthouse.replay.v1) built strictly from the
// viewer contract in docs/plans/2026-08-22-lighthouse-design.md. The board is
// the one seed 11 carves; the events come from a small JS port of the sim's
// twelve-step resolution order, and every states[i] is the boardStateJson
// after events[0..<i], so the dev shell can be eyeballed without a live
// episode.
//
//   node client/fixtures/gen_fixture.js
"use strict";
var fs = require("fs");
var path = require("path");

var GRID = [
  "#########.#",
  "#.........#",
  "#.###.###.#",
  "#.#.#.#...#",
  "#.#.#.#.###",
  "#...#.#...#",
  "#####.###.#",
  "#.....#...#",
  "###########"
];
var WIDTH = GRID[0].length, HEIGHT = GRID.length;
var EXIT = [9, 0];
var STARTS = [[1, 7], [5, 7], [9, 7]];
var KEYS = [[3, 3], [1, 3], [5, 5]];
var NAMES = ["Fresnel", "Tinker", "Gasket", "Piston"];
var POLICY_NAMES = ["lighthouse-beacon", "lighthouse-pilot", "Baseline (1)",
  "Baseline (2)"];
var SCRIPTED = [false, false, true, true];
// The shipped `standard` settings, on the board seed 11 carves.
var CONFIG = {
  seed: 11, maxTicks: 45, width: WIDTH, height: HEIGHT,
  tideDelay: 10, tidePeriod: 7, keyCount: KEYS.length, messageCap: 160,
  sampled: true, grid: GRID, exit: EXIT, starts: STARTS, keys: KEYS
};
var FLOOD_CLOCK = CONFIG.tideDelay + HEIGHT * CONFIG.tidePeriod;
var NEIGHBOURS = [[0, -1], [1, 0], [0, 1], [-1, 0]];   // N, E, S, W
var MOVE_OF = { "0,-1": "N", "1,0": "E", "0,1": "S", "-1,0": "W" };
var DELTA = { N: [0, -1], S: [0, 1], E: [1, 0], W: [-1, 0], WAIT: [0, 0] };

// Keeper notes, one per transmission, so the feed shows a plan forming.
var KEEPER_NOTES = [
  "Tinker -> key (3,3), Gasket -> key (1,3), Piston -> key (5,5).",
  "",
  "Tinker obeying. Water at row 8; nobody within two yet.",
  "",
  "Piston is slowest; it has the longest corridor.",
  "",
  "All keys in. Everyone at the exit now — say it once, loudly.",
  ""
];
var RUNNER_NOTES = {
  1: ["Order N. Corridor ahead, holding it.", "",
    "Bumped once; took the nearest open turn.", "", "Key in hand."],
  2: ["Following the keeper letter for letter.", "", "",
    "Corridor is long; keeping the last letter."],
  3: []
};

function isWall(x, y) {
  if (x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT) return true;
  return GRID[y][x] === "#";
}
function tideRows(clock) {
  var r = Math.floor((clock - CONFIG.tideDelay) / CONFIG.tidePeriod);
  return Math.max(0, Math.min(HEIGHT, r));
}
function waterLine(clock) { return HEIGHT - tideRows(clock); }
function flooded(y, clock) { return y >= waterLine(clock); }

function bfs(from, clock) {
  var dist = new Array(WIDTH * HEIGHT).fill(-1);
  if (isWall(from[0], from[1]) || flooded(from[1], clock)) return dist;
  dist[from[1] * WIDTH + from[0]] = 0;
  var queue = [from];
  for (var head = 0; head < queue.length; head++) {
    var cell = queue[head];
    var base = dist[cell[1] * WIDTH + cell[0]];
    NEIGHBOURS.forEach(function (step) {
      var nx = cell[0] + step[0], ny = cell[1] + step[1];
      if (isWall(nx, ny) || flooded(ny, clock)) return;
      if (dist[ny * WIDTH + nx] >= 0) return;
      dist[ny * WIDTH + nx] = base + 1;
      queue.push([nx, ny]);
    });
  }
  return dist;
}

function firstStep(dist, from) {
  var here = dist[from[1] * WIDTH + from[0]];
  if (here <= 0) return "WAIT";
  for (var i = 0; i < NEIGHBOURS.length; i++) {
    var step = NEIGHBOURS[i];
    var nx = from[0] + step[0], ny = from[1] + step[1];
    if (isWall(nx, ny)) continue;
    if (dist[ny * WIDTH + nx] === here - 1) return MOVE_OF[step.join(",")];
  }
  return "WAIT";
}

// ---- The sim -------------------------------------------------------------
var state = {
  pos: STARTS.map(function (p) { return p.slice(); }),
  status: ["active", "active", "active"],
  keysHeld: [0, 0, 0],
  lastMove: ["WAIT", "WAIT", "WAIT"],
  blocked: [false, false, false],
  keysOnFloor: KEYS.map(function (k) { return k.slice(); }),
  keysCollected: 0, gateOpen: false, escaped: 0, drowned: 0,
  tick: 0, clock: 0, messages: [], notes: ["", "", "", ""],
  scripted: SCRIPTED.slice(), done: false, reason: "",
  inbox: "", standing: "", standingTick: -9, heading: ["N", "N", "N"]
};

function glyphAt(x, y) {
  if (x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT) return "#";
  for (var i = 0; i < 3; i++) {
    if (state.status[i] === "active" && state.pos[i][0] === x &&
        state.pos[i][1] === y) {
      return String(i + 1);
    }
  }
  if (x === EXIT[0] && y === EXIT[1]) return state.gateOpen ? "O" : "E";
  if (state.keysOnFloor.some(function (k) { return k[0] === x && k[1] === y; })) {
    return "K";
  }
  if (isWall(x, y)) return "#";
  if (flooded(y, state.clock)) return "~";
  return ".";
}

function windowOf(runner) {
  var here = state.pos[runner];
  var lines = [];
  for (var dy = -1; dy <= 1; dy++) {
    var line = "";
    for (var dx = -1; dx <= 1; dx++) {
      line += (dx === 0 && dy === 0) ? "@" : glyphAt(here[0] + dx, here[1] + dy);
    }
    lines.push(line);
  }
  return lines;
}

function teamScore() {
  var k = state.keysCollected / CONFIG.keyCount;
  var b = state.escaped === 3 ?
    Math.max(0, Math.min(1, 1 - state.clock / FLOOD_CLOCK)) : 0;
  return 6 * Math.min(1, k) + 10 * state.escaped + 6 * b;
}

function pending(seat) {
  if (state.done) return false;
  return seat === 0 || state.status[seat - 1] === "active";
}

function boardState() {
  var seats = [{
    name: NAMES[0], role: "keeper", status: "keeper", pos: null, keys: 0,
    notes: state.notes[0], messages: state.messages.length,
    scripted: state.scripted[0], pending: pending(0)
  }];
  for (var i = 0; i < 3; i++) {
    var live = state.status[i] === "active";
    seats.push({
      name: NAMES[i + 1], role: "runner", status: state.status[i],
      pos: live ? state.pos[i].slice() : null, keys: state.keysHeld[i],
      lastMove: state.lastMove[i], blocked: state.blocked[i],
      window: live ? windowOf(i) : [], notes: state.notes[i + 1],
      scripted: state.scripted[i + 1], pending: pending(i + 1)
    });
  }
  var last = state.messages[state.messages.length - 1];
  return {
    seats: seats, grid: GRID, exit: EXIT, gateOpen: state.gateOpen,
    keysOnFloor: state.keysOnFloor.map(function (k) { return k.slice(); }),
    keysCollected: state.keysCollected, keyCount: CONFIG.keyCount,
    tick: state.tick, maxTicks: CONFIG.maxTicks, clock: state.clock,
    tideRows: tideRows(state.clock), waterLine: waterLine(state.clock),
    message: last ? last[1] : "", messageCost: 1,
    messageAge: last ? Math.max(0, state.tick - 1 - last[0]) : 0,
    escaped: state.escaped, drowned: state.drowned, score: teamScore(),
    phase: state.done ? "done" : "running", gameDone: state.done,
    reason: state.reason
  };
}


var CLOCKWISE = { N: "E", E: "S", S: "W", W: "N" };
var ANTICLOCKWISE = { N: "W", W: "S", S: "E", E: "N" };
var BACK = { N: "S", S: "N", E: "W", W: "E" };

function ordered(message, alias) {
  if (!message) return null;
  var found = new RegExp("\\b" + alias + "[\\s:]+([NSEW]|hold)\\b", "i")
    .exec(message);
  if (!found) return null;
  return found[1].toLowerCase() === "hold" ? "WAIT" : found[1].toUpperCase();
}

function open(runner, move) {
  if (move === "WAIT") return true;
  var d = DELTA[move];
  var x = state.pos[runner][0] + d[0], y = state.pos[runner][1] + d[1];
  return !isWall(x, y) && !flooded(y, state.clock);
}

function obey(runner) {
  var alias = NAMES[runner + 1];
  var want = ordered(state.inbox || "", alias);
  if (want === null && state.standing &&
      state.tick - state.standingTick <= 3) {
    want = ordered(state.standing, alias);
  }
  if (want !== null) {
    if (want === "WAIT") return "WAIT";
    if (open(runner, want)) return want;
    var turns = [CLOCKWISE[want], ANTICLOCKWISE[want], BACK[want]];
    for (var i = 0; i < turns.length; i++) {
      if (open(runner, turns[i])) return turns[i];
    }
    return "WAIT";
  }
  var heading = state.heading[runner];
  var order = [ANTICLOCKWISE[heading], heading, CLOCKWISE[heading],
    BACK[heading]];
  for (var k = 0; k < order.length; k++) {
    if (open(runner, order[k])) {
      state.heading[runner] = order[k];
      return order[k];
    }
  }
  return "WAIT";
}

var events = [];
var states = [];
function emit(event) { events.push(event); states.push(boardState()); }

states.push(boardState());
emit({ kind: "start" });

// The keeper: nearest uncollected key per runner, then the exit; aimed one
// step ahead because a transmission lands a tick late.
function keeperSteps() {
  var exitField = bfs(EXIT, state.clock);
  var keyFields = state.keysOnFloor.map(function (k) {
    return bfs(k, state.clock);
  });
  var target = [-1, -1, -1];
  if (state.keysCollected < CONFIG.keyCount && keyFields.length) {
    var pairs = [];
    for (var r = 0; r < 3; r++) {
      if (state.status[r] !== "active") continue;
      keyFields.forEach(function (field, k) {
        var d = field[state.pos[r][1] * WIDTH + state.pos[r][0]];
        if (d >= 0) pairs.push([d, r, k]);
      });
    }
    pairs.sort(function (a, b) {
      return a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
    });
    var tookRunner = {}, tookKey = {};
    pairs.forEach(function (p) {
      if (tookRunner[p[1]] || tookKey[p[2]]) return;
      tookRunner[p[1]] = true;
      tookKey[p[2]] = true;
      target[p[1]] = p[2];
    });
  }
  var steps = ["WAIT", "WAIT", "WAIT"];
  for (var i = 0; i < 3; i++) {
    if (state.status[i] !== "active") continue;
    var field = target[i] < 0 ? exitField : keyFields[target[i]];
    var now = firstStep(field, state.pos[i]);
    if (now === "WAIT") continue;
    var ahead = [state.pos[i][0] + DELTA[now][0],
      state.pos[i][1] + DELTA[now][1]];
    steps[i] = firstStep(field, ahead);
  }
  return steps;
}

var talked = 0;
while (!state.done) {
  var tick = state.tick;
  var steps = keeperSteps();
  var parts = [];
  for (var i = 0; i < 3; i++) {
    if (state.status[i] !== "active") continue;
    parts.push(NAMES[i + 1] + " " + (steps[i] === "WAIT" ? "hold" : steps[i]));
  }
  var message = parts.join("; ");
  var spoke = message.length > 0 && tick % 2 === 0;

  // The runners obey the order that landed at the start of this tick, or
  // the standing order while it is at most three ticks old, and turn to the
  // nearest open direction when the ordered one is blocked — the wallhug
  // baseline, blind, with only its 3x3 window to go on.
  var moves = ["WAIT", "WAIT", "WAIT"];
  for (var m = 0; m < 3; m++) {
    if (state.status[m] !== "active") continue;
    moves[m] = obey(m);
  }

  // Notes, echoed into the tick record only when they change.
  var notes = ["", "", "", ""];
  if (spoke && KEEPER_NOTES[talked]) notes[0] = KEEPER_NOTES[talked];
  [1, 2, 3].forEach(function (seat) {
    var pool = RUNNER_NOTES[seat] || [];
    var note = pool[Math.floor(tick / 3)];
    if (note) notes[seat] = note;
  });
  notes.forEach(function (note, seat) {
    if (note) state.notes[seat] = note;
  });

  // 3. Transmit.
  if (spoke) {
    talked += 1;
    state.messages.push([tick, message]);
    emit({ kind: "say", tick: tick, seat: 0, cost: 1, text: message });
  }

  // 4. Moves.
  var wasActive = state.status.map(function (s) { return s === "active"; });
  for (var r2 = 0; r2 < 3; r2++) {
    state.blocked[r2] = false;
    if (!wasActive[r2]) { state.lastMove[r2] = "WAIT"; continue; }
    state.lastMove[r2] = moves[r2];
    if (moves[r2] !== "WAIT") state.heading[r2] = moves[r2];
    var d = DELTA[moves[r2]];
    var tx = state.pos[r2][0] + d[0], ty = state.pos[r2][1] + d[1];
    if (isWall(tx, ty) || flooded(ty, state.clock)) {
      state.blocked[r2] = true;
    } else {
      state.pos[r2] = [tx, ty];
    }
  }

  // 5. Keys.
  for (var r3 = 0; r3 < 3; r3++) {
    if (!wasActive[r3]) continue;
    var at = state.keysOnFloor.findIndex(function (k) {
      return k[0] === state.pos[r3][0] && k[1] === state.pos[r3][1];
    });
    if (at >= 0) {
      state.keysOnFloor.splice(at, 1);
      state.keysCollected += 1;
      state.keysHeld[r3] += 1;
      emit({ kind: "key", tick: tick, seat: r3 + 1, x: state.pos[r3][0],
        y: state.pos[r3][1], keysCollected: state.keysCollected });
    }
  }

  // 6. Gate.
  if (state.keysCollected >= CONFIG.keyCount) state.gateOpen = true;

  // 7. Exit.
  for (var r4 = 0; r4 < 3; r4++) {
    if (!wasActive[r4] || state.status[r4] !== "active") continue;
    if (state.gateOpen && state.pos[r4][0] === EXIT[0] &&
        state.pos[r4][1] === EXIT[1]) {
      state.status[r4] = "escaped";
      state.escaped += 1;
      emit({ kind: "escape", tick: tick, seat: r4 + 1,
        escaped: state.escaped });
      state.pos[r4] = [-1, -1];
    }
  }

  // 8/9. Clock and tide.
  state.clock += 1 + (spoke ? 1 : 0);

  // 10. Drown.
  for (var r5 = 0; r5 < 3; r5++) {
    if (state.status[r5] !== "active") continue;
    if (flooded(state.pos[r5][1], state.clock)) {
      state.status[r5] = "drowned";
      state.drowned += 1;
      emit({ kind: "drown", tick: tick, seat: r5 + 1, x: state.pos[r5][0],
        y: state.pos[r5][1], drowned: state.drowned });
      state.pos[r5] = [-1, -1];
    }
  }

  // 11. Tick record.
  var record = {
    kind: "tick", tick: tick, clock: state.clock,
    tideRows: tideRows(state.clock),
    positions: state.pos.map(function (p) { return p.slice(); }),
    alive: state.status.map(function (s) { return s === "active"; }),
    moves: moves.map(function (mv, i) { return wasActive[i] ? mv : ""; }),
    blocked: state.blocked.slice(),
    keysOnFloor: state.keysOnFloor.map(function (k) { return k.slice(); }),
    keysCollected: state.keysCollected, gateOpen: state.gateOpen,
    escaped: state.escaped, drowned: state.drowned,
    notes: notes.slice(), scripted: state.scripted.slice()
  };
  state.tick += 1;
  emit(record);
  state.inbox = spoke ? message : "";
  if (spoke) { state.standing = message; state.standingTick = tick; }

  // 12. End check.
  if (state.escaped + state.drowned === 3) {
    state.done = true; state.reason = "complete";
  } else if (state.clock >= FLOOD_CLOCK) {
    state.done = true; state.reason = "complete";
  } else if (state.tick >= CONFIG.maxTicks) {
    state.done = true; state.reason = "timeup";
  }
}
emit({ kind: "end", tick: state.tick, text: state.reason });

var score = teamScore();
var results = {
  names: POLICY_NAMES.slice(),
  scores: [score, score, score, score],
  roles: ["keeper", "runner", "runner", "runner"],
  teamScore: score, keys: state.keysCollected, keyCount: CONFIG.keyCount,
  escaped: state.escaped, drowned: state.drowned,
  messages: state.messages.length, ticks: state.tick,
  maxTicks: CONFIG.maxTicks, clock: state.clock, reason: state.reason
};
var payload = {
  protocol: "lighthouse.replay.v1",
  names: NAMES, policyNames: POLICY_NAMES,
  config: CONFIG, events: events, results: results, states: states
};
if (states.length !== events.length + 1) {
  throw new Error("states/events mismatch: " + states.length + " vs " +
    events.length);
}
var out = path.join(__dirname, "sample_replay.json");
fs.writeFileSync(out, JSON.stringify(payload, null, 1));
console.log("wrote", out, events.length, "events;",
  "keys", state.keysCollected + "/" + CONFIG.keyCount,
  "escaped", state.escaped, "drowned", state.drowned,
  "reason", state.reason, "score", score.toFixed(1));
