## The event vocabulary is a CLOSED enum of sixteen kinds, the beat kinds are
## exactly seven of them, and every kind the appended viewer block consumes is
## in the set.

import std/[json, sets, strutils]
import snake/[rules, events, sim, sim_types, baselines, engine, labels,
              records, replays, replay_runtime]
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

# `fallback` is EMITTED, not merely declared: a recorded fallback comes back
# as a real event on playback, and drives the beat and the feed row.
block:
  var config = defaultGameConfig()
  config.seed = 42
  config.maxTurns = 40
  var played = runScriptedEpisode(config, certificationSeats())
  var replay = played.replay
  ## Two records for one seat-turn -- attempt 1 and the retry -- which is what
  ## the decision layer really writes; they are ONE missed call.
  replay.chats.add(fallbackRecord(3, 1, 1, "timeout", "attempt 1 timed out"))
  replay.chats.add(fallbackRecord(3, 1, 2, "timeout", "fell back to coil"))
  var rt = loadReplay(encodeReplay(replay))
  var emitted: seq[TurnEvent]
  for e in rt.events:
    if e.kind == ekFallback:
      emitted.add(e)
  c.check(emitted.len == 1,
    "one fallback record pair is one fallback event (got " &
    $emitted.len & ")")
  if emitted.len == 1:
    c.check(emitted[0].turn == 3 and emitted[0].slot == 1,
      "and it names the turn and the seat")
    c.check(emitted[0].text == "timeout", "and carries the cause")
    c.check(feedRow(rt.episode, emitted[0]) ==
      cogAlias(1) & " MISSED THE CALL — coil move (timeout)",
      "and the feed row the design note prints is reachable at last")
  var beats = 0
  for b in rt.beats:
    if b.kind == "fallback":
      inc beats
      c.check(b.turn == 3, "the fallback beat is on the right turn")
      c.check(b.slot == 1, "and names the seat that missed the call")
  c.check(beats == 1, "exactly one fallback beat (got " & $beats & ")")
  c.check("\"k\":\"fallback\"" in eventsJsonl(rt.events, rt.replay.turns.len,
    GameVersion),
    "and the tier-2 analysis stream carries a fallback row")

# The tier-2 analysis stream is the design note's REDUCED vocabulary, not the
# broadcast enum.
block:
  var config = defaultGameConfig()
  config.seed = 42
  config.maxTurns = 40
  let played = runScriptedEpisode(config, certificationSeats())
  let directives = @[
    DirectiveEvent(turn: 1, slot: 0, alias: cogAlias(0), source: "llm",
      dir: "up", latencyMs: 210, repaired: false),
    DirectiveEvent(turn: 2, slot: 3, alias: cogAlias(3), source: "scripted",
      dir: "left", latencyMs: 0, repaired: true)]
  let jsonl = eventsJsonl(played.events, played.episode.turnsPlayed,
    GameVersion, directives)
  var kinds = initHashSet[string]()
  var rows = 0
  var summary = newJNull()
  for line in jsonl.strip().splitLines():
    let node = parseJson(line)
    if node{"type"}.getStr() == "summary":
      summary = node
      continue
    inc rows
    kinds.incl(node{"k"}.getStr())
  var reduced = initHashSet[string]()
  for kind in SimEventKind:
    reduced.incl(key(kind))
  c.check(reduced.len == 14, "the reduced vocabulary is fourteen kinds")
  c.check(kinds <= reduced,
    "every tier-2 row is one of them; extra=" & $(kinds - reduced))
  for gone in ["gamestart", "spawn", "end"]:
    c.check(gone notin kinds,
      "the tier-2 stream does not carry the broadcast-only kind " & gone)
  c.check("directive" in kinds,
    "and it DOES carry the directive rows the sim cannot derive")
  c.check("turn" in kinds and "move" in kinds and "death" in kinds,
    "with the board kinds it does carry")
  c.check(summary.kind == JObject, "the summary row is present")
  if summary.kind == JObject:
    c.check(summary{"events"}.getInt() == rows,
      "and counts the rows it is a summary of")
    c.check(summary{"turns"}.getInt() == played.episode.turnsPlayed,
      "and the turns")
    c.check(summary{"gameVersion"}.getStr() == GameVersion,
      "and the game version")
  ## A turn's directive precedes that turn's board events: the decision comes
  ## before the resolution.
  var firstDirective = -1
  var firstTurnEvent = -1
  var index = 0
  for line in jsonl.strip().splitLines():
    let node = parseJson(line)
    if node{"k"}.getStr() == "directive" and firstDirective < 0:
      firstDirective = index
    if node{"k"}.getStr() == "turn" and node{"t"}.getInt() == 1 and
        firstTurnEvent < 0:
      firstTurnEvent = index
    inc index
  c.check(firstDirective >= 0 and firstTurnEvent >= 0,
    "both a directive and a turn row exist")
  c.check(firstDirective < firstTurnEvent,
    "turn 1's directive comes before turn 1's board events")

c.report()
