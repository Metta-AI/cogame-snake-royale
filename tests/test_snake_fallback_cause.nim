## Preserve the actual failed call in the final replay/live fallback event.
import std/[json, os]
import snake/[decide, events, sim, sim_types]

putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:1")
var config = defaultGameConfig()
config.turnSpacingMs = 0
var episode = newEpisode(config)
var engine = initDecisionEngine(config)
engine.seats[0].isLlm = true
engine.seats[0].prompt = "choose a legal direction"
let records = engine.turn(episode, 0)
var failures = 0
for record in records:
  let row = parseJson(record)
  if row["k"].getStr() == "fallback":
    doAssert row["cause"].getStr() == "transport_error"
    inc failures
doAssert failures == 3 # Two connection attempts and the final fallback.
doAssert episode.seats[0].fallbackTurns == 1
for event in engine.events:
  if event.kind == ekFallback:
    doAssert event.text == "transport_error"
delEnv("COWORLD_LLM_ENDPOINT")
echo "fallback retains transport failure cause"
