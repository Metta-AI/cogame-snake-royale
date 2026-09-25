## The snake-royale player container: scripted, prompt, or external policy.
##
## Prompt decisions run inside the game, where the platform supplies its LLM
## secret. External policies receive the seat view and return a direction over
## the same ordinary player socket.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      coil | forager               -> this seat is scripted
##   PLAYER_NUMERIC_URL   a frozen Fabric choice endpoint
##   PLAYER_JEV           1 to choose through System One
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `coil`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy <snake-royale-image> --name my-snake \
##     --run /bin/snake-royale-player --secret-env PLAYER_PROMPT="<strategy>"

import std/[json, options, os, random, strutils, times, unicode]
import whisky
import snake/numeric_policy
import snake/jev_policy

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24
  ReconnectAttempts = 6
  MaxPromptRunes = 4000

proc truncateRunes(text: string, limit: int): string =
  if limit <= 0: return ""
  if text.runeLen <= limit: return text
  text.runeSubStr(0, limit)

proc registrationBlob(prompt, scripted, policy: string,
                      external: bool): string =
  ## The one registration message. `scripted` is JSON null when the seat is an
  ## LLM seat, so the server can tell "no baseline named" from "coil named
  ## explicitly".
  var node = %*{
    "type": "register",
    "prompt": prompt.truncateRunes(MaxPromptRunes),
    "policy": policy
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  if external:
    node["mode"] = %"external"
  $node

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    numeric = getEnv("PLAYER_NUMERIC_URL").strip().len > 0
    jev = getEnv("PLAYER_JEV") == "1"
    external = numeric or jev
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif numeric: "numeric"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "coil"
  echo "snake-royale player: kind=",
    (if external: "external" elif prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "coil"),
    " label=", label
  if external and (prompt.len > 0 or scripted.len > 0) or numeric and jev:
    quit("Choose exactly one player policy mode", 1)
  randomize()
  let session = "snake:" & $getCurrentProcessId() & ":" &
    $getTime().toUnix() & ":" & $rand(high(int))

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The episode runner starts the players at the same
    ## instant as the game, so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "snake-royale player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("snake-royale player: game never accepted a connection", 1)
  echo "snake-royale player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame
  # or a truncated read (only a timeout returns none), and the game's own
  # quit(0) can outrun the flushed final frame. A naive player exits 1 on that
  # race and fails certification intermittently (the raid 0.1.3 scar). Exiting
  # 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE: a seat whose slot is not the next
  # open one may register before it has an index (the paintball round-3 scar).
  var reconnects = 0
  var done = false
  while not done:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label, external), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if "\"final\"" in received.get.data:
          done = true
          break
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label, external), BinaryMessage)
        if external and received.get().kind == TextMessage:
          let request = parseJson(received.get().data)
          if request{"type"}.getStr() == "decision":
            let choice = if jev: chooseJevDirection(request)
              else: chooseNumericDirection(request, session)
            socket.send($( %*{"type": "order", "turn": request["turn"],
              "choice": choice}), TextMessage)
    except CatchableError as error:
      echo "snake-royale player: socket closed (", error.msg, ")"
    if done:
      break
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "snake-royale player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "snake-royale player: game is no longer listening, exiting cleanly"
      break
    echo "snake-royale player: reconnected, re-registering"
  quit(0)
