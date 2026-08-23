// Lighthouse shared renderer + drivers.
//
// One canvas scene — the god-view maze, the rising tide, three fog cones,
// the portcullis, the keeper's radio subtitle with its tick-cost badge, the
// lighthouse tower, and three corner thumbnails showing each runner's
// cramped 3x3 view — fed by three drivers: live /global websocket, live
// /player websocket, and replay (from the game's /replay websocket or the
// static wasm bundle). All state derivation happens server-side / wasm-side;
// this file only draws board-state objects:
//   {seats:[{name,role,status,pos,keys,lastMove,blocked,window,notes,
//            messages,scripted,pending} x4],
//    grid:[strings], exit:[x,y], gateOpen, keysOnFloor:[[x,y]],
//    keysCollected, keyCount, tick, maxTicks, clock, tideRows, waterLine,
//    message, messageAge, messageCost, escaped, drowned, score,
//    phase:"running|done", gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome.
  // Lighthouse seats four cogs: the keeper is red, the runners blue, green
  // and yellow — the same order as the four sprites.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  // The subtitle plate holds at full opacity for a beat, then fades down to
  // a resting tint so a paused frame still shows the standing order.
  var PICK_HOLD_MS = 2500;
  var PICK_FADE_MS = 700;
  var PICK_REST = 0.4;
  // The water eases to a new line rather than teleporting.
  var TIDE_EASE_MS = 500;
  var GATE_FLARE_MS = 600;
  var DROWN_BURST_MS = 700;

  var WATER = "rgba(58, 124, 140, 0.55)";
  var WATER_CREST = "rgba(146, 214, 226, 0.85)";
  var SCRIM = "rgba(12, 10, 8, 0.62)";

  var GLYPH_FONT = "'rajdhani', 'Apple Symbols', 'Segoe UI Symbol', " +
    "'Noto Sans Symbols 2', system-ui, sans-serif";

  var MOVE_WORDS = {
    N: "north", S: "south", E: "east", W: "west", WAIT: "holds still"
  };
  var STATUS_GLYPH = { active: "\u25B2", escaped: "\u2714", drowned: "\u2248" };

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  // Babel's ellipsize, cutting by code point rather than by UTF-16 code
  // unit: the subtitle plate carries whatever the keeper transmitted, and
  // String.slice would happily cut an astral rune (an emoji, say) between
  // its surrogates and render a replacement box. The design note asks for
  // a rune-safe boundary here.
  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var runes = Array.from(text);
    var cut = runes.join("");
    while (runes.length > 1 &&
        ctx.measureText(cut + "…").width > maxWidth) {
      runes.pop();
      cut = runes.join("");
    }
    return cut + "…";
  }

  // Colour helpers for the rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  var NOTE_LINES = 3, NOTE_LINE_H = 12, NOTE_PAD = 6;

  function noteHeight(scale) {
    return (NOTE_LINES * NOTE_LINE_H + NOTE_PAD * 2 - 2) * scale;
  }

  function drawParchment(ctx, x, y, w, text, scale) {
    var pad = NOTE_PAD * scale;
    var lineH = NOTE_LINE_H * scale;
    var h = noteHeight(scale);
    ctx.save();
    ctx.font = Math.round(10.5 * scale) + "px " + GLYPH_FONT;
    var lines = text ? wrapLines(ctx, text, w - pad * 2, NOTE_LINES) : [];
    ctx.fillStyle = text ? "rgba(242, 232, 216, 0.92)" :
      "rgba(242, 232, 216, 0.10)";
    ctx.strokeStyle = text ? CARD_EDGE : "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1;
    ctx.setLineDash(text ? [] : [3, 3]);
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    if (text) {
      ctx.beginPath();
      ctx.moveTo(x + w - 7 * scale, y);
      ctx.lineTo(x + w, y + 7 * scale);
      ctx.lineTo(x + w - 7 * scale, y + 7 * scale);
      ctx.closePath();
      ctx.fillStyle = "rgba(42, 31, 22, 0.25)";
      ctx.fill();
    }
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    if (text) {
      ctx.fillStyle = INK;
      lines.forEach(function (line, i) {
        ctx.fillText(line, x + pad, y + pad + i * lineH);
      });
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText("NO NOTES YET", x + pad, y + pad);
    }
    ctx.restore();
  }

  // A small tag ("KEEPER", "OUT") in the seat's colour.
  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  // ---- Layout --------------------------------------------------------------

  // The maze is letterboxed and integer-scaled into the stage. The three
  // 3x3 thumbnails live in the right gutter on a wide stage, collapse into
  // one row under the maze below 520px, and hide entirely below 420px — so
  // the board itself never shrinks below a readable cell.
  function computeLayout(w, h, cols, rows) {
    var margin = 10;
    var subH = Math.max(30, Math.min(56, Math.round(h * 0.13)));
    var mode = w >= 520 ? "gutter" : (w >= 420 ? "row" : "none");
    var gutterW = mode === "gutter" ?
      Math.max(84, Math.min(140, Math.round(w * 0.16))) : 0;
    var rowH = mode === "row" ?
      Math.max(48, Math.min(78, Math.round(h * 0.18))) : 0;
    var availW = Math.max(40, w - 2 * margin - gutterW);
    var availH = Math.max(40, h - 2 * margin - subH - rowH);
    var cell = Math.max(3, Math.floor(Math.min(availW / cols, availH / rows)));
    var boardW = cell * cols;
    var boardH = cell * rows;
    var boardX = margin + Math.floor((availW - boardW) / 2);
    var boardY = margin + Math.floor((availH - boardH) / 2);
    var thumbs = [];
    if (mode === "gutter") {
      var slotH = Math.floor((h - 2 * margin - subH) / 3);
      var side = Math.min(gutterW - 12, slotH - 20);
      for (var i = 0; i < 3; i++) {
        thumbs.push({
          x: w - margin - gutterW + Math.floor((gutterW - side) / 2),
          y: margin + i * slotH + 14,
          size: Math.max(24, side)
        });
      }
    } else if (mode === "row") {
      var slotW = Math.floor((w - 2 * margin) / 3);
      var side2 = Math.min(slotW - 16, rowH - 18);
      for (var k = 0; k < 3; k++) {
        thumbs.push({
          x: margin + k * slotW + Math.floor((slotW - side2) / 2),
          y: h - margin - subH - rowH + 14,
          size: Math.max(20, side2)
        });
      }
    }
    return {
      margin: margin, cell: cell, cols: cols, rows: rows,
      boardX: boardX, boardY: boardY, boardW: boardW, boardH: boardH,
      subtitle: { x: margin, y: h - margin - subH, w: w - 2 * margin,
        h: subH },
      thumbs: thumbs, mode: mode, width: w, height: h,
      scale: Math.max(0.55, Math.min(1.6, cell / 34))
    };
  }

  // ---- Tile art ------------------------------------------------------------

  // Deterministic per-tile jitter so the masonry reads as stone rather than
  // a grey rectangle, and never crawls between frames.
  function tileNoise(x, y) {
    var n = Math.sin(x * 127.1 + y * 311.7) * 43758.5453;
    return n - Math.floor(n);
  }

  function drawWall(ctx, x, y, cell) {
    var n = tileNoise(x, y);
    var base = 26 + Math.round(n * 14);
    ctx.fillStyle = "rgb(" + base + "," + (base - 4) + "," + (base - 9) + ")";
    ctx.fillRect(x, y, cell, cell);
    // Lit bevel top and left, mortar bottom and right.
    ctx.fillStyle = "rgba(242, 232, 216, 0.13)";
    ctx.fillRect(x, y, cell, 1);
    ctx.fillRect(x, y, 1, cell);
    ctx.fillStyle = "rgba(0, 0, 0, 0.45)";
    ctx.fillRect(x, y + cell - 1, cell, 1);
    ctx.fillRect(x + cell - 1, y, 1, cell);
    // A chiselled block seam.
    if (cell >= 10) {
      ctx.fillStyle = "rgba(0, 0, 0, 0.22)";
      ctx.fillRect(x + 1, y + Math.floor(cell * (0.42 + n * 0.16)),
        cell - 2, 1);
    }
  }

  function drawKey(ctx, cx, cy, cell, phase) {
    var bob = Math.sin(phase) * cell * 0.06;
    var r = cell * 0.16;
    ctx.save();
    ctx.translate(cx, cy + bob);
    var glow = ctx.createRadialGradient(0, 0, 0, 0, 0, cell * 0.55);
    glow.addColorStop(0, rgba(AMBER, 0.42));
    glow.addColorStop(1, rgba(AMBER, 0));
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(0, 0, cell * 0.55, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = AMBER;
    ctx.fillStyle = AMBER;
    ctx.lineWidth = Math.max(1, cell * 0.07);
    ctx.beginPath();
    ctx.arc(-cell * 0.14, 0, r, 0, Math.PI * 2);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-cell * 0.14 + r, 0);
    ctx.lineTo(cell * 0.28, 0);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(cell * 0.16, 0);
    ctx.lineTo(cell * 0.16, cell * 0.14);
    ctx.moveTo(cell * 0.26, 0);
    ctx.lineTo(cell * 0.26, cell * 0.14);
    ctx.stroke();
    ctx.restore();
  }

  // The exit: a portcullis in the top wall. Shut = iron bars over a dark
  // arch with the keyhole plate counting keys; open = bars retracted with
  // amber light spilling down the corridor.
  function drawPortcullis(ctx, x, y, cell, open, flare, collected, total) {
    ctx.save();
    ctx.fillStyle = open ? "#20150c" : "#150f0a";
    ctx.fillRect(x, y, cell, cell);
    if (open) {
      var spill = ctx.createLinearGradient(0, y, 0, y + cell * 3);
      spill.addColorStop(0, rgba(AMBER, 0.55 + 0.35 * flare));
      spill.addColorStop(1, rgba(AMBER, 0));
      ctx.fillStyle = spill;
      ctx.fillRect(x, y, cell, cell * 3);
      ctx.strokeStyle = rgba(AMBER, 0.9);
      ctx.lineWidth = Math.max(1, cell * 0.09);
      ctx.beginPath();
      ctx.moveTo(x + cell * 0.15, y + cell * 0.18);
      ctx.lineTo(x + cell * 0.85, y + cell * 0.18);
      ctx.stroke();
      if (flare > 0) {
        ctx.fillStyle = rgba(PAPER, 0.5 * flare);
        ctx.fillRect(x, y, cell, cell);
      }
    } else {
      ctx.strokeStyle = "#8d8378";
      ctx.lineWidth = Math.max(1, cell * 0.08);
      for (var b = 1; b <= 3; b++) {
        var bx = x + (cell * b) / 4;
        ctx.beginPath();
        ctx.moveTo(bx, y + 1);
        ctx.lineTo(bx, y + cell - 1);
        ctx.stroke();
      }
      ctx.beginPath();
      ctx.moveTo(x + 1, y + cell * 0.5);
      ctx.lineTo(x + cell - 1, y + cell * 0.5);
      ctx.stroke();
      if (cell >= 16) {
        ctx.fillStyle = PAPER;
        ctx.font = "700 " + Math.round(cell * 0.36) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(collected + "/" + total, x + cell / 2, y + cell * 0.72);
      }
    }
    ctx.restore();
  }

  // ---- Tide bookkeeping ----------------------------------------------------

  var tideAnim = { shown: null, from: null, at: 0 };

  function easedWaterLine(target, now) {
    if (tideAnim.shown === null) {
      tideAnim.shown = target;
      tideAnim.from = target;
      return target;
    }
    if (target !== tideAnim.shown) {
      tideAnim.from = easedWaterLine(tideAnim.shown, now);
      tideAnim.shown = target;
      tideAnim.at = now;
    }
    var t = Math.min(1, (now - tideAnim.at) / TIDE_EASE_MS);
    var e = 1 - Math.pow(1 - t, 3);
    return tideAnim.from + (tideAnim.shown - tideAnim.from) * e;
  }

  // ---- The stage -----------------------------------------------------------

  var scrimCanvas = null;

  function fogLayer(w, h) {
    if (!scrimCanvas) {
      scrimCanvas = document.createElement("canvas");
    }
    if (scrimCanvas.width !== w || scrimCanvas.height !== h) {
      scrimCanvas.width = w;
      scrimCanvas.height = h;
    }
    return scrimCanvas;
  }

  function runnerSeats(view) {
    return (view.seats || []).slice(1);
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var now = view.now || Date.now();
    var grid = view.grid || [];
    var rows = grid.length || 11;
    var cols = grid.length ? grid[0].length : 17;
    var layout = computeLayout(w, h, cols, rows);
    var cell = layout.cell;
    var fx = view.effects || {};

    // Backdrop.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(12, 9, 6, 0.72)";
    ctx.fillRect(0, 0, w, h);

    if (!grid.length) {
      // A redacted player frame carries no map: say so rather than draw a
      // grey box.
      ctx.fillStyle = GHOST;
      ctx.font = "600 14px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("NO MAP — YOU ARE BLIND", w / 2, h / 2);
      drawSubtitle(ctx, layout, view, now, fx);
      return;
    }

    // Floor tiles: the flagstone pattern, brightened, clipped to the maze.
    ctx.save();
    ctx.beginPath();
    for (var fy = 0; fy < rows; fy++) {
      for (var fxi = 0; fxi < cols; fxi++) {
        if (grid[fy][fxi] !== "#") {
          ctx.rect(layout.boardX + fxi * cell, layout.boardY + fy * cell,
            cell, cell);
        }
      }
    }
    ctx.clip();
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
      ctx.fillRect(layout.boardX, layout.boardY, layout.boardW, layout.boardH);
      ctx.fillStyle = "rgba(28, 22, 15, 0.30)";
    } else {
      ctx.fillStyle = "#3b3025";
    }
    ctx.fillRect(layout.boardX, layout.boardY, layout.boardW, layout.boardH);
    ctx.restore();

    // Walls.
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        if (grid[y][x] === "#") {
          drawWall(ctx, layout.boardX + x * cell, layout.boardY + y * cell,
            cell);
        }
      }
    }

    // Exit.
    var exit = view.exit || [1, 0];
    var gateAt = fx.gateAt;
    var flare = typeof gateAt === "number" ?
      Math.max(0, 1 - (now - gateAt) / GATE_FLARE_MS) : 0;
    drawPortcullis(ctx, layout.boardX + exit[0] * cell,
      layout.boardY + exit[1] * cell, cell, !!view.gateOpen, flare,
      view.keysCollected || 0, view.keyCount || 3);

    // Keys.
    (view.keysOnFloor || []).forEach(function (key, i) {
      drawKey(ctx, layout.boardX + (key[0] + 0.5) * cell,
        layout.boardY + (key[1] + 0.5) * cell, cell,
        now / 520 + i * 1.7);
    });

    // Water.
    var line = easedWaterLine(
      typeof view.waterLine === "number" ? view.waterLine : rows, now);
    if (line < rows) {
      var surfaceY = layout.boardY + line * cell;
      ctx.save();
      ctx.beginPath();
      ctx.rect(layout.boardX, surfaceY, layout.boardW,
        layout.boardY + layout.boardH - surfaceY);
      ctx.clip();
      ctx.fillStyle = WATER;
      ctx.fillRect(layout.boardX, surfaceY, layout.boardW,
        layout.boardY + layout.boardH - surfaceY);
      // Two ripples at different phases and speeds.
      ctx.strokeStyle = "rgba(146, 214, 226, 0.22)";
      ctx.lineWidth = 1;
      for (var r = 0; r < 2; r++) {
        ctx.beginPath();
        for (var px = 0; px <= layout.boardW; px += 4) {
          var yy = surfaceY + cell * (0.55 + r * 0.9) +
            Math.sin(px / (26 + r * 13) + now / (700 + r * 430)) *
              cell * 0.12;
          if (px === 0) ctx.moveTo(layout.boardX + px, yy);
          else ctx.lineTo(layout.boardX + px, yy);
        }
        ctx.stroke();
      }
      ctx.restore();
      // Crest line plus foam speckles.
      ctx.save();
      ctx.strokeStyle = WATER_CREST;
      ctx.lineWidth = Math.max(1, cell * 0.09);
      ctx.beginPath();
      for (var cx2 = 0; cx2 <= layout.boardW; cx2 += 4) {
        var cy2 = surfaceY + Math.sin(cx2 / 19 + now / 480) * cell * 0.08;
        if (cx2 === 0) ctx.moveTo(layout.boardX + cx2, cy2);
        else ctx.lineTo(layout.boardX + cx2, cy2);
      }
      ctx.stroke();
      ctx.fillStyle = "rgba(242, 232, 216, 0.55)";
      for (var s = 0; s < Math.round(layout.boardW / 26); s++) {
        var sx = layout.boardX + ((s * 53 + Math.round(now / 90)) %
          layout.boardW);
        ctx.fillRect(sx, surfaceY - 1 +
          Math.sin(sx / 15 + now / 380) * cell * 0.07, 2, 2);
      }
      ctx.restore();
    }

    // Runners.
    var runners = runnerSeats(view);
    runners.forEach(function (seat, index) {
      if (!seat) return;
      var color = seatColor(index + 1);
      var drownAt = (fx.drownAt || [])[index];
      if (seat.status === "drowned") {
        if (typeof drownAt === "number" && now - drownAt < DROWN_BURST_MS) {
          var last = (fx.lastPos || [])[index];
          if (last) {
            drawBubbles(ctx, layout, last, cell,
              (now - drownAt) / DROWN_BURST_MS, color);
          }
        }
        return;
      }
      if (!seat.pos) return;
      drawRunner(ctx, images, layout, seat, index, cell, now);
    });

    // Fog: the dramatic-irony device. Everything outside the runners' 3x3
    // windows is scrimmed; each window is a clear square with a soft
    // radial falloff.
    var fog = fogLayer(layout.boardW, layout.boardH);
    var fctx = fog.getContext("2d");
    fctx.clearRect(0, 0, layout.boardW, layout.boardH);
    fctx.fillStyle = SCRIM;
    fctx.fillRect(0, 0, layout.boardW, layout.boardH);
    fctx.globalCompositeOperation = "destination-out";
    runners.forEach(function (seat) {
      if (!seat || !seat.pos) return;
      var cx = (seat.pos[0] + 0.5) * cell;
      var cy = (seat.pos[1] + 0.5) * cell;
      var g = fctx.createRadialGradient(cx, cy, cell * 0.9, cx, cy,
        cell * 1.75);
      g.addColorStop(0, "rgba(0,0,0,1)");
      g.addColorStop(1, "rgba(0,0,0,0)");
      fctx.fillStyle = g;
      fctx.fillRect(cx - cell * 2, cy - cell * 2, cell * 4, cell * 4);
    });
    fctx.globalCompositeOperation = "source-over";
    ctx.drawImage(fog, layout.boardX, layout.boardY);

    // Window rims, in the runner's seat colour, above the scrim.
    runners.forEach(function (seat, index) {
      if (!seat || !seat.pos) return;
      ctx.save();
      ctx.strokeStyle = rgba(COLOR_HEX[seatColor(index + 1)], 0.75);
      ctx.lineWidth = 1;
      ctx.strokeRect(layout.boardX + (seat.pos[0] - 1) * cell + 0.5,
        layout.boardY + (seat.pos[1] - 1) * cell + 0.5,
        cell * 3 - 1, cell * 3 - 1);
      ctx.restore();
    });

    if (flare > 0) {
      drawTag(ctx, layout.boardX + (exit[0] + 0.5) * cell,
        layout.boardY + exit[1] * cell - cell * 0.6, "gate open", AMBER,
        layout.scale);
    }

    drawLighthouse(ctx, images, layout, view, now, fx);
    // The keeper's private notes, on paper under the tower: the audience
    // watches the plan form. Only where there is room for it.
    var keeper = (view.seats || [])[0];
    if (keeper && layout.width >= 520) {
      var noteW = Math.min(190, layout.boardX - layout.margin * 2);
      if (noteW > 90) {
        drawParchment(ctx, layout.margin,
          layout.margin + layout.height * 0.20, noteW, keeper.notes || "",
          layout.scale);
      }
    }
    drawThumbnails(ctx, images, layout, view, now);
    drawSubtitle(ctx, layout, view, now, fx);
  }

  function drawRunner(ctx, images, layout, seat, index, cell, now) {
    var color = seatColor(index + 1);
    var sprite = images["soldier_" + color + "_front.png"];
    var cx = layout.boardX + (seat.pos[0] + 0.5) * cell;
    var cy = layout.boardY + (seat.pos[1] + 0.5) * cell;
    // The nano-banana cog is drawn larger than its tile with its wheels
    // on the tile's lower edge, so the kit (life ring, pack, flag) reads
    // at board scale; the seat tint sits in a ground ellipse under the
    // wheels rather than a ring that would hide the kit.
    var size = cell * 1.45;
    var feet = cy + cell * 0.42;
    ctx.save();
    if (sprite && sprite.width) {
      ctx.fillStyle = rgba(COLOR_HEX[color], 0.55);
      ctx.beginPath();
      ctx.ellipse(cx, feet - cell * 0.02, cell * 0.36, cell * 0.11, 0, 0,
        Math.PI * 2);
      ctx.fill();
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(sprite, cx - size / 2, feet - size, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(cx - size / 3, cy - size / 3, size / 1.5, size / 1.5);
    }
    if (seat.pending) {
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = Math.max(1, cell * 0.07);
      ctx.setLineDash([cell * 0.2, cell * 0.16]);
      ctx.beginPath();
      ctx.ellipse(cx, feet - cell * 0.02, cell * 0.46, cell * 0.16, 0, 0,
        Math.PI * 2);
      ctx.stroke();
      ctx.setLineDash([]);
    }
    // Key pips docked under the runner.
    for (var k = 0; k < Math.min(seat.keys || 0, 4); k++) {
      ctx.fillStyle = AMBER;
      ctx.fillRect(cx - cell * 0.3 + k * cell * 0.18,
        cy + cell * 0.34, cell * 0.12, cell * 0.12);
    }
    ctx.restore();
  }

  function drawBubbles(ctx, layout, tile, cell, t, color) {
    ctx.save();
    ctx.globalAlpha = 1 - t;
    ctx.fillStyle = "rgba(212, 236, 240, 0.8)";
    for (var i = 0; i < 6; i++) {
      var a = i * 1.04;
      var rr = cell * (0.12 + 0.3 * t);
      ctx.beginPath();
      ctx.arc(layout.boardX + (tile[0] + 0.5) * cell + Math.cos(a) * rr,
        layout.boardY + (tile[1] + 0.5) * cell - t * cell * 0.7 +
          Math.sin(a) * rr,
        Math.max(1, cell * 0.07 * (1 - t)), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 0.45 * (1 - t);
    ctx.fillStyle = shade(COLOR_HEX[color], 0.5);
    ctx.fillRect(layout.boardX + tile[0] * cell + cell * 0.2,
      layout.boardY + tile[1] * cell + cell * 0.2, cell * 0.6, cell * 0.6);
    ctx.restore();
  }

  // The tower: the show's logo moment, and a second read on "the keeper
  // spoke" — the beam flares on every transmit.
  function drawLighthouse(ctx, images, layout, view, now, fx) {
    var s = Math.max(18, Math.min(46, layout.height * 0.11));
    var x = layout.margin + s * 0.6;
    var y = layout.margin + s * 1.25;
    var sayAt = fx.sayAt;
    var pulse = typeof sayAt === "number" ?
      Math.max(0, 1 - (now - sayAt) / 900) : 0;
    ctx.save();
    // Beam.
    var angle = (now / 2600) % (Math.PI * 2);
    var beam = ctx.createRadialGradient(x, y - s * 0.75, 0, x, y - s * 0.75,
      s * 3.2);
    beam.addColorStop(0, rgba(AMBER, 0.30 + 0.45 * pulse));
    beam.addColorStop(1, rgba(AMBER, 0));
    ctx.fillStyle = beam;
    ctx.beginPath();
    ctx.moveTo(x, y - s * 0.75);
    ctx.arc(x, y - s * 0.75, s * 3.2, angle - 0.22, angle + 0.22);
    ctx.closePath();
    ctx.fill();
    // Tower.
    ctx.fillStyle = "rgba(242, 232, 216, 0.82)";
    ctx.beginPath();
    ctx.moveTo(x - s * 0.30, y + s * 0.55);
    ctx.lineTo(x - s * 0.17, y - s * 0.55);
    ctx.lineTo(x + s * 0.17, y - s * 0.55);
    ctx.lineTo(x + s * 0.30, y + s * 0.55);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = COLOR_HEX.red;
    ctx.fillRect(x - s * 0.24, y - s * 0.16, s * 0.48, s * 0.16);
    ctx.fillRect(x - s * 0.27, y + s * 0.16, s * 0.54, s * 0.14);
    // Lantern room.
    ctx.fillStyle = rgba(AMBER, 0.65 + 0.35 * pulse);
    ctx.fillRect(x - s * 0.2, y - s * 0.9, s * 0.4, s * 0.35);
    ctx.fillStyle = INK;
    ctx.fillRect(x - s * 0.24, y - s * 0.95, s * 0.48, s * 0.07);
    // The keeper, lantern raised, at the foot of the tower.
    var keeper = images["soldier_red_front.png"];
    if (keeper && keeper.width) {
      var ks = s * 1.6;
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(keeper, x + s * 0.2, y + s * 0.6 - ks, ks, ks);
    }
    ctx.restore();
  }

  function drawThumbnails(ctx, images, layout, view, now) {
    if (!layout.thumbs.length) return;
    var runners = runnerSeats(view);
    layout.thumbs.forEach(function (box, index) {
      var seat = runners[index];
      if (!seat) return;
      var color = COLOR_HEX[seatColor(index + 1)];
      var side = box.size;
      var sub = side / 3;
      ctx.save();
      ctx.fillStyle = "rgba(12, 9, 6, 0.85)";
      ctx.fillRect(box.x, box.y, side, side);
      var window = seat.window || [];
      for (var wy = 0; wy < 3; wy++) {
        var line = window[wy] || "###";
        for (var wx = 0; wx < 3; wx++) {
          var g = line[wx] || "#";
          var px = box.x + wx * sub;
          var py = box.y + wy * sub;
          if (g === "#") {
            drawWall(ctx, px, py, sub);
          } else {
            ctx.fillStyle = "#3b3025";
            ctx.fillRect(px, py, sub, sub);
            if (g === "~") {
              ctx.fillStyle = WATER;
              ctx.fillRect(px, py, sub, sub);
            } else if (g === "K") {
              drawKey(ctx, px + sub / 2, py + sub / 2, sub, now / 520);
            } else if (g === "E" || g === "O") {
              ctx.fillStyle = g === "O" ? rgba(AMBER, 0.8) : "#8d8378";
              ctx.fillRect(px + sub * 0.2, py + sub * 0.2, sub * 0.6,
                sub * 0.6);
            } else if (g === "@") {
              var me = images["soldier_" + seatColor(index + 1) +
                "_front.png"];
              if (me && me.width) {
                ctx.imageSmoothingEnabled = true;
                ctx.drawImage(me, px - sub * 0.1, py - sub * 0.25,
                  sub * 1.2, sub * 1.2);
              } else {
                ctx.fillStyle = color;
                ctx.fillRect(px + sub * 0.22, py + sub * 0.22, sub * 0.56,
                  sub * 0.56);
              }
            } else if (g === "1" || g === "2" || g === "3") {
              ctx.fillStyle = COLOR_HEX[seatColor(Number(g))];
              ctx.fillRect(px + sub * 0.3, py + sub * 0.3, sub * 0.4,
                sub * 0.4);
            }
          }
        }
      }
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.strokeRect(box.x + 0.5, box.y + 0.5, side - 1, side - 1);
      ctx.font = "600 " + Math.round(Math.max(8, side * 0.20)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = PAPER;
      var caption = ellipsize(ctx,
        (STATUS_GLYPH[seat.status] || "") + " " + (seat.name || ""), side);
      ctx.fillText(caption, box.x, box.y - 3);
      for (var k = 0; k < Math.min(seat.keys || 0, 4); k++) {
        ctx.fillStyle = AMBER;
        ctx.fillRect(box.x + k * side * 0.14, box.y + side + 3,
          side * 0.1, side * 0.1);
      }
      ctx.restore();
    });
  }

  // The radio subtitle: keeper-red on paper with the tick-cost badge.
  function drawSubtitle(ctx, layout, view, now, fx) {
    var box = layout.subtitle;
    var sayAt = fx.sayAt;
    var age = typeof sayAt === "number" ? now - sayAt : null;
    var alpha = age === null ? PICK_REST :
      age < PICK_HOLD_MS ? 1 :
      Math.max(PICK_REST, 1 - (age - PICK_HOLD_MS) / PICK_FADE_MS *
        (1 - PICK_REST));
    var text = view.message || "";
    ctx.save();
    ctx.globalAlpha = text ? alpha : PICK_REST * 0.8;
    ctx.fillStyle = PAPER;
    ctx.strokeStyle = COLOR_HEX.red;
    ctx.lineWidth = 2;
    roundRect(ctx, box.x, box.y, box.w, box.h, 4);
    ctx.fill();
    ctx.stroke();
    var badgeW = Math.min(74, box.w * 0.22);
    var fontPx = Math.max(10, Math.min(16, box.h * 0.38));
    ctx.font = "600 " + Math.round(fontPx) + "px " + GLYPH_FONT;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillStyle = text ? INK : GHOST;
    var maxLines = box.w < 420 ? 2 : 1;
    var lines = wrapLines(ctx, text || "— silence —",
      box.w - badgeW - 20, maxLines);
    lines.forEach(function (line, i) {
      ctx.fillText(line, box.x + 8,
        box.y + (box.h - lines.length * (fontPx + 2)) / 2 +
          i * (fontPx + 2));
    });
    if (text) {
      var pulse = age !== null && age < 420 ? 1 - age / 420 : 0;
      ctx.fillStyle = rgba(AMBER, 0.85);
      roundRect(ctx, box.x + box.w - badgeW - 6, box.y + 5, badgeW,
        box.h - 10, 3);
      ctx.fill();
      if (pulse > 0) {
        ctx.fillStyle = rgba(PAPER, 0.6 * pulse);
        roundRect(ctx, box.x + box.w - badgeW - 6, box.y + 5, badgeW,
          box.h - 10, 3);
        ctx.fill();
      }
      ctx.fillStyle = INK;
      ctx.font = "700 " + Math.round(Math.max(8, fontPx * 0.68)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("\u25C9 +" + (view.messageCost || 1) + " TICK",
        box.x + box.w - badgeW / 2 - 6, box.y + box.h / 2);
    }
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous aliases ("Fresnel", "Sprocket");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // Tick numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first tick event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "tick") return events[i].tick === 1 ? 1 : 0;
    }
    return 0;
  }

  function moveWord(token) {
    return MOVE_WORDS[token] || token;
  }

  // `ctx` carries what a line needs from earlier events: the runner names
  // and the running tallies.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "The lantern is lit — one cog sees the maze, three are blind.";
      case "say":
        return name(0) + ": \u201C" + nameMap.text(event.text || "") +
          "\u201D (+" + (event.cost || 1) + " tick)";
      case "key":
        return name(event.seat) + " takes a key (" +
          (event.keysCollected || 0) + "/" + (ctx.keyCount || 3) + ")";
      case "escape":
        return name(event.seat) + " escapes";
      case "drown":
        return name(event.seat) + " is taken by the tide";
      case "tick":
        return tickText(event, nameMap, ctx);
      case "end":
        return endText(event, ctx);
      default: return JSON.stringify(event);
    }
  }

  function tickText(event, nameMap, ctx) {
    var parts = [];
    (event.moves || []).forEach(function (token, index) {
      if (!token) return;
      // A runner that escaped or drowned on this tick already has its own
      // line above; narrating its last step after it would read backwards.
      if ((event.alive || [])[index] === false) return;
      var who = clampName(nameMap.seat(index + 1));
      if ((event.blocked || [])[index]) {
        parts.push(who + " bumps a wall");
      } else if (token === "WAIT") {
        parts.push(who + " holds still");
      } else {
        parts.push(who + " moves " + moveWord(token));
      }
    });
    if (event.gateOpen && !ctx.gateSeen) {
      ctx.gateSeen = true;
      parts.push("THE GATE OPENS");
    }
    if (!parts.length) parts.push("the water rises");
    return parts.join(" \u00B7 ");
  }

  function endText(event, ctx) {
    var out = ctx.escaped || 0;
    return "Final — " + out + " of 3 out, " + (ctx.keys || 0) +
      " keys, score " + (ctx.score || 0).toFixed(1) +
      (event.text === "deadline" ? " — episode deadline." :
        event.text === "timeup" ? " — the clock ran out." : ".");
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "TICK " + block;
  }

  // Renders the full transcript grouped into one section per tick.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex, results) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { keyCount: 3, keys: 0, escaped: 0, score: 0, gateSeen: false };
    if (results) {
      ctx.keyCount = results.keyCount || 3;
      ctx.keys = results.keys !== undefined ? results.keys :
        (results.keysCollected || 0);
      ctx.escaped = results.escaped || 0;
      ctx.score = results.teamScore !== undefined ? results.teamScore :
        (results.score || 0);
    }
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.tick - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "say" ? " seat0" : "") +
        (event.kind === "key" || event.kind === "escape" ?
          " feed-score seat" + (event.seat % COLORS.length) : "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      // Notes: say-styled, only when the seat's notes changed.
      if (event.kind === "tick") {
        (event.notes || []).forEach(function (note, seat) {
          if (!note || note === lastNotes[seat]) return;
          lastNotes[seat] = note;
          html += '<div class="feed-line feed-say' +
            (i >= limit ? " feed-future" : "") + '">' +
            escapeHtml(clampName(nameMap.seat(seat)) + " notes: " +
              nameMap.text(note)) + "</div>";
        });
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the keeper last spoke (the subtitle plate and the beam), when the
  // gate flipped (the portcullis flare), and where and when each runner
  // drowned (the bubble burst).
  function makeEffects() {
    var seen = 0;
    var sayAt = null;
    var gateAt = null;
    var drownAt = [null, null, null];
    var lastPos = [null, null, null];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest events get to animate — replaying every historical flash as
      // a fresh one would strobe the stage.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "say") {
            sayAt = animate ? now : now - PICK_HOLD_MS;
          } else if (event.kind === "drown") {
            drownAt[event.seat - 1] = animate ? now : null;
            lastPos[event.seat - 1] = [event.x, event.y];
          } else if (event.kind === "tick") {
            if (event.gateOpen && gateAt === null) {
              gateAt = animate ? now : now - GATE_FLARE_MS;
            }
            (event.positions || []).forEach(function (p, i) {
              if (p && p[0] >= 0) lastPos[i] = p;
            });
          }
        }
      },
      reset: function () {
        seen = 0; sayAt = null; gateAt = null;
        drownAt = [null, null, null];
        lastPos = [null, null, null];
      },
      view: function () {
        return {
          effects: {
            sayAt: sayAt, gateAt: gateAt,
            drownAt: drownAt.slice(), lastPos: lastPos.slice()
          }
        };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state) {
    if (!state) return "";
    var parts = [];
    parts.push("TICK " + (state.tick || 0) +
      (state.maxTicks ? " / " + state.maxTicks : ""));
    if (typeof state.waterLine === "number") {
      parts.push("TIDE ROW " + state.waterLine);
    }
    parts.push("KEYS " + (state.keysCollected || 0) + "/" +
      (state.keyCount || 3));
    if (state.gameDone || state.done) parts.push("FINAL");
    return parts.join(" \u00B7 ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var pending = seat.pending && !state.gameDone;
      if (index === 0) {
        html += '<div class="plate ' + seatColor(index) + '">' +
          '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
          "</span>" +
          (pending ? '<span class="plate-it">\u25B6</span>' : "") +
          '<span class="plate-msg">\u25C9 ' + (seat.messages || 0) +
          "</span>" +
          '<span class="plate-label">msgs</span>' +
          '<span class="plate-score">' +
          (state.score || 0).toFixed(1) + "</span>" +
          "</div>";
        return;
      }
      var pips = "";
      for (var p = 0; p < Math.min(seat.keys || 0, 4); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      html += '<div class="plate ' + seatColor(index) + " " +
        (seat.status || "active") + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (pending ? '<span class="plate-it">\u25B6</span>' : "") +
        '<span class="plate-status">' +
        (STATUS_GLYPH[seat.status] || "\u25B2") + "</span>" +
        '<span class="plate-label">' + (seat.status || "active") + "</span>" +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function verdictText(results) {
    switch (results.escaped || 0) {
      case 3: return "ALL THREE OUT";
      case 2: return "TWO OF THREE OUT";
      case 1: return "ONE OF THREE OUT";
      default: return "THE TIDE TOOK THEM";
    }
  }

  function reasonLine(results) {
    var still = 3 - (results.escaped || 0) - (results.drowned || 0);
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.ticks || 0) +
          " of " + (results.maxTicks || results.ticks || 0) + " ticks";
      case "timeup":
        return "the clock ran out with " + still + " still in the maze";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, one row per seat below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var roles = results.roles || [];
    var scores = results.scores || [];
    var verdict = verdictText(results);
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.ticks || 0) + " TICK" +
      ((results.ticks || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' +
      ((results.escaped || 0) >= 2 ? "green" : "red") + '">' + verdict +
      "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">role</span>' +
      '<span class="end-head">status</span>' +
      '<span class="end-head">keys</span>' +
      '<span class="end-head">messages</span>' +
      '<span class="end-head">score</span>';
    var seats = results.seats || [];
    names.forEach(function (name, i) {
      var seat = seats[i] || {};
      var cell = function (value) {
        return '<span class="end-cell">' + value + "</span>";
      };
      html += '<span class="end-cell rank">' + (i + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) + '">' +
        escapeHtml(name) + "</span>" +
        cell(escapeHtml(roles[i] || (i === 0 ? "keeper" : "runner"))) +
        cell(escapeHtml(seat.status || (i === 0 ? "keeper" : "—"))) +
        cell(i === 0 ? "—" : (seat.keys === undefined ? "—" : seat.keys)) +
        cell(i === 0 ? (results.messages || 0) : "—") +
        cell((scores[i] || 0).toFixed(1));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.grid = state.grid || [];
    view.exit = state.exit;
    view.gateOpen = state.gateOpen;
    view.keysOnFloor = state.keysOnFloor || [];
    view.keysCollected = state.keysCollected || 0;
    view.keyCount = state.keyCount || 3;
    view.waterLine = state.waterLine;
    view.tideRows = state.tideRows;
    view.tick = state.tick || 0;
    view.maxTicks = state.maxTicks || 0;
    view.message = state.message || "";
    view.messageCost = state.messageCost || 1;
    view.score = state.score || 0;
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      // Player pages get no policyNames (they must not learn who is behind
      // a seat) and a redacted state (no map), so their map degrades to
      // the aliases and the stage says so.
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, latest);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen,
                Object.assign({}, data,
                  { seats: (latest || {}).seats || [] }),
                true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          renderer.draw(stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          }));
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per tick, a marker
  // per key / escape / drown (coloured by the seat) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.tick - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "key" && kind !== "escape" && kind !== "drown" &&
          kind !== "end") {
        return;
      }
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind !== "end" ? " seat" + (event.seat % COLORS.length) : "") +
        (kind === "end" || kind === "drown" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var results = payload.results || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    // The endscreen's per-seat columns come from the last board state, not
    // from results, which is a team-level record.
    var endResults = Object.assign({}, results,
      { seats: (states[states.length - 1] || {}).seats || [] });
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] || { seats: [] };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, results);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState());
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, endResults,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event just
        // absorbed — so the keeper's words get read and the tick gets seen
        // before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "say" ? 1300 :
          shown && shown.kind === "tick" ? 900 :
          shown && shown.kind === "escape" ? 1200 :
          shown && shown.kind === "drown" ? 1200 :
          shown && shown.kind === "key" ? 900 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw(stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        }));
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.LighthouseRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
