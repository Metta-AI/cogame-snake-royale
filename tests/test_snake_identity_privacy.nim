## Two name spaces, kept apart. No real policy name may appear in any
## observation JSON, any prompt or any board label; the aliases are the only
## names an agent ever sees.

import std/[json, strutils]
import snake/[rules, sim, sim_types, baselines, engine, decide, records]
import helpers

var c = newChecker("test_snake_identity_privacy")

var config = defaultGameConfig()
config.seed = 42
config.maxTurns = 20
config.playerNames = @["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]

var episode = newEpisode(config)
for slot in 0 ..< Seats:
  episode.seats[slot].notes = "my own private note"
  episode.seats[slot].say = "north lane is mine"
  episode.seats[slot].sayTurnsLeft = 2

for slot in 0 ..< Seats:
  let view = episode.seatViewJson(slot)
  for other in 0 ..< Seats:
    c.check(episode.seats[other].name notin view,
      "the real name " & episode.seats[other].name & " never reaches a seat")
  c.check(cogAlias(slot) in view, "the seat's own alias is there")
  ## The other seats' notes are never in an observation.
  let node = parseJson(view)
  c.check(node{"your_notes"}.getStr() == "my own private note",
    "your_notes is the seat's OWN previous note")
  c.check(view.count("my own private note") == 1,
    "and no other seat's note is in it")
  ## spawnDeal is never in an observation.
  c.check("spawnDeal" notin view, "spawnDeal is hidden")
  ## No pending direction for this turn.
  c.check("\"pending\"" notin view, "no seat's pending direction is in it")

# The register record is REDACTED: the prompt is never written.
block:
  let record = registerRecord(0, cogAlias(0), episode.colour(0),
    "strangler", "llm", "coil")
  c.check("strangler" in record, "the policy LABEL is recorded")
  c.check("PLAYER_PROMPT" notin record and "Win by shrinking" notin record,
    "the prompt is never written to the replay")

# showPlayerLabels is false in every shipped variant, so no on-board label can
# leak an identity.
block:
  let m = parseJson(readFile("coworld_manifest_template.json"))
  for variant in m{"variants"}:
    c.check(variant{"game_config"}{"showPlayerLabels"}.getBool() == false,
      variant{"id"}.getStr() & ": showPlayerLabels is false")
  c.check(m{"certification"}{"game_config"}{"showPlayerLabels"}.getBool() == false,
    "certification: showPlayerLabels is false")

# The results document is where the real names live -- spectator side only.
block:
  let played = runScriptedEpisode(config, certificationSeats())
  let results = parseJson(played.episode.snakeResultsJson())
  c.check(results{"names"}[0].getStr() == "daveey",
    "results.names carries the real policy names")
  c.check(results{"aliases"}[0].getStr() == "COG-alpha",
    "and results.aliases carries the in-game aliases")

c.report()
