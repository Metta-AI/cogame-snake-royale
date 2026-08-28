## The emitted board-label vocabulary equals tests/label_manifest.txt,
## regenerated in the same commit as any label change.

import std/[strutils]
import snake/[board, rules, sim, sim_types, labels, engine]
import helpers

var c = newChecker("test_snake_label_contract")

let manifest = readFile("tests/label_manifest.txt")
let emitted = labelManifest()
c.check(manifest == emitted,
  "tests/label_manifest.txt is stale; regenerate it in the same commit as " &
  "the label change. Emitted:\n" & emitted)

for phrase in LabelVocabulary:
  c.check(phrase in manifest, "the manifest carries: " & phrase)
  ## Plain language, never internal notation.
  c.check("slot" notin phrase.toLowerAscii(), phrase & " names no slot index")

# The rows the design note prints, rendered from real events.
block:
  var config = defaultGameConfig()
  config.seed = 42
  let episode = newEpisode(config)
  c.check(feedRow(episode, TurnEvent(kind: ekDeath, turn: 7, slot: 3,
      other: -1, at: cell(3, -1), value: 4, text: $dcWall)) ==
    "COG-delta runs into the north wall", "the wall row names the wall")
  c.check(feedRow(episode, TurnEvent(kind: ekDeath, turn: 7, slot: 0,
      other: -1, at: cell(2, episode.state.rules.board.h), value: 4,
      text: $dcWall)) == "COG-alpha runs into the south wall",
    "and the other sides too")
  c.check(feedRow(episode, TurnEvent(kind: ekHeadOn, turn: 9, slot: 0,
      other: 0, at: cell(4, 4), value: 2, extra: 8, text: "0:8,2:6")) ==
    "HEAD-ON — COG-alpha (8) beats COG-gamma (6)",
    "the head-on row shows who beat whom, and by how much")
  c.check(feedRow(episode, TurnEvent(kind: ekHeadOn, turn: 9, slot: 1,
      other: -1, at: cell(4, 4), value: 2, extra: 0, text: "1:7,3:7")) ==
    "HEAD-ON — COG-beta and COG-delta both die (7 v 7)",
    "and an equal-length head-on names both and both lengths")
  c.check(feedRow(episode, TurnEvent(kind: ekDecline, turn: 5, slot: 1,
      other: 3, at: cell(2, 2))) ==
    "COG-beta declines a free head-on with COG-delta",
    "the alliance audit's row names the rival that was spared")
  c.check(feedRow(episode, TurnEvent(kind: ekFallback, turn: 5, slot: 3,
      other: -1, text: "timeout")) ==
    "COG-delta MISSED THE CALL — coil move (timeout)",
    "and a missed call says which seat and why")

# ...and over a real episode every row the feed carries is plain language
# built from the event the sim emitted, with no placeholder left in it.
block:
  var config = defaultGameConfig()
  config.seed = 42
  config.maxTurns = 40
  let played = runScriptedEpisode(config, certificationSeats())
  var walls, headons, rows = 0
  for e in played.events:
    let row = feedRow(played.episode, e)
    if row.len == 0:
      continue
    inc rows
    c.check("COG-" in row or row.startsWith("HEAD-ON") or
      row.startsWith("HUNGER") or row.startsWith("DUEL") or
      row.startsWith("Last snake"), "a real feed row reads plainly: " & row)
    if e.kind == ekDeath and e.text == $dcWall:
      inc walls
      c.check(row.endsWith(" wall") and
        ("north" in row or "south" in row or "east" in row or "west" in row),
        "a wall death names the side it ran into: " & row)
    if e.kind == ekHeadOn:
      inc headons
      c.check("(" in row, "a head-on row carries the lengths: " & row)
  c.check(rows > 0, "the episode produced feed rows at all")
  c.check(walls + headons >= 1,
    "including at least one wall death or head-on (" & $walls & "/" &
    $headons & ")")

c.report()
