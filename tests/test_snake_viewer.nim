## The viewer's provenance and its 360 px rules. Static assertions over the
## committed chrome; the bundle is EXECUTED by ci.yml's wasm-viewer job.

import std/[os, sets, strutils]
import helpers

const Sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr32(x: uint32, n: int): uint32 = (x shr n) or (x shl (32 - n))

proc sha256Hex(data: string): string =
  ## SHA-256, written out here on purpose. The design note pins the starter's
  ## `chrome_common.js` by its SHA-256, and std/sha1 moved out of the standard
  ## library in Nim 2: a byte-for-byte provenance pin must not depend on a
  ## package that may or may not be synced, so the digest is computed rather
  ## than imported. Cross-checked against `sha256sum` / python hashlib.
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg = data
  let bits = uint64(data.len) * 8'u64
  msg.add('\x80')
  while msg.len mod 64 != 56:
    msg.add('\0')
  for i in countdown(7, 0):
    msg.add(char((bits shr (8 * i)) and 0xFF'u64))
  var at = 0
  while at < msg.len:
    var w: array[64, uint32]
    for i in 0 ..< 16:
      w[i] = (uint32(uint8(msg[at + i * 4])) shl 24) or
             (uint32(uint8(msg[at + i * 4 + 1])) shl 16) or
             (uint32(uint8(msg[at + i * 4 + 2])) shl 8) or
              uint32(uint8(msg[at + i * 4 + 3]))
    for i in 16 ..< 64:
      let s0 = rotr32(w[i - 15], 7) xor rotr32(w[i - 15], 18) xor
        (w[i - 15] shr 3)
      let s1 = rotr32(w[i - 2], 17) xor rotr32(w[i - 2], 19) xor
        (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var
      a = h[0]
      b = h[1]
      c = h[2]
      d = h[3]
      e = h[4]
      f = h[5]
      g = h[6]
      k = h[7]
    for i in 0 ..< 64:
      let s1 = rotr32(e, 6) xor rotr32(e, 11) xor rotr32(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = k + s1 + ch + Sha256K[i] + w[i]
      let s0 = rotr32(a, 2) xor rotr32(a, 13) xor rotr32(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      k = g; g = f; f = e; e = d + t1
      d = c; c = b; b = a; a = t1 + t2
    h[0] = h[0] + a; h[1] = h[1] + b; h[2] = h[2] + c; h[3] = h[3] + d
    h[4] = h[4] + e; h[5] = h[5] + f; h[6] = h[6] + g; h[7] = h[7] + k
    at = at + 64
  result = ""
  for v in h:
    result.add(toHex(v, 8).toLowerAscii())

var c = newChecker("test_snake_viewer")

let page = readFile("client/replay_broadcast.html")
let core = readFile("client/broadcast_core.js")
let chrome = readFile("client/chrome_common.js")

# 39 -- chrome_common.js is byte-identical to the starter's.
block:
  ## Pinned by size and digest: the starter ships 40 022 bytes and this fork
  ## must not have touched a single one of them. Everything this game adds
  ## lives in the appended game block.
  c.check(chrome.len == 40022,
    "39: chrome_common.js is the starter's 40022 bytes (got " &
    $chrome.len & ")")
  c.check(sha256Hex("abc") ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "39: (the digest function itself is the real SHA-256)")
  c.check(sha256Hex(chrome) ==
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c",
    "39: chrome_common.js sha256 matches the starter's (got " &
    sha256Hex(chrome) & ")")
  for kept in ["markBeat", "renderBeatMarkers", "ingestBeats", "renderClock",
               "renderTransport", "ingestLullSpans", "renderMomentum"]:
    c.check(("function " & kept) in chrome, "39: " & kept & " survives")

# 40 -- the page is the starter's, plus an appended block.
block:
  c.check("SNAKE-ROYALE additions to the inherited coworld-ctf chrome" in page,
    "40: the appended block carries its banner")
  let banner = page.find("SNAKE-ROYALE additions")
  for inherited in ["#viewport", "#stage", "#board", "#lightpool", "#grain",
                    "#lockerroom", "#chrome", "#scorebug", "#bannerlane",
                    "#killfeed", "#mmwarn", "#transport", "#scrub",
                    "#endcard", "#status"]:
    c.check(page.find(inherited) < banner,
      "40: " & inherited & " is inherited, not re-declared in the block")
  for kept in ["id=\"plates-l\"", "id=\"plates-r\"", "id=\"clock\"",
               "id=\"clock-time\"", "id=\"clock-caption\"", "id=\"ffwd-mini\"",
               "id=\"btn-restart\"", "id=\"btn-back\"", "id=\"btn-play\"",
               "id=\"btn-fwd\"", "id=\"btn-end\"", "id=\"btn-loop\"",
               "id=\"btn-skip\"", "id=\"btn-spoilers\"", "id=\"ffwd-chip\"",
               "id=\"win-chip\"", "id=\"tick-clock\"", "id=\"speedchips\"",
               "id=\"momentum\"", "id=\"scrub-fill\"", "id=\"lulls\"",
               "id=\"scrub-win\"", "id=\"scrub-head\"", "id=\"ec-headline\"",
               "id=\"ec-wincond\"", "id=\"ec-how\"", "id=\"ec-teams\"",
               "id=\"ec-replay\"", "id=\"lk-bg\"", "id=\"lk-art\"",
               "id=\"lk-sprites\"", "id=\"lk-cap\""]:
    c.check(kept in page, "40: the starter element " & kept & " is kept")
  c.check("window.SnakeChrome" in page and "install(" in page,
    "40: the block installs through the starter's own splice hook")
  c.check("PB_CTX" in page, "40: with the starter's PB_CTX contents")
  c.check("pushFeed: pushFeed" in page, "40: including pushFeed")
  c.check("function pushFeed(row) {" in page,
    "40: pushFeed keeps the starter's one-argument signature")
  ## The INHERITED HEAD -- everything above the banner -- is pinned by sha256
  ## and by byte length. Provenance against coworld-ctf itself is reproduced
  ## mechanically by scripts/build_replay_page.py (the starter is not in the
  ## CI image, so it cannot be diffed here); this pin is what makes an
  ## UNRECORDED edit to the inherited page fail the build. Move it only with
  ## the design-note entry that explains the edit.
  let head = page[0 ..< banner]
  c.check(head.len == 84746,
    "40: the inherited head is 84746 bytes (got " & $head.len & ")")
  c.check(sha256Hex(head) ==
    "5f36436b64a6982e132e0abb7cc616f5ae4d5a9ff8a00fd47db6b4009d2ef6dc",
    "40: and its sha256 is pinned (got " & sha256Hex(head) & ")")
  ## `pushFeed` by BODY, not by name: the cogball 0.1.4 latch scar was a
  ## signature drift that threw mid-replay and latched static_replay.js into
  ## `failed`, and a body that grows a second argument is the same bug.
  let feedAt = page.find("  function pushFeed(row) {")
  let feedEnd = page.find("\n  }\n", feedAt)
  c.check(feedAt > 0 and feedEnd > feedAt, "40: pushFeed's body is findable")
  let pushFeedBody = page[feedAt .. feedEnd + 4]
  c.check(pushFeedBody.len == 691,
    "40: pushFeed's body is the starter's 691 bytes (got " &
    $pushFeedBody.len & ")")
  c.check(sha256Hex(pushFeedBody) ==
    "f57de7ceb58cc687a9a28537f4df549d940b102bf58cc60e0411eef4f184ee5f",
    "40: byte-identical to the starter's (got " & sha256Hex(pushFeedBody) & ")")
  ## The renderer's kept procs, by the same rule: the factory name, the
  ## method surface the shell calls and the frame-packet ingest.
  for kept in ["window.BroadcastCore", "function ingest(bytes)",
               "setViewportSize:", "setViewportFit:", "getTransform:",
               "getPaceStats:", "sendCommand:", "function syncCanvas()",
               "function boardGeometry()", "function publishTransform(g)"]:
    c.check(kept in core, "40: broadcast_core.js keeps " & kept)

# 41 -- no shadowed chrome aliases.
block:
  ## chrome_common.js's alias list is hoisted into the driver as
  ## `var markBeat = C.markBeat, ...`. A game-block FUNCTION of the same name
  ## would shadow it and render unlabelled div markers that never seek.
  let banner = page.find("SNAKE-ROYALE additions")
  let appended = page[banner .. ^1]
  for alias in ["markBeat", "killMarkerTeam", "renderBeatMarkers", "teamCol",
                "activeTeams", "teamOf", "rosterName", "renderClock",
                "renderTransport", "ingestBeats", "ingestLullSpans",
                "renderMomentum", "recordMomentum", "setVerdict", "esc",
                "fmt", "togglePov", "getSpoilers", "setSpoilers"]:
    c.check(("function " & alias & "(") notin appended,
      "41: the game block does not shadow " & alias)
  c.check("function snakeBeat(" in appended, "41: the beat builder is snakeBeat")
  c.check("markBeat(" notin appended,
    "41: the game block never calls markBeat")

# 42 -- beat CSS matches emitted kinds exactly.
block:
  var declared = initHashSet[string]()
  var index = 0
  while true:
    let at = page.find(".beat-marker.", index)
    if at < 0: break
    var stop = at + len(".beat-marker.")
    while stop < page.len and page[stop] in {'a' .. 'z'}:
      inc stop
    declared.incl(page[at + len(".beat-marker.") ..< stop])
    index = stop
  let emitted = toHashSet(["eat", "headon", "death", "trapped", "duel",
                           "fallback", "gameover"])
  c.check(declared == emitted,
    "42: .beat-marker rules are exactly the emitted kinds; extra=" &
    $(declared - emitted) & " missing=" & $(emitted - declared))

# 43 -- transport, endcard and the 360 px rules.
block:
  c.check("#endcard {" in page and "bottom: var(--band, 0px)" in page,
    "43: the endcard stops at var(--band)")
  c.check("classList.remove('on')" in page,
    "43: and every seek dismisses it")
  c.check("root.style.setProperty('--hudscale'" in page,
    "43: relayout() sets --hudscale on :root")
  c.check("root.style.setProperty('--topband'" in page,
    "43: and --topband")
  c.check("root.style.setProperty('--band'" in page, "43: and --band")
  c.check("stage.classList.toggle('tiny', boardW <= 620)" in page,
    "43: and toggles .tiny under 620 px")
  # The four 360 px rules.
  c.check("flex: 1 1 auto;" in page and "min-width: 3.2em;" in page,
    "43: rule 1 -- .plate-name grows, shrinks and keeps a 3.2em floor")
  c.check("@media (max-width: 640px)" in page,
    "43: labels are hidden under 640 px")
  c.check("#stage.tiny .plate .len-label" in page,
    "43: rule 2 -- under .tiny a plate keeps chip + name + length")
  c.check("#stage.tiny .plate .hpbar" in page,
    "43: the health bar becomes an underline on the chip")
  c.check("#stage.tiny #momentum" in page,
    "43: rule 4 -- the ribbon halves in height under .tiny")
  c.check("#stage.tiny #killfeed .feed-row:nth-child(n+4)" in page,
    "43: and the feed shows three rows instead of four")
  c.check("Math.max(9, Math.round(cell * 0.42))" in core,
    "43: rule 3 -- the say bubble has a 9 px font floor")
  c.check("if (y < 2) y = 2;" in core,
    "43: and is clamped inside the canvas, never at a negative y")
  ## The band is sized from the SERVER's cap, measured in the face it is drawn
  ## in, and reserved whether or not anybody is speaking.
  c.check("WIRE.maxSayRunes" in core,
    "43: the bubble reads the server's own say cap")
  c.check("new Array(MAX_SAY_RUNES + 1).join('W')" in core,
    "43: and measures a FULL-CAP sample, not the string in flight")
  c.check("ctx.measureText(SAY_CAP_SAMPLE)" in core,
    "43: in the font it will be drawn in")
  c.check("function sayBandFor(cell)" in core and "band: band" in core,
    "43: and the band is reserved in the layout")
  c.check("oy = band +" in core,
    "43: so the board sits below it whether or not anybody is speaking")
  # The removed ids appear nowhere but in the removal note.
  let banner = page.find("SNAKE-ROYALE additions")
  let body = page[0 ..< banner]
  for gone in ["id=\"viewpanel\"", "id=\"minimap\"", "id=\"zoombar\"",
               "id=\"zoom-in\"", "id=\"zoom-out\"", "id=\"zoom-slider\"",
               "id=\"zoom-read\"", "id=\"fpv\"", "id=\"fpv-canvas\"",
               "id=\"povBadge\"", "id=\"minimap-canvas\""]:
    c.check(gone notin body, "43: " & gone & " is gone")
  c.check("attachMinimap(" notin body,
    "43: and nothing calls attachMinimap")
  ## #viewpanel is dropped ENTIRELY, not hidden: the residual no-op stubs and
  ## the shell's minimap transfer are gone too. A method that exists and does
  ## nothing is indistinguishable from one that works.
  let shell = readFile("replay-viewer/static_replay.js")
  let worker = readFile("replay-viewer/static_replay_worker.js")
  for gone in ["zoomAt", "setZoom", "panBy", "panByMap", "panTo",
               "resetView", "attachMinimap", "transferControlToOffscreen()"]:
    c.check(gone notin core,
      "43: the renderer carries no " & gone & " stub")
  for gone in ["attachMinimap", "pendingMinimap", "sendMinimap",
               "'minimap'", "action === 'zoom'"]:
    c.check(gone notin shell and gone notin worker,
      "43: and neither shell nor worker still wires " & gone)
  ## What the shell DOES keep: the board canvas transfer and the API the page
  ## really calls.
  c.check("canvas.transferControlToOffscreen()" in shell,
    "43: the board canvas is still handed to the worker")
  for kept in ["sendCommand:", "setViewportFit:", "getTransform:",
               "clickMap:", "start:", "stop:"]:
    c.check(kept in shell, "43: the shell keeps " & kept)
  # No game-block element is positioned inside the transport band.
  let blockText = page[banner .. ^1]
  c.check("#transport" notin blockText,
    "43: the game block never touches the transport band")

# The renderer is the shipped one, and it draws every readout the design names.
block:
  for fn in ["function drawGrid", "function drawSnakes", "function drawFood",
             "function drawTrails", "function drawWrapGhosts",
             "function drawTrappedRing", "function drawBubbles",
             "function drawFlashes"]:
    c.check(fn in core, "the renderer ships " & fn)
  c.check("window.BroadcastCore" in core,
    "and keeps the starter's factory name")
  c.check("SNAKE_WIRE" in core, "and reads window.SNAKE_WIRE")
  c.check("CTF_WIRE" notin core, "the CTF_WIRE name is gone")

# 48 -- the renderer fixture really drives the readouts it claims to cover.
block:
  ## The bundle draws in a Worker on an OffscreenCanvas, where
  ## viewer_smoke.mjs's main-thread canvas patch cannot see a single
  ## `fillText`: the fixture is the ONLY text-bounds coverage, so what it
  ## drives is load-bearing. It used to hand the chrome `roster: []`,
  ## `beats: []`, `lead.pts: []` and `duel: -1`, which exercised none of the
  ## scorebug, the beat markers, the ribbon or the duel banner.
  let fixture = readFile("tools/ci/renderer_fixture.html")
  let workflow = readFile(".github/workflows/ci.yml")
  c.check("window.SNAKE_DRIVE_FRAME = onFrame;" in page,
    "48: the page publishes its frame path for the fixture")
  c.check("win.SNAKE_DRIVE_FRAME" in fixture,
    "48: and the fixture drives the page's own frame path")
  for driven in ["roster: roster(seats)", "beats: beats()", "pts: leadPts()",
                 "duel: DUEL", "results: over ? results() : null"]:
    c.check(driven in fixture,
      "48: the fixture drives real chrome data (" & driven & ")")
  for kind in ["'eat'", "'trapped'", "'headon'", "'fallback'", "'death'",
               "'duel'", "'gameover'"]:
    c.check("k: " & kind in fixture,
      "48: and a beat of every emitted kind (" & kind & ")")
  for asserted in ["plates, not 4", "beat markers, not",
                   "the length ribbon drew nothing",
                   "the match feed drew no rows",
                   "the duel banner never fired",
                   "the endcard stayed up after a seek"]:
    c.check(asserted in fixture,
      "48: and fails the step when a readout is missing (" & asserted & ")")
  c.check("fixture/viewer-smoke.json" in workflow,
    "48: and ci.yml uploads the fixture's own evidence, not just the log line")
  c.check("--strict-text-bounds" in workflow,
    "48: with the text-bounds gate on")

c.report()
