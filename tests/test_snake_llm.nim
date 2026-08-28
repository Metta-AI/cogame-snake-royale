## The LLM transport is the starter's, kept function for function, with only
## the SystemPrompt replaced -- and the decision layer batches all four seats
## in ONE parallel batch per turn.

import std/[os, strutils]
import snake/[sim, sim_types, llm, decide, directives, baselines]
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

c.report()
