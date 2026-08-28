## The LLM transport is the starter's, kept function for function, with only
## the SystemPrompt replaced -- and the decision layer batches all four seats
## in ONE parallel batch per turn.

import std/[os, strutils]
import snake/[sim, sim_types, llm, decide, directives, baselines, server]
import helpers

var c = newChecker("test_snake_llm")

# With no credentials at all the client disables itself INSTANTLY, with no
# network wait, which is what lets offline certification finish in seconds.
block:
  delEnv("ANTHROPIC_API_KEY")
  delEnv("ANTHROPIC_API_KEY_URI")
  delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
  delEnv("AWS_BEARER_TOKEN_BEDROCK")
  let client = newLlmClient(defaultGameConfig())
  c.check(client.disabled, "no credentials disables the client")
  c.check(client.transport == ltNone, "and the transport is none")

# The system prompt is the only game-specific text in the transport module.
block:
  c.check("four-snake free-for-all" in SystemPrompt,
    "the system prompt describes THIS game")
  c.check("Your reply MUST begin with '{'" in SystemPrompt,
    "and forces JSON (Haiku answers prose-first otherwise)")
  c.check("\"dir\":\"up|down|left|right\"" in SystemPrompt,
    "and states the schema")
  c.check("x growing RIGHT and y growing DOWN" in SystemPrompt,
    "and the coordinate system")
  c.check("moves" in SystemPrompt,
    "and points at the precomputed legal choice set")
  c.check("paintball" notin SystemPrompt and "hill" notin SystemPrompt,
    "and carries none of the starter's game")

# The operator block wraps the seat's own PLAYER_PROMPT and is rune-capped.
block:
  var long = ""
  for _ in 0 ..< MaxPromptRunes + 100:
    long.add("x")
  let wrapped = operatorBlock(long)
  c.check("GUIDANCE FROM YOUR OPERATOR" in wrapped, "the operator heading")
  c.check(wrapped.count('x') == MaxPromptRunes,
    "and the prompt is truncated to the cap (got " & $wrapped.count('x') & ")")
  c.check(operatorBlock("").len == 0, "an empty prompt adds nothing")

# The cadence constants are the design note's.
block:
  let config = defaultGameConfig()
  c.check(config.attempt1Ms == 6000, "attempt1Ms 6000")
  c.check(config.retryMs == 3000, "retryMs 3000")
  c.check(config.turnBudgetMs == 11000, "turnBudgetMs 11000")
  c.check(config.turnSpacingMs == 9000, "turnSpacingMs 9000")
  c.check(config.wallClockBudgetSeconds == 640, "wallClockBudgetSeconds 640")
  c.check(config.lobbyJoinTimeoutSeconds == 90, "lobbyJoinTimeoutSeconds 90")
  ## The whole-second rule: curly hands the deadline to CURLOPT_TIMEOUT.
  c.check(config.attempt1Ms mod 1000 == 0 and config.retryMs mod 1000 == 0,
    "the deadlines are whole seconds")
  ## Four seats at 60/9 seconds is 26.7 requests a minute, inside the
  ## sidecar's 30-per-minute per-episode cap.
  c.check(Seats * 60000 div config.turnSpacingMs <= 30,
    "four seats stay inside the sidecar's rate cap")
  ## The worst case settles inside 60 % of episodeTimeoutSeconds (720 s).
  c.check(50 * config.turnBudgetMs div 1000 + 50 <= 720,
    "the worst case fits the 720 s play budget")
  c.check(config.wallClockBudgetSeconds <= 720,
    "and the engine's own stop is inside it")
  ## THE WHOLE ENVELOPE, out loud. The episode clock starts above the lobby
  ## (server.nim), so `wallClockBudgetSeconds` covers the lobby AND the loop;
  ## what can still be added after it is the turn already in flight when the
  ## stop fires, the display hold, and the shutdown grace.
  block:
    let worst = config.wallClockBudgetSeconds +
      (config.turnBudgetMs + 999) div 1000 +
      (config.gameOverTurns * 250 + 999) div 1000 +
      ShutdownGraceSeconds
    c.check(worst <= 720,
      "lobby + loop + the turn in flight + the hold + the grace fits 720 s (" &
      $worst & " s)")
    c.check(config.lobbyJoinTimeoutSeconds < config.wallClockBudgetSeconds,
      "and the lobby cannot eat the whole budget on its own")
    let source = readFile("src/snake/server.nim")
    let clockAt = source.find("let started = getMonoTime()")
    let lobbyAt = source.find("waitForLobby(config)")
    c.check(clockAt > 0 and lobbyAt > 0, "both the clock and the lobby exist")
    c.check(clockAt < lobbyAt,
      "the episode clock starts ABOVE the lobby, so the budget covers it")
    let holdAt = source.find("sleep(max(0, config.gameOverTurns) * 250)")
    let writeAt = source.find("writeCogameUri(rt.resultsUri")
    c.check(holdAt > 0 and writeAt > 0, "the hold and the write both exist")
    c.check(holdAt < writeAt,
      "and the display hold runs BEFORE the artifacts are written")
  ## The per-turn budget is a cap on the CALLS -- attempt 1 plus the single
  ## retry plus slack -- so it must be able to hold both attempts.
  c.check(config.turnBudgetMs >= config.attempt1Ms + config.retryMs,
    "the turn budget covers attempt 1 AND the retry")

# The turn budget covers the calls, not the rate floor in front of them.
block:
  ## The retry is unconditional (design note D3), so the clock the deadline
  ## check reads must START AT THE FIRST REQUEST, below the `turnSpacingMs`
  ## sleep. Started above it, the sleep -- 9 s minus the previous turn's
  ## latency -- ate the budget, leaving exactly attempt 1's own 6 s in steady
  ## state and pre-empting the retry batch.
  let source = readFile("src/snake/decide.nim")
  let floorAt = source.find("if since < episode.config.turnSpacingMs:")
  let clockAt = source.find("let turnStart = getMonoTime()")
  let deadlineAt = source.find("if getMonoTime() - turnStart >= budget:")
  c.check(floorAt > 0 and clockAt > 0 and deadlineAt > 0,
    "the rate floor, the turn clock and the deadline check are all present")
  c.check(clockAt > floorAt,
    "the turn budget clock starts BELOW the rate floor's sleep")
  c.check(deadlineAt > clockAt, "and the deadline check reads it")
  ## And a config that could not hold both attempts is repaired.
  var narrow = defaultGameConfig()
  narrow.update("""{"turnBudgetMs": 6000}""")
  c.check(narrow.turnBudgetMs == narrow.attempt1Ms + narrow.retryMs,
    "a turn budget too small for attempt 1 + retry is repaired (got " &
    $narrow.turnBudgetMs & ")")

# sim_config REJECTS a sub-second deadline.
block:
  var config = defaultGameConfig()
  var raised = false
  try:
    config.update("""{"attempt1Ms": 4500}""")
  except SnakeError:
    raised = true
  c.check(raised, "a sub-second attempt1Ms is rejected, not silently floored")

# ONE parallel batch per turn: the loop issues at most two batches (attempt +
# retry) and never queries seats sequentially.
block:
  let source = readFile("src/snake/decide.nim")
  c.check("makeRequests(" in source,
    "the turn loop uses curly's parallel batch API")
  c.check("while open.len > 0 and attempt < 2:" in source,
    "at most two batches per turn")
  c.check("batch.post(" in source, "every open seat is posted into ONE batch")
  c.check("falling back" in source,
    "the exact phrase phase 60 greps the game log for")
  c.check("will retry" in source,
    "and attempt 1 says `will retry`, never `falling back`")

# A fallback is EMITTED as an event on the live path too, not only recorded.
block:
  ## With no credentials every LLM seat falls back every turn. The record is
  ## what phase 60 counts; the EVENT is what reaches the tier-2 stream and the
  ## match feed, and there was no code path constructing one.
  var config = defaultGameConfig()
  config.turnSpacingMs = 0
  var episode = newEpisode(config)
  var engine = initDecisionEngine(config)
  engine.seats[0].isLlm = true
  engine.seats[0].prompt = "take the most open lane"
  let records = engine.turn(episode, 0)
  var recorded = 0
  for record in records:
    if "\"k\":\"fallback\"" in record: inc recorded
  c.check(recorded >= 1, "the fallback is recorded for the replay")
  var events = 0
  for e in engine.events:
    if e.kind == ekFallback and e.slot == 0:
      inc events
      c.check(e.text == "no_credentials", "and the event carries the cause")
      c.check(e.turn == episode.state.turn + 1, "and the turn")
  c.check(events == 1,
    "and exactly one fallback EVENT is emitted (got " & $events & ")")
  c.check(engine.haveOrder[0] and episode.seats[0].fallbackTurns == 1,
    "and the seat still has a legal order")

c.report()
