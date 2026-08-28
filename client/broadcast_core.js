// broadcast_core.js — snake-royale board renderer + frame-packet client.
//
// FORKED from coworld-ctf's client/broadcast_core.js. That file is paintbot's
// continuous-2-D draw layer over the Bitworld sprite protocol; this game is a
// small integer grid, so the sprite/layer compositor, every weapon, paint,
// hill, flag and fog draw call, the first-person pipeline and the whole
// zoom/pan/minimap surface are DELETED (design note §Viewer -> Chrome
// provenance: #viewpanel goes entirely). What is kept
// is the shape the page depends on: the same `window.BroadcastCore.create`
// factory and the same method surface, the canvas/DPR sizing, the letterbox
// fit and its `onTransform` callback, the status/text callbacks, the first
// frame signal, and the pace stats. Added: drawGrid, drawSnakes (segments,
// head sprite, tail taper, dead-wreck fade), drawFood, drawTrails (tron),
// drawWrapGhosts (geese), drawTrappedRing and the say-bubble renderer.
//
// The wire is one JSON frame packet per drawn frame (see
// src/snake/broadcast.nim). Its `chrome` field is handed to onText, exactly as
// the starter smuggled its chrome document through the same channel the board
// rides, so the HUD survives every playback path.
//
// Dependency-free IIFE; runs in a Window and in a Dedicated Worker with an
// OffscreenCanvas, one implementation, so protocol and rendering fixes cannot
// drift between the two delivery modes.
(function () {
  'use strict';

  var globalScope = typeof window !== 'undefined' ? window : self;
  var requestFrame = typeof globalScope.requestAnimationFrame === 'function'
    ? globalScope.requestAnimationFrame.bind(globalScope)
    : function (cb) { return setTimeout(function () { cb(Date.now()); }, 16); };
  var cancelFrame = typeof globalScope.cancelAnimationFrame === 'function'
    ? globalScope.cancelAnimationFrame.bind(globalScope)
    : clearTimeout;

  var WIRE = globalScope.SNAKE_WIRE || {};
  var COLOURS = WIRE.colours || ['amber', 'teal', 'violet', 'lime'];
  var COLOUR_HEX = WIRE.colourHex ||
    ['#e8a33d', '#2fb3a8', '#8a5cd6', '#8ec63f'];
  var PIECES = ['head_u', 'head_r', 'head_d', 'head_l', 'body', 'corner',
    'tail'];
  var textDecoder = new TextDecoder('utf-8');

  // ---- sprite kit ---------------------------------------------------------
  // Every sprite is a nano-banana render of the Softmax cog, split by
  // scripts/art/split_snake_sheet.py and shipped next to this file in the
  // static bundle. Loading is best-effort and never blocks a frame: until an
  // image lands the segment draws as its rounded plate in the same colour, so
  // a slow asset can never stop the board from rendering.
  var art = {};
  var artBase = '.';
  function loadArt(name) {
    if (art[name] !== undefined) return;
    art[name] = null;
    var url = artBase + '/' + name + '.png';
    if (typeof createImageBitmap === 'function' &&
        typeof fetch === 'function') {
      fetch(url, { credentials: 'omit' })
        .then(function (r) { return r.ok ? r.blob() : null; })
        .then(function (b) { return b ? createImageBitmap(b) : null; })
        .then(function (bmp) { if (bmp) art[name] = bmp; })
        .catch(function () { });
    } else if (typeof Image === 'function') {
      var img = new Image();
      img.onload = function () { art[name] = img; };
      img.src = url;
    }
  }
  function loadKit() {
    for (var c = 0; c < COLOURS.length; c++) {
      for (var p = 0; p < PIECES.length; p++) {
        loadArt('snake_' + COLOURS[c] + '_' + PIECES[p]);
      }
    }
    loadArt('food_apple');
    loadArt('wreck');
  }

  function colourHex(name) {
    var i = COLOURS.indexOf(name);
    return i >= 0 ? COLOUR_HEX[i] : '#e8a33d';
  }

  // ---- the say bubble's type ----------------------------------------------
  // The bubble is laid out from the cap the SERVER enforces (MaxSayRunes),
  // measured in the font it is drawn in -- never from whatever string happens
  // to be in flight, which is how a remark grows into whatever is above it
  // (the cogchemists 2026-08-24 scar). `data/font.ttf` is the game's own face
  // and ships next to this file in the static bundle; the load is best-effort
  // and the measurement always uses whichever face is actually active, so a
  // failed load degrades to the fallback stack rather than to a wrong box.
  var MAX_SAY_RUNES = WIRE.maxSayRunes || 24;
  var SAY_FACE = 'system-ui, sans-serif';
  var SAY_CAP_SAMPLE = new Array(MAX_SAY_RUNES + 1).join('W');
  var sayCapWidths = {};
  function sayFontFor(cell) { return Math.max(9, Math.round(cell * 0.42)); }
  function sayBandFor(cell) { return Math.round(sayFontFor(cell) * 1.8) + 4; }
  function loadSayFace() {
    if (typeof globalScope.FontFace !== 'function' || !globalScope.fonts) return;
    try {
      var face = new globalScope.FontFace('snakeface',
        'url(' + artBase + '/font.ttf)');
      face.load().then(function (loaded) {
        globalScope.fonts.add(loaded);
        SAY_FACE = '"snakeface", system-ui, sans-serif';
        sayCapWidths = {};              // re-measure the cap in the real face
      }).catch(function () { });
    } catch (error) { /* the fallback stack is already correct */ }
  }
  function shade(hex, f) {
    var n = parseInt(hex.slice(1), 16);
    var r = Math.max(0, Math.min(255, Math.round(((n >> 16) & 255) * f)));
    var g = Math.max(0, Math.min(255, Math.round(((n >> 8) & 255) * f)));
    var b = Math.max(0, Math.min(255, Math.round((n & 255) * f)));
    return 'rgb(' + r + ',' + g + ',' + b + ')';
  }
  function roundRect(ctx, x, y, w, h, r) {
    var rr = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + rr, y);
    ctx.arcTo(x + w, y, x + w, y + h, rr);
    ctx.arcTo(x + w, y + h, x, y + h, rr);
    ctx.arcTo(x, y + h, x, y, rr);
    ctx.arcTo(x, y, x + w, y, rr);
    ctx.closePath();
  }

  function BroadcastCore(config) {
    var canvas = config.canvas;
    var onText = config.onText || function () { };
    var onStatus = config.onStatus || function () { };
    var onFirstFrame = config.onFirstFrame || function () { };
    var onTransform = config.onTransform || function () { };
    var onSendPacket = config.onSendPacket || null;
    var ctx = canvas.getContext('2d');

    var state = null;
    var chromeJson = '';
    var firstFrameFired = false;
    var rafHandle = null;
    var dirty = false;
    var stopped = false;
    var drawCount = 0;
    var viewportWidth = Number(config.viewportWidth) || 0;
    var viewportHeight = Number(config.viewportHeight) || 0;
    var pixelRatio = Number(config.devicePixelRatio) ||
      (globalScope.devicePixelRatio || 1);
    // Letterbox transform, reported to the page so its click mapping and view
    // controls read one object whether the core runs here or a thread away.
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 1, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };

    loadKit();
    loadSayFace();

    function cssSize() {
      var w = viewportWidth || canvas.width || 1;
      var h = viewportHeight || canvas.height || 1;
      return { w: Math.max(1, w), h: Math.max(1, h) };
    }

    function syncCanvas() {
      var size = cssSize();
      var w = Math.max(1, Math.round(size.w * pixelRatio));
      var h = Math.max(1, Math.round(size.h * pixelRatio));
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
    }

    function boardGeometry() {
      var size = cssSize();
      var bw = state && state.board ? state.board.w : 17;
      var bh = state && state.board ? state.board.h : 9;
      var availW = size.w * pixelRatio;
      var availH = size.h * pixelRatio;
      // The say band is RESERVED whether or not anybody is speaking, so the
      // board does not move when a remark lands and a top-row snake's bubble
      // always has somewhere to go. Its height comes from the cap, and the
      // cap's font comes from the cell, so the fit is taken twice: once to
      // learn the cell, once with the band that cell implies.
      var cell = Math.max(2, Math.floor(Math.min(availW / bw, availH / bh)));
      var band = sayBandFor(cell);
      cell = Math.max(2, Math.floor(
        Math.min(availW / bw, Math.max(1, availH - band) / bh)));
      band = sayBandFor(cell);
      var pxW = cell * bw;
      var pxH = cell * bh;
      var ox = Math.round((availW - pxW) / 2);
      var oy = band + Math.round(Math.max(0, availH - band - pxH) / 2);
      return { cell: cell, ox: ox, oy: oy, w: bw, h: bh, pxW: pxW, pxH: pxH,
               band: band };
    }

    function publishTransform(g) {
      var next = {
        scale: g.cell, offsetX: g.ox, offsetY: g.oy,
        nativeW: g.w, nativeH: g.h,
        zoom: 1, minZoom: 1, maxZoom: 1, fitScale: g.cell,
        focusX: g.w / 2, focusY: g.h / 2, visW: g.w, visH: g.h
      };
      if (next.scale !== transform.scale || next.offsetX !== transform.offsetX ||
          next.offsetY !== transform.offsetY ||
          next.nativeW !== transform.nativeW ||
          next.nativeH !== transform.nativeH) {
        transform = next;
        onTransform(transform);
      }
    }

    // ---- the board ---------------------------------------------------------
    function drawGrid(g) {
      ctx.fillStyle = '#16110d';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      var grad = ctx.createLinearGradient(g.ox, g.oy, g.ox, g.oy + g.pxH);
      grad.addColorStop(0, '#241a12');
      grad.addColorStop(1, '#17110c');
      ctx.fillStyle = grad;
      ctx.fillRect(g.ox, g.oy, g.pxW, g.pxH);
      ctx.strokeStyle = 'rgba(242,232,216,0.07)';
      ctx.lineWidth = Math.max(1, Math.floor(g.cell / 24));
      for (var x = 0; x <= g.w; x++) {
        ctx.beginPath();
        ctx.moveTo(g.ox + x * g.cell, g.oy);
        ctx.lineTo(g.ox + x * g.cell, g.oy + g.pxH);
        ctx.stroke();
      }
      for (var y = 0; y <= g.h; y++) {
        ctx.beginPath();
        ctx.moveTo(g.ox, g.oy + y * g.cell);
        ctx.lineTo(g.ox + g.pxW, g.oy + y * g.cell);
        ctx.stroke();
      }
      // Walls read as a lit border; a torus has none, which is why the geese
      // board draws wrap ghosts instead.
      if (!state.board.wrap) {
        ctx.strokeStyle = 'rgba(232,163,61,0.55)';
        ctx.lineWidth = Math.max(2, Math.floor(g.cell / 8));
        ctx.strokeRect(g.ox - ctx.lineWidth / 2, g.oy - ctx.lineWidth / 2,
          g.pxW + ctx.lineWidth, g.pxH + ctx.lineWidth);
      }
    }

    function drawFood(g) {
      var apple = art['food_apple'];
      for (var i = 0; i < state.food.length; i++) {
        var f = state.food[i];
        var x = g.ox + f[0] * g.cell;
        var y = g.oy + f[1] * g.cell;
        if (apple) {
          ctx.drawImage(apple, x, y, g.cell, g.cell);
        } else {
          ctx.fillStyle = '#e0523a';
          ctx.beginPath();
          ctx.arc(x + g.cell / 2, y + g.cell / 2, g.cell * 0.32, 0,
            Math.PI * 2);
          ctx.fill();
        }
      }
    }

    function pieceFor(snake, index) {
      var body = snake.body;
      if (index === 0) {
        var d = snake.dir >= 0 && snake.dir < 4 ? snake.dir : 0;
        return 'head_' + ['u', 'r', 'd', 'l'][d];
      }
      if (index === body.length - 1 && body.length > 1) return 'tail';
      var prev = body[index - 1];
      var next = body[index + 1];
      if (prev && next && prev[0] !== next[0] && prev[1] !== next[1]) {
        return 'corner';
      }
      return 'body';
    }

    function lerpCell(cur, prev, alpha) {
      if (!prev) return cur;
      var dx = cur[0] - prev[0];
      var dy = cur[1] - prev[1];
      // A wrap step jumps the whole board; snapping is honest there, gliding
      // would invent motion the sim never had.
      if (Math.abs(dx) > 1 || Math.abs(dy) > 1) return cur;
      return [prev[0] + dx * alpha, prev[1] + dy * alpha];
    }

    function drawSegment(g, colour, piece, pos, fade) {
      var img = art['snake_' + colour + '_' + piece];
      var x = g.ox + pos[0] * g.cell;
      var y = g.oy + pos[1] * g.cell;
      if (fade < 1) ctx.globalAlpha = fade;
      if (img) {
        ctx.drawImage(img, x, y, g.cell, g.cell);
      } else {
        var hex = colourHex(colour);
        ctx.fillStyle = piece.indexOf('head') === 0 ? hex : shade(hex, 0.86);
        roundRect(ctx, x + g.cell * 0.06, y + g.cell * 0.06,
          g.cell * 0.88, g.cell * 0.88, g.cell * 0.22);
        ctx.fill();
        ctx.strokeStyle = shade(hex, 0.45);
        ctx.lineWidth = Math.max(1, g.cell / 16);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }

    function drawTrails(g, snake) {
      // tron: the trail is a solid neon wall, because a light cycle IS a wall.
      var hex = colourHex(snake.colour);
      ctx.fillStyle = hex;
      ctx.globalAlpha = 0.85;
      for (var i = 1; i < snake.body.length; i++) {
        var c = snake.body[i];
        ctx.fillRect(g.ox + c[0] * g.cell + g.cell * 0.12,
          g.oy + c[1] * g.cell + g.cell * 0.12,
          g.cell * 0.76, g.cell * 0.76);
      }
      ctx.globalAlpha = 1;
    }

    function drawTrappedRing(g, snake) {
      if (!snake.trapped || !snake.body.length) return;
      var c = snake.body[0];
      ctx.strokeStyle = '#e0523a';
      ctx.lineWidth = Math.max(2, g.cell / 8);
      ctx.beginPath();
      ctx.arc(g.ox + (c[0] + 0.5) * g.cell, g.oy + (c[1] + 0.5) * g.cell,
        g.cell * 0.46, 0, Math.PI * 2);
      ctx.stroke();
    }

    function drawWrapGhosts(g, snake) {
      // On a torus a snake crossing an edge reappears on the far side and a
      // spectator loses it. A dimmed one-cell repeat across the opposite edge
      // says where it is about to come back.
      if (!state.board.wrap || !snake.body.length) return;
      ctx.globalAlpha = 0.28;
      for (var i = 0; i < snake.body.length; i++) {
        var c = snake.body[i];
        var ghosts = [];
        if (c[0] === 0) ghosts.push([g.w, c[1]]);
        if (c[0] === g.w - 1) ghosts.push([-1, c[1]]);
        if (c[1] === 0) ghosts.push([c[0], g.h]);
        if (c[1] === g.h - 1) ghosts.push([c[0], -1]);
        for (var k = 0; k < ghosts.length; k++) {
          drawSegment(g, snake.colour, pieceFor(snake, i), ghosts[k], 1);
        }
      }
      ctx.globalAlpha = 1;
    }

    function drawSnakes(g, alpha) {
      for (var s = 0; s < state.snakes.length; s++) {
        var snake = state.snakes[s];
        if (!snake.alive) {
          if (snake.died && snake.prev && snake.prev.length) {
            var wreck = art['wreck'];
            for (var w = 0; w < snake.prev.length; w++) {
              var p = snake.prev[w];
              var x = g.ox + p[0] * g.cell;
              var y = g.oy + p[1] * g.cell;
              ctx.globalAlpha = 0.75 * (1 - alpha);
              if (wreck) ctx.drawImage(wreck, x, y, g.cell, g.cell);
              else {
                ctx.fillStyle = '#6b6157';
                ctx.fillRect(x + 2, y + 2, g.cell - 4, g.cell - 4);
              }
              ctx.globalAlpha = 1;
            }
          }
          continue;
        }
        if (state.board.trail) {
          drawTrails(g, snake);
          drawSegment(g, snake.colour, pieceFor(snake, 0),
            lerpCell(snake.body[0], snake.prev[0], alpha), 1);
        } else {
          for (var i = snake.body.length - 1; i >= 0; i--) {
            var prevPos = snake.prev[Math.min(i, snake.prev.length - 1)];
            var pos = i === 0 ? lerpCell(snake.body[0], snake.prev[0], alpha)
              : snake.body[i];
            var grown = snake.ate && i === snake.body.length - 1;
            drawSegment(g, snake.colour, pieceFor(snake, i), pos,
              grown ? 0.55 + 0.45 * alpha : 1);
            if (prevPos === undefined) prevPos = pos;
          }
        }
        drawWrapGhosts(g, snake);
        drawTrappedRing(g, snake);
      }
    }

    function drawFlashes(g, alpha) {
      for (var i = 0; i < state.flashes.length; i++) {
        var f = state.flashes[i];
        var cx = g.ox + (f.x + 0.5) * g.cell;
        var cy = g.oy + (f.y + 0.5) * g.cell;
        // A head-on is the game's most brutal rule; it must not be a silent
        // disappearance.
        ctx.strokeStyle = f.k === 'headon' ? '#f2e8d8' : '#e8a33d';
        ctx.globalAlpha = Math.max(0, 1 - alpha);
        ctx.lineWidth = Math.max(2, g.cell / 6);
        ctx.beginPath();
        ctx.arc(cx, cy, g.cell * (0.3 + 0.5 * alpha), 0, Math.PI * 2);
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }

    function sayBoxWidth(font) {
      // Measured ONCE per font size, in the face the text is drawn in, from a
      // full-cap sample -- so the box is the same for every remark and the
      // widest legal remark still fits inside it.
      if (sayCapWidths[font] === undefined) {
        var was = ctx.font;
        ctx.font = font + 'px ' + SAY_FACE;
        sayCapWidths[font] = Math.ceil(
          ctx.measureText(SAY_CAP_SAMPLE).width + font);
        ctx.font = was;
      }
      return sayCapWidths[font];
    }

    function drawBubbles(g) {
      if (!state.bubbles.length) return;
      // The font is the cell's, floored at 9 px, and then shrunk if a full-cap
      // remark would not fit the board at that size: the STRING is never
      // shortened to fit the box (a clipped sentence is the defect; a smaller
      // sentence is not).
      var font = sayFontFor(g.cell);
      while (font > 9 && sayBoxWidth(font) > g.pxW - 4) font -= 1;
      var w = Math.min(sayBoxWidth(font), Math.max(16, g.pxW - 4));
      var h = font * 1.8;
      ctx.font = font + 'px ' + SAY_FACE;
      ctx.textBaseline = 'middle';
      for (var i = 0; i < state.bubbles.length; i++) {
        var b = state.bubbles[i];
        var text = String(b.text || '');
        if (!text) continue;
        // The box is laid out from the server's own cap on this string and
        // then CLAMPED INSIDE THE CANVAS, so a bubble on a top-row snake is
        // never drawn at a negative y (the cogchemists 2026-08-24 scar): it
        // rides the reserved band above the board instead.
        var x = g.ox + (b.x + 0.5) * g.cell - w / 2;
        var y = g.oy + b.y * g.cell - h - 2;
        if (x < 2) x = 2;
        if (x + w > canvas.width - 2) x = canvas.width - w - 2;
        if (y < 2) y = 2;
        if (y + h > canvas.height - 2) y = canvas.height - h - 2;
        ctx.fillStyle = 'rgba(20,14,9,0.86)';
        roundRect(ctx, x, y, w, h, h / 3);
        ctx.fill();
        ctx.strokeStyle = colourHex(
          (state.snakes[b.slot] && state.snakes[b.slot].colour) || 'amber');
        ctx.lineWidth = 1.5;
        ctx.stroke();
        ctx.fillStyle = '#f2e8d8';
        ctx.textAlign = 'center';
        ctx.fillText(text, x + w / 2, y + h / 2);
      }
      ctx.textAlign = 'left';
    }

    function draw() {
      if (!state) return;
      syncCanvas();
      var g = boardGeometry();
      publishTransform(g);
      var alpha = Math.max(0, Math.min(1, (state.alpha || 0) / 1000));
      drawGrid(g);
      drawFood(g);
      drawSnakes(g, alpha);
      drawFlashes(g, alpha);
      drawBubbles(g);
      drawCount++;
      if (!firstFrameFired) {
        firstFrameFired = true;
        onStatus('live');
        onFirstFrame();
      }
    }

    function scheduleDraw() {
      if (dirty || stopped) return;
      dirty = true;
      rafHandle = requestFrame(function () {
        dirty = false;
        rafHandle = null;
        try { draw(); } catch (e) { onStatus('error'); throw e; }
      });
    }

    function ingest(bytes) {
      var text = typeof bytes === 'string'
        ? bytes : textDecoder.decode(bytes);
      var packet = JSON.parse(text);
      state = packet;
      if (!state.snakes) state.snakes = [];
      if (!state.food) state.food = [];
      if (!state.bubbles) state.bubbles = [];
      if (!state.flashes) state.flashes = [];
      var chrome = JSON.stringify(packet.chrome || {});
      if (chrome !== chromeJson) {
        chromeJson = chrome;
        onText(chrome);
      }
      draw();
    }

    return {
      ingest: ingest,
      start: function () { onStatus('connecting'); scheduleDraw(); },
      stop: function () {
        stopped = true;
        if (rafHandle) cancelFrame(rafHandle);
      },
      sendCommand: function (text) {
        if (onSendPacket) {
          onSendPacket(new TextEncoder().encode(String(text)));
        }
      },
      clickMap: function () { },
      setViewportSize: function (w, h, dpr) {
        viewportWidth = Number(w) || viewportWidth;
        viewportHeight = Number(h) || viewportHeight;
        pixelRatio = Number(dpr) || pixelRatio;
        scheduleDraw();
      },
      setViewportFit: function () { scheduleDraw(); },
      getTransform: function () { return transform; },
      // The zoom bar and the minimap (#viewpanel) are DROPPED for this game --
      // markup, CSS, wiring and stubs. All three boards are small fixed
      // rectangles that relayout() letterboxes whole at every width, so there
      // is nothing to pan to and nothing to shrink into a minimap. The
      // no-op stubs are gone too: a method that exists and does nothing is
      // indistinguishable from one that works.
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: 0, interval: 1000 / 24,
          draws: drawCount };
      }
    };
  }

  globalScope.BroadcastCore = {
    create: function (config) { return BroadcastCore(config); }
  };
})();
