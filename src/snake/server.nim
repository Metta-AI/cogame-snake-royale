## The game server: the Coworld contract, the lobby, the turn loop and the
## artifact writes.
##
## Forked from `coworld-ctf`'s `src/ctf/server.nim` with three named edits
## (design note §Sim module -> The named edits):
##
## 1. The tick loop is a TURN loop: one decision round plus one `resolveTurn`
##    per iteration, `fastMode` always on, no frame pacing.
##    `maxTicks` / `gameOverTicks` / `lobbyJoinTimeoutTicks` are `maxTurns` /
##    `gameOverTurns` / `lobbyJoinTimeoutSeconds` -- the last in SECONDS,
##    because a `fastMode` turn has no wall-clock meaning.
## 2. The wall-clock check at the top of the loop is kept as-is, reading
##    `wallClockBudgetSeconds`.
## 3. The certifier's browser probes stay registered BEFORE any catch-all
##    asset route and keep answering for a bounded grace after the artifacts
##    are written: `GET /client/player?slot=&token=` (token-checked, and it
##    must NOT open the player socket -- the flatland 0.1.1 scar),
##    `GET /client/global`, the `/global` websocket's first message, and
##    `/healthz` (the lantern 0.1.1 and 0.1.3 scars). Global broadcasts are
##    fire-and-forget so a slow viewer can never stall the episode.

import std/[json, locks, monotimes, nativesockets, os, strutils, times]
import mummy, mummy/routers
import board, rules, sim, sim_types, directives, decide, records, baselines,
       control, replays, replay_runtime, broadcast, global, events, labels,
       runtime, wire_constants

type
  Registration = object
    prompt: string
    scripted: string
    policy: string
    seen: bool

  SharedState = object
    episode: Episode
    registrations: array[Seats, Registration]
    joined: array[Seats, bool]
    playing: bool
    finished: bool

var
  stateLock: Lock
  shared: SharedState
  playerSockets: seq[tuple[ws: WebSocket, slot: int]]
  globalSockets: seq[WebSocket]
  socketLock: Lock
  httpServer: Server
  serveThread: Thread[tuple[host: string, port: int]]

initLock(stateLock)
initLock(socketLock)

const
  AssetRoot = "."
  ClientRoot = "client"

const
  ShutdownGraceSeconds* = 20
    ## `/healthz` and `/global` keep answering this long after the artifacts
    ## are written; the episode runner waits on process exit anyway.
  StartupGraceMs* = 200
    ## The listen socket is up before the lobby opens.

proc contentTypeFor(path: string): string =
  let dot = path.rfind('.')
  if dot < 0:
    return "application/octet-stream"
  case path[dot .. ^1].toLowerAscii()
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".webp": "image/webp"
  of ".ttf": "font/ttf"
  else: "application/octet-stream"

proc jsonHeaders(): HttpHeaders =
  result["content-type"] = "application/json"
  result["cache-control"] = "no-store"

proc textHeaders(kind: string): HttpHeaders =
  result["content-type"] = kind
  result["cache-control"] = "no-store"

proc readClientPage(name: string): string =
  let path = ClientRoot / name
  if not fileExists(path):
    return "<!doctype html><html><head><meta charset=\"utf-8\">" &
      "<title>snake-royale</title></head><body>snake-royale</body></html>"
  spliceWireConstants(readFile(path))

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------

proc queryValue(request: Request, key: string): string =
  request.queryParams[key]

proc handleHealth(request: Request) {.gcsafe.} =
  request.respond(200, jsonHeaders(), "{\"ok\":true}")

proc handleClientPlayer(request: Request) {.gcsafe.} =
  ## The certifier probes this route with a good token and a bad one BEFORE
  ## any player pod starts. It serves a real page and it NEVER opens the
  ## player socket.
  let
    slotText = request.queryValue("slot")
    token = request.queryValue("token")
  var slot = -1
  try:
    slot = parseInt(slotText.strip())
  except CatchableError:
    slot = -1
  var expected = ""
  {.cast(gcsafe).}:
    withLock stateLock:
      if slot >= 0 and slot < Seats:
        expected = shared.episode.seats[slot].token
  if slot < 0 or slot >= Seats:
    request.respond(400, textHeaders("text/plain; charset=utf-8"),
      "unknown slot")
    return
  if expected.len > 0 and token != expected:
    request.respond(403, textHeaders("text/plain; charset=utf-8"),
      "bad player token")
    return
  request.respond(200, textHeaders("text/html; charset=utf-8"),
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>" &
    "snake-royale seat " & $slot & "</title></head><body>" &
    "<h1>snake-royale</h1><p>Seat " & $slot & " is driven by the game " &
    "server. This page is the seat's status view; it opens no socket.</p>" &
    "</body></html>")

proc handleClientGlobal(request: Request) {.gcsafe.} =
  request.respond(200, textHeaders("text/html; charset=utf-8"),
    readClientPage("replay_broadcast.html"))

proc handleClientReplay(request: Request) {.gcsafe.} =
  ## LOCAL developer replay mode only. This route is NEVER declared to the
  ## platform: the hosted viewer is the static wasm bundle.
  request.respond(200, textHeaders("text/html; charset=utf-8"),
    readClientPage("replay_broadcast.html"))

proc handleAsset(request: Request) {.gcsafe.} =
  var rel = request.path
  while rel.len > 0 and rel[0] == '/':
    rel = rel[1 .. ^1]
  if rel.len == 0:
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      readClientPage("replay_broadcast.html"))
    return
  if ".." in rel:
    request.respond(404, textHeaders("text/plain; charset=utf-8"), "no")
    return
  for root in [ClientRoot, AssetRoot / "data", AssetRoot]:
    let path = root / rel
    if fileExists(path):
      request.respond(200, textHeaders(contentTypeFor(rel)), readFile(path))
      return
  request.respond(404, textHeaders("text/plain; charset=utf-8"), "not found")

# ---------------------------------------------------------------------------
#  WebSockets
# ---------------------------------------------------------------------------

proc handleUpgrade(request: Request) {.gcsafe.} =
  let isPlayer = request.path == "/player"
  var slot = -1
  if isPlayer:
    let token = request.queryValue("token")
    try:
      slot = parseInt(request.queryValue("slot").strip())
    except CatchableError:
      slot = -1
    var expected = ""
    {.cast(gcsafe).}:
      withLock stateLock:
        if slot >= 0 and slot < Seats:
          expected = shared.episode.seats[slot].token
    if slot < 0 or slot >= Seats or (expected.len > 0 and token != expected):
      ## A bad player token must be REFUSED, not accepted: the certifier
      ## probes with a wrong token and fails the episode if it is admitted.
      request.respond(403, textHeaders("text/plain; charset=utf-8"),
        "bad player token")
      return
  var socket: WebSocket
  try:
    socket = request.upgradeToWebSocket()
  except CatchableError:
    return
  {.cast(gcsafe).}:
    withLock socketLock:
      if isPlayer:
        playerSockets.add((socket, slot))
      else:
        globalSockets.add(socket)

proc applyRegistration(slot: int, payload: string) =
  var node: JsonNode
  try:
    node = parseJson(payload)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  withLock stateLock:
    shared.registrations[slot].prompt =
      node{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
    shared.registrations[slot].scripted = node{"scripted"}.getStr()
    shared.registrations[slot].policy =
      node{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
    shared.registrations[slot].seen = true
    shared.joined[slot] = true

proc websocketHandler(socket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  {.cast(gcsafe).}:
    var slot = -1
    withLock socketLock:
      for entry in playerSockets:
        if entry.ws == socket:
          slot = entry.slot
          break
    case event
    of OpenEvent:
      if slot >= 0:
        withLock stateLock:
          shared.joined[slot] = true
        socket.send("{\"type\":\"hello\",\"slot\":" & $slot & "}")
      else:
        ## The certifier reads the FIRST message on `/global` and pings it
        ## afterwards; answer immediately.
        var body = ""
        withLock stateLock:
          body = liveStateJson(shared.episode, shared.playing)
        socket.send(body)
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings `/global` to check the
      ## game is alive, so an unanswered ping fails certification with
      ## `game_contract_violation`.
      ## Registration frames arrive as BinaryMessage (see
      ## `src/snake_royale_player.nim`), so only Ping is filtered out here.
      if message.kind == Ping:
        socket.send(message.data, Pong)
        return
      if slot >= 0 and message.data.len > 0:
        applyRegistration(slot, message.data)
    of CloseEvent, ErrorEvent:
      withLock socketLock:
        var keptPlayers: seq[tuple[ws: WebSocket, slot: int]]
        for entry in playerSockets:
          if not (entry.ws == socket):
            keptPlayers.add(entry)
        playerSockets = keptPlayers
        var keptGlobals: seq[WebSocket]
        for s in globalSockets:
          if not (s == socket):
            keptGlobals.add(s)
        globalSockets = keptGlobals

proc broadcastLive() =
  ## Fire and forget: `send` only QUEUES, so a slow viewer can never stall the
  ## episode.
  {.cast(gcsafe).}:
    var body = ""
    withLock stateLock:
      body = liveStateJson(shared.episode, shared.playing)
    withLock socketLock:
      for s in globalSockets:
        s.send(body)
      for entry in playerSockets:
        entry.ws.send(body)

proc sendFinal() =
  {.cast(gcsafe).}:
    withLock socketLock:
      for entry in playerSockets:
        entry.ws.send("{\"type\":\"final\"}")
      for s in globalSockets:
        s.send("{\"type\":\"final\"}")

proc buildRouter(): Router =
  ## Registered BEFORE any catch-all asset route.
  result.get("/healthz", handleHealth)
  result.get("/client/player", handleClientPlayer)
  result.get("/client/global", handleClientGlobal)
  result.get("/client/replay", handleClientReplay)
  result.get("/player", handleUpgrade)
  result.get("/global", handleUpgrade)
  result.get("/**", handleAsset)

proc serveLoop(args: tuple[host: string, port: int]) {.thread.} =
  {.cast(gcsafe).}:
    httpServer.serve(Port(args.port), args.host)

# ---------------------------------------------------------------------------
#  The episode
# ---------------------------------------------------------------------------

proc waitForLobby(config: GameConfig) =
  let deadline = getMonoTime() +
    initDuration(seconds = config.lobbyJoinTimeoutSeconds)
  while getMonoTime() < deadline:
    var joined = 0
    withLock stateLock:
      for slot in 0 ..< Seats:
        if shared.registrations[slot].seen:
          inc joined
    if joined >= min(Seats, config.minPlayers):
      return
    sleep(100)

proc runEpisode*(host: string, port: int, config: GameConfig,
                 rt: RuntimeConfig) =
  withLock stateLock:
    shared.episode = newEpisode(config)
    shared.playing = false

  httpServer = newServer(buildRouter().toHandler(), websocketHandler)
  createThread(serveThread, serveLoop, (host: host, port: port))
  echo "snake-royale listening on ", host, ":", port
  sleep(StartupGraceMs)

  ## THE EPISODE CLOCK STARTS HERE, above the lobby -- the platform charges
  ## from pod start, so `wallClockBudgetSeconds` has to cover the lobby too.
  ## Started below `waitForLobby` it measured the loop alone, and the worst
  ## case became lobbyJoinTimeoutSeconds (90) + the whole 640 s budget + the
  ## turn in flight + the shutdown grace = ~720 s, i.e. exactly the 60 % of
  ## episodeTimeoutSeconds the design note plays inside, with nothing spare.
  ## Covering the lobby puts the worst case at ~672 s
  ## (tests/test_snake_llm.nim does the arithmetic).
  let started = getMonoTime()

  waitForLobby(config)

  var
    engine = initDecisionEngine(config)
    replay = Replay(gameName: GameName, gameVersion: GameVersion)
    allEvents: seq[TurnEvent]
    directiveEvents: seq[DirectiveEvent]
    episode: Episode

  withLock stateLock:
    episode = shared.episode
  allEvents = episode.events

  # Install the registrations. A seat with no register record is logged
  # LOUDLY and flagged `deadSeats` (the grf-football 2026-08-27 scar: a lost
  # register packet silently demoted a champion to the default script for a
  # whole episode).
  for slot in 0 ..< Seats:
    var reg: Registration
    withLock stateLock:
      reg = shared.registrations[slot]
    if not reg.seen:
      echo "ERROR: seat ", slot, UnregisteredSeatLog
      episode.seats[slot].dead = true
      engine.seats[slot].isLlm = false
      engine.seats[slot].baseline = blCoil
      engine.seats[slot].label = "coil"
    else:
      engine.seats[slot].registered = true
      engine.seats[slot].prompt = reg.prompt
      engine.seats[slot].isLlm = reg.prompt.len > 0
      engine.seats[slot].baseline = parseBaseline(reg.scripted)
      engine.seats[slot].label =
        if reg.policy.len > 0: reg.policy
        elif reg.prompt.len > 0: "prompt"
        else: $engine.seats[slot].baseline
    episode.seats[slot].policyKind = engine.policyKind(slot)
    episode.seats[slot].policyLabel = engine.seats[slot].label
    episode.seats[slot].baseline = $engine.seats[slot].baseline
    replay.joins.add((slot, episode.seats[slot].name,
      episode.seats[slot].token))
    replay.chats.add(registerRecord(slot, cogAlias(slot), episode.colour(slot),
      engine.seats[slot].label, episode.seats[slot].policyKind,
      $engine.seats[slot].baseline))

  replay.configJson = replayConfigJson(episode)

  withLock stateLock:
    shared.episode = episode
    shared.playing = true
  broadcastLive()

  var
    endRule = erFullTime
    reason = rsComplete
    stopDetail = ""
    stopRecorded = false

  try:
    while true:
      let elapsed = (getMonoTime() - started).inSeconds.int
      if elapsed >= config.wallClockBudgetSeconds:
        endRule = erWallClock
        reason = rsDeadline
        replay.chats.add(stopRecord(episode.state.turn, $endRule))
        stopRecorded = true
        break
      if episode.state.aliveCount() <= 1:
        endRule = erLastStanding
        break
      if episode.state.turn >= config.maxTurns:
        endRule = erFullTime
        break

      let records = engine.turn(episode, elapsed)
      for record in records:
        replay.chats.add(record)
      ## A fallback is a fact about the transport, not about the board, so the
      ## sim cannot derive it: the decision layer emits the events and they
      ## join the episode's stream here.
      allEvents.add(engine.events)

      var
        dirs: array[Seats, Dir]
        alts: array[Seats, tuple[has: bool, dir: Dir]]
        bytes: array[Seats, uint8]
      for slot in 0 ..< Seats:
        if not episode.state.snakes[slot].alive:
          bytes[slot] = DeadDirByte
          dirs[slot] = episode.state.snakes[slot].lastDir
          continue
        let order = engine.orders[slot]
        dirs[slot] = order.dir
        alts[slot] = (order.hasAlt, order.alt)
        episode.seats[slot].notes = order.notes
        if order.say.len > 0:
          episode.seats[slot].say = order.say
          episode.seats[slot].sayTurnsLeft = max(1, config.sayTurns)
          inc episode.seats[slot].saidTurns
        elif episode.seats[slot].sayTurnsLeft > 0:
          dec episode.seats[slot].sayTurnsLeft
        replay.chats.add(boundedDirectiveRecord(order, episode.state.turn + 1,
          slot, cogAlias(slot), ""))
        ## The tier-2 stream's `directive` row: a fact about the DECISION, so
        ## no board event carries it.
        directiveEvents.add(DirectiveEvent(turn: episode.state.turn + 1,
          slot: slot, alias: cogAlias(slot), source: $order.source,
          dir: $order.dir, latencyMs: order.latencyMs,
          repaired: order.repaired))

      let before = episode.state
      var turnEvents = resolveTurn(episode.state, dirs, alts)
      turnEvents.add(auditDeclinedKills(episode.state, before, dirs))
      allEvents.add(turnEvents)
      for slot in 0 ..< Seats:
        bytes[slot] =
          if before.snakes[slot].alive: uint8(ord(dirs[slot]))
          else: DeadDirByte
      replay.turns.add(ReplayTurn(dirs: bytes, hash: episode.state.gameHash))
      episode.turnsPlayed = episode.state.turn

      withLock stateLock:
        shared.episode = episode
      broadcastLive()
  except CatchableError as error:
    reason = rsFault
    endRule = erSimFault
    stopDetail = error.msg
    if not stopRecorded:
      replay.chats.add(stopRecord(episode.state.turn, $endRule))
    echo "snake-royale: sim fault, settling from the last completed turn: ",
      error.msg

  episode.turnsPlayed = episode.state.turn
  for slot in 0 ..< Seats:
    if episode.state.snakes[slot].alive:
      episode.state.snakes[slot].survivedTurns = episode.turnsPlayed
  episode.settle(reason, endRule, stopDetail)
  allEvents.add(TurnEvent(kind: ekGameOver, turn: episode.turnsPlayed,
    slot: -1, other: -1, text: $endRule))
  allEvents.add(TurnEvent(kind: ekEnd, turn: episode.turnsPlayed, slot: -1,
    other: -1, text: $reason))
  replay.chats.add(resultRecord(episode))

  withLock stateLock:
    shared.episode = episode
    shared.playing = false
    shared.finished = true
  broadcastLive()

  # The display hold, THEN the artifacts (design note §End conditions:
  # `complete` "settles after the gameOverTurns display hold, then writes
  # artifacts"). Both are bounded and the whole post-settle tail is
  # gameOverTurns * 250 ms + the write + ShutdownGraceSeconds.
  sleep(max(0, config.gameOverTurns) * 250)

  # Artifacts.
  writeCogameUri(rt.resultsUri, "COGAME_RESULTS_URI",
    episode.snakeResultsJson())
  writeCogameUri(rt.replayUri, "COGAME_SAVE_REPLAY_URI", encodeReplay(replay))
  if rt.eventsUri.len > 0:
    writeCogameUri(rt.eventsUri, "COGAME_EVENTS_URI",
      eventsJsonl(allEvents, episode.turnsPlayed, GameVersion,
                  directiveEvents))
  var missing: seq[int]
  for slot in 0 ..< Seats:
    if episode.seats[slot].dead:
      missing.add(slot)
  if missing.len > 0 and rt.failureUri.len > 0:
    writeCogameUri(rt.failureUri, "COGAME_PLAYER_FAILURE_URI",
      playerFailureJson(missing[0]))

  echo "snake-royale: episode ", $reason, " (", $endRule, ") after ",
    episode.turnsPlayed, " turns"
  sendFinal()

  # A bounded shutdown grace in which `/healthz` and `/global` keep answering
  # (the lantern 0.1.3 scar).
  let graceUntil = getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
  while getMonoTime() < graceUntil:
    sleep(250)
  httpServer.close()

proc runLocalReplay*(host: string, port: int, bytes: string) =
  ## The local developer replay route. Never declared to the platform.
  var rt = loadReplay(bytes)
  echo "snake-royale: local replay, ", rt.replay.turns.len, " turns, ",
    "mismatch at ", rt.mismatchTurn
  discard framePacket(rt)
  httpServer = newServer(buildRouter().toHandler(), websocketHandler)
  httpServer.serve(Port(port), host)