## The manifest pins. Every one of these is a platform rejection that repo CI
## would otherwise not catch until phase 40.

import std/[json, sets, strutils]
import snake/[rules, sim_config, sim_types]
import helpers

var c = newChecker("test_snake_manifest")
let m = parseJson(readFile("coworld_manifest_template.json"))

# num_agents in EVERY variant's game_config AND in the cert fixture, and never
# at a variant's top level (CoworldVariant is additionalProperties:false).
c.check(m{"variants"}.len == 3, "three variants ship in v1")
for variant in m{"variants"}:
  let id = variant{"id"}.getStr()
  let gc = variant{"game_config"}
  c.check(gc{"num_agents"}.getInt() == 4, id & ": num_agents 4 in game_config")
  c.check(variant{"num_agents"}.isNil, id & ": num_agents NOT at variant level")
  c.check(gc{"tokens"}.isNil, id & ": no literal tokens in game_config")
  c.check(gc{"slots"}.isNil, id & ": no slots in game_config")
  c.check(variant{"description"}.getStr().len > 40, id & ": has a description")
  c.check(variant{"name"}.getStr().len > 0, id & ": has a name")
  c.check(gc{"wallClockBudgetSeconds"}.getInt() <= 640, id & ": budget <= 640 s")
  c.check(gc{"maxTurns"}.getInt() <= 60, id & ": maxTurns <= 60")
  c.check(gc{"players"}.len == 4, id & ": four named players")
  ## the variant really constructs the module it names
  var config = defaultGameConfig()
  config.update($gc)
  let built = rulesFromConfig(config)
  c.check(built.name == id, id & ": constructs the module it names")
  c.check(built.board.w == gc{"boardW"}.getInt(), id & ": board width")
  c.check(built.board.h == gc{"boardH"}.getInt(), id & ": board height")
  c.check(built.board.wrap == gc{"wrap"}.getBool(), id & ": wrap")
  c.check(built.foodCount == gc{"foodCount"}.getInt(), id & ": foodCount")
  c.check(built.headToHead == (if gc{"headToHead"}.getStr() == "both_die":
    hhBothDie else: hhLongerWins), id & ": headToHead")

let cert = m{"certification"}
c.check(cert{"game_config"}{"num_agents"}.getInt() == 4,
  "num_agents 4 in certification.game_config")
c.check(cert{"players"}.len == 4, "certification seats four players")
c.check(cert{"game_config"}{"players"}.len == 4,
  "certification.game_config names four players")
c.check(cert{"game_config"}{"tokens"}.isNil,
  "no runner-managed tokens in the cert fixture")

# Every declared player occupies a certification slot (the raid 0.1.2 scar).
c.check(m{"player"}.len == 2, "two bundled players")
var seated = initHashSet[string]()
for entry in cert{"players"}:
  seated.incl(entry{"player_id"}.getStr())
for entry in m{"player"}:
  let id = entry{"id"}.getStr()
  c.check(id in seated, "player " & id & " occupies a certification slot")
  c.check(entry{"resources"}{"limits"}{"cpu"}.getStr() == "1",
    "player " & id & ": limits.cpu is at least 1")
  c.check(entry{"description"}.getStr().len > 0, "player " & id & " described")
  c.check(entry{"source_url"}.getStr().len > 0, "player " & id & " sourced")
  c.check(entry{"type"}.getStr() == "player", "player " & id & " typed")

# config_schema: a real JSON Schema, closed, with bounds on every array.
let schema = m{"game"}{"config_schema"}
c.check(schema{"additionalProperties"}.getBool() == false,
  "config_schema is closed")
var required = initHashSet[string]()
for r in schema{"required"}:
  required.incl(r.getStr())
c.check("tokens" in required and "players" in required,
  "config_schema requires tokens and players")
for name, prop in schema{"properties"}:
  if prop{"type"}.getStr() == "array":
    c.check(not prop{"minItems"}.isNil and not prop{"maxItems"}.isNil,
      "config_schema." & name & " declares minItems/maxItems")
c.check(schema{"properties"}{"num_agents"}{"minimum"}.getInt() == 4 and
  schema{"properties"}{"num_agents"}{"maximum"}.getInt() == 4,
  "num_agents is pinned at 4")
var moduleEnum = initHashSet[string]()
for v in schema{"properties"}{"module"}{"enum"}:
  moduleEnum.incl(v.getStr())
c.check(moduleEnum == toHashSet(["royale", "geese", "tron"]),
  "module enum is the three shipped modules")

# results_schema is closed and exactly the documented keys.
let results = m{"game"}{"results_schema"}
c.check(results{"additionalProperties"}.getBool() == false,
  "results_schema is closed")
var reasons = initHashSet[string]()
for v in results{"properties"}{"reason"}{"enum"}:
  reasons.incl(v.getStr())
c.check(reasons == toHashSet(["complete", "deadline", "fault"]),
  "reason is a closed three-value enum")
var endRules = initHashSet[string]()
for v in results{"properties"}{"endRule"}{"enum"}:
  endRules.incl(v.getStr())
c.check(endRules == toHashSet(["last_standing", "full_time", "wall_clock",
  "sim_fault", "host_error"]), "endRule is the closed five-value enum")

# Top-level shape.
c.check(not m{"$schema"}.isNil, "$schema is present")
c.check(m{"tags"}.len >= 3, "at least three top-level tags")
c.check(m{"game"}{"tags"}.isNil, "game.tags must NOT exist")
c.check(m{"episode_timeout_minutes"}.getInt() == 20,
  "episode_timeout_minutes is top level")
c.check(m{"version"}.isNil, "no top-level version")
c.check(m{"game"}{"display_name"}.isNil, "no game.display_name")
c.check(m{"game"}{"description"}.getStr().len > 0, "game.description present")
c.check(m{"game"}{"owner"}.getStr().len > 0, "game.owner present")
c.check(m{"game"}{"name"}.getStr() == "snake-royale", "game.name is the slug")
c.check(m{"game"}{"runnable"}{"type"}.getStr() == "game",
  "game.runnable.type is game")
c.check(m{"game"}{"runnable"}{"image"}.getStr() == "{{SNAKE_ROYALE_IMAGE}}",
  "the image placeholder is derived from the compose service name")
c.check(m{"game"}{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
  "secret://coworld/snake-royale/anthropic_api_key",
  "the secret namespace equals game.name")
c.check(m{"game"}{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer",
  "the replay viewer is the STATIC bundle, under game")
c.check(m{"replay_viewer"}.isNil, "and not at the top level")

# protocols: BOTH player and global, as objects, never bare strings.
for stream in ["player", "global"]:
  let node = m{"game"}{"protocols"}{stream}
  c.check(node.kind == JObject, "protocols." & stream & " is an object")
  c.check(node{"type"}.getStr().len > 0 and node{"value"}.getStr().len > 0,
    "protocols." & stream & " carries type and value")

# docs: an inlined readme plus three pages.
let docs = m{"game"}{"docs"}
c.check(docs{"readme"}{"type"}.getStr() == "text" and
  docs{"readme"}{"value"}.getStr().len > 200, "docs.readme is inlined text")
c.check(docs{"pages"}.len == 3, "three doc pages")
for page in docs{"pages"}:
  c.check(page{"id"}.getStr().len > 0, "every page has an id")
  c.check(page{"title"}.getStr().len > 0, "every page has a title")
  c.check(page{"content"}{"type"}.getStr() == "text" and
    page{"content"}{"value"}.getStr().len > 100,
    "every page has non-empty inlined text")

# The compose service name is what the placeholder is derived from.
let compose = readFile("compose.yaml")
c.check("snake-royale:" in compose, "compose declares the snake-royale service")
c.check("image: coworld-snake-royale:latest" in compose,
  "and the image the manifest placeholder maps to")
c.check("platform: linux/amd64" in compose, "platform: linux/amd64")
c.check("network: host" in compose, "build network: host")

# The policy set: two PLAYER_PROMPT champions plus two scripted baselines, all
# from the same image, env-switched; champion #2 carries the daveey-1 player.
let policies = parseJson(readFile("tools/ci/policies.json"))
c.check(policies.len == 4, "four policies")
var prompts = 0
var scripted = 0
for policy in policies:
  c.check(policy{"run"}.getStr() == "/bin/snake-royale-player",
    "every policy runs the seat registrar")
  c.check(policy{"name"}.getStr().startsWith("snake-royale-"),
    "every policy is namespaced by the slug")
  c.check(policy{"env"}{"USE_BEDROCK"}.isNil,
    "no USE_BEDROCK: the LLM call is made by the GAME pod")
  if not policy{"env"}{"PLAYER_PROMPT"}.isNil:
    inc prompts
    c.check(policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 400,
      "a champion's whole strategy is its prompt")
  if not policy{"env"}{"PLAYER_SCRIPTED"}.isNil:
    inc scripted
    c.check(policy{"env"}{"PLAYER_SCRIPTED"}.getStr() in ["coil", "forager"],
      "a filler names a shipped baseline")
c.check(prompts == 2, "two LLM prompt champions")
c.check(scripted == 2, "two scripted baselines")
c.check(policies[1]{"player"}.getStr() == "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
  "champion #2 is uploaded as daveey-1")

c.report()
