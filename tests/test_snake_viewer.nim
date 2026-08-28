## The viewer's provenance and its 360 px rules. Static assertions over the
## committed chrome; the bundle is EXECUTED by ci.yml's wasm-viewer job.

import std/[os, sets, strutils]
import helpers

proc fnv1a64(text: string): uint64 =
  ## A dependency-free content digest. std/sha1 moved out of the standard
  ## library in Nim 2, and pinning a byte-for-byte copy must not depend on a
  ## package that may or may not be synced.
  result = 0xcbf29ce484222325'u64
  for ch in text:
    result = result xor uint64(ord(ch))
    result = result * 0x100000001b3'u64

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
  c.check(fnv1a64(chrome) == 0xd26e0d29ae78e8f6'u64,
    "39: chrome_common.js digest matches the starter's (got 0x" &
    toHex(fnv1a64(chrome)) & ")")
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
