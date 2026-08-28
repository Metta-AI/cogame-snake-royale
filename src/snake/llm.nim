## Claude-backed snake command. A policy is just a prompt: the game server
## composes the seat's whole-board view plus that seat's PLAYER_PROMPT and
## asks Claude which direction that snake takes this turn.
##
## Forked STRUCTURALLY VERBATIM from `coworld-ctf`'s `src/ctf/llm.nim`: the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures. Only the
## `SystemPrompt*` const is replaced (design note §Sim module -> Kept).
##
## Snake Royale is a SIMULTANEOUS-decision game, so ALL FOUR seats' calls go
## out as ONE parallel batch per turn (`curly.makeRequests`). Seats are never
## queried sequentially: that is what keeps 50 turns inside the wall-clock
## budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils, unicode],
  curly,
  runtime, sim_types, directives

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again (paintball round 2, 2026-08-25).

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "snake-royale llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call.
  ##
  ## `us.anthropic.claude-sonnet-4-6` was never a candidate (cogame-raid round
  ## 2, 2026-08-23) and `us.anthropic.claude-sonnet-4-5-20250929-v1:0` is not
  ## one either: it was the ladder fallback for paintball 0.1.2 and the hosted
  ## round-2 game log recorded 133 calls to it, every single one returning
  ## "Timeout was reached" and none returning text. One haiku throttle then
  ## cascaded into a whole episode of scripted fallbacks — the retry is what
  ## burned the turn, not the throttle. With no second candidate a throttle
  ## fails fast (see LlmClient.throttled) and the seat plays the scripted
  ## fallback for that turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "snake-royale llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "snake-royale llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "snake-royale llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" below: "LLM provider is unavailable".
    echo "snake-royale llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are one snake in a four-snake free-for-all on a rectangular grid. Every turn all four
snakes move ONE cell at the same time; nobody sees anybody else's move before it happens.
You choose one direction per turn and nothing else.
Coordinates are [x, y] with x growing RIGHT and y growing DOWN, so "up" is y-1, "down" is
y+1, "left" is x-1, "right" is x+1, and [0,0] is the top-left cell.
Your body is a list of cells, head first. Each turn your head enters the cell you chose and
your tail leaves its cell, so your length is unchanged unless you eat. Eating food adds one
segment and refills your health.
You die if your head leaves the board (unless this board wraps), or enters ANY snake's body
including your own, or if your health reaches zero. If two heads enter the same cell, this
board's rule decides it: "longer_wins" means the strictly longer snake lives and the rest
die; "both_die" means everyone in that cell dies. Equal lengths always all die.
You may not move into your own neck, the cell directly behind your head. If you name it
anyway the game silently uses your "alt", then your last direction.
The whole board is visible to you. The `moves` list has already been computed by the SAME
code that resolves the turn: for each of the four directions it gives the target cell,
whether it is off the board, whose body is in it, whether food is there, how many free cells
you could still reach from it, and whether a head-on there would be a win, a tie or a loss
for you. Trust it. A `free_space` smaller than your own length means you are sealing
yourself in and will die inside your own coil.
The winner is the LAST SNAKE ALIVE. Placement pays +1.000, +0.333, -0.333, -1.000 and the
four scores always sum to zero, so outliving one more snake is worth as much as anything
else you can do. Ties in survival are broken by length, then by food eaten.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"dir":"up|down|left|right",
 "alt":"up|down|left|right",
 "say":"<=24 chars, PUBLIC - every snake reads it next turn",
 "notes":"<=160 chars, private, handed back to you next turn"}
"dir" is your move. "alt" is used only if "dir" is your neck. "say" is broadcast to all four
snakes and drawn on the replay: it is the only channel you have, and everyone, including the
snake you are about to seal in, reads it.
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## view. The view is built server-side from the seat's fog (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson
