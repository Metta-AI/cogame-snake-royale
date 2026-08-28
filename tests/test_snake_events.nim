## The event vocabulary is a CLOSED enum of sixteen kinds, the beat kinds are
## exactly seven of them, and every kind the appended viewer block consumes is
## in the set.

import std/[sets, strutils]
import snake/[rules, events, sim, sim_types, baselines, engine]
import helpers

var c = newChecker("test_snake_events")

# The closed enum.
var declared = initHashSet[string]()
for kind in EventKind:
  declared.incl($kind)
let expected = toHashSet(["gamestart", "spawn", "turn", "move", "say", "eat",
  "foodspawn", "shrink", "headon", "death", "trapped", "decline", "duel",
  "fallback", "gameover", "end"])
c.check(declared == expected,
  "the emitted set is exactly the sixteen documented kinds; extra=" &
  $(declared - expected) & " missing=" & $(expected - declared))
c.check(AllEventKinds.len == 16, "sixteen kinds are listed")

# Beats are exactly seven of them.
var beats = initHashSet[string]()
for kind in BeatKinds:
  beats.incl($kind)
c.check(beats == toHashSet(["eat", "headon", "death", "trapped", "duel",
  "fallback", "gameover"]), "the beat kinds are the documented seven")
for kind in ["gamestart", "spawn", "turn", "move", "say", "foodspawn",
             "shrink", "decline", "end"]:
  var found = false
  for b in BeatKinds:
    if $b == kind: found = true
  c.check(not found, kind & " never makes a beat")

# Everything a real episode emits is in the set.
block:
  var config = defaultGameConfig()
  config.seed = 42
  config.maxTurns = 40
  let played = runScriptedEpisode(config, certificationSeats())
  for e in played.events:
    c.check($e.kind in expected, "a real episode emitted " & $e.kind)
  let jsonl = eventsJsonl(played.events, played.episode.turnsPlayed,
    GameVersion)
  c.check(jsonl.endsWith("\n"), "the JSON-lines stream ends in a newline")
  c.check("\"type\":\"summary\"" in jsonl,
    "and carries the mandatory trailing summary row")
  c.check("\"gameVersion\"" in jsonl, "with the game version in it")

# Every kind the appended viewer block consumes is in the set.
block:
  let page = readFile("client/replay_broadcast.html")
  let banner = page.find("SNAKE-ROYALE additions")
  let blockText = page[banner .. ^1]
  for kind in ["eat", "headon", "death", "trapped", "duel", "fallback",
               "gameover"]:
    c.check(("beat-marker." & kind) in blockText,
      "the block styles the emitted kind " & kind)

c.report()
