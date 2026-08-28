## Plain-language board and feed labels. Never internal notation: the feed
## says `COG-beta eats — length 6`, not `EAT s1 l6`.
##
## Forked from `coworld-ctf`'s `src/ctf/labels.nim`, which scopes itself to
## the vocabulary a spectator reads. `tests/test_snake_label_contract.nim`
## asserts the emitted set equals `tests/label_manifest.txt`, regenerated in
## the same commit as any label change.

import std/strutils
import rules, sim

proc deathPhrase*(cause: DeathCause, alias: string, wall: string): string =
  case cause
  of dcWall: alias & " runs into the " & wall & " wall"
  of dcBody: alias & " runs into a body"
  of dcHeadOn: alias & " loses a head-on"
  of dcStarve: alias & " starves"
  of dcNone: alias & " is out"

proc wallSideOf*(board: Board, c: Cell): string =
  if c.y < 0: "north"
  elif c.y >= board.h: "south"
  elif c.x < 0: "west"
  else: "east"

proc headOnMembers(text: string): seq[tuple[slot, length: int]] =
  ## The `headon` event's group, `slot:length` ascending (see `rules.nim`
  ## step 9). Tolerant: an event without the field just yields nothing, and
  ## the row falls back to the shape that needs no lengths.
  for part in text.split(','):
    let halves = part.split(':')
    if halves.len != 2:
      continue
    try:
      result.add((parseInt(halves[0]), parseInt(halves[1])))
    except ValueError:
      discard

proc feedRow*(episode: Episode, e: TurnEvent): string =
  ## One plain-language match-feed row, or an empty string for a kind the feed
  ## does not carry.
  let alias = cogAlias(e.slot)
  case e.kind
  of ekEat:
    alias & " eats — length " & $e.value
  of ekDeath:
    if e.text == $dcHeadOn: ""            ## the head-on row already said it
    else:
      var cause = dcNone
      try:
        cause = parseEnum[DeathCause](e.text)
      except ValueError:
        discard
      deathPhrase(cause, alias, wallSideOf(episode.state.rules.board, e.at))
  of ekHeadOn:
    let members = headOnMembers(e.text)
    if e.other >= 0:
      ## A winner: name it, name what it beat, and give both lengths -- length
      ## is the only thing that wins a head-on, so the row has to show it.
      var beaten = ""
      for m in members:
        if m.slot == e.other:
          continue
        if beaten.len > 0:
          beaten.add(" and ")
        beaten.add(cogAlias(m.slot) & " (" & $m.length & ")")
      if beaten.len == 0:
        "HEAD-ON — " & cogAlias(e.other) & " wins the cell"
      else:
        "HEAD-ON — " & cogAlias(e.other) & " (" & $e.extra & ") beats " & beaten
    elif members.len == 2:
      "HEAD-ON — " & cogAlias(members[0].slot) & " and " &
        cogAlias(members[1].slot) & " both die (" & $members[0].length &
        " v " & $members[1].length & ")"
    elif members.len > 2:
      var names = ""
      for i, m in members:
        if i > 0:
          names.add(if i == members.len - 1: " and " else: ", ")
        names.add(cogAlias(m.slot))
      "HEAD-ON — " & names & " all die"
    else:
      "HEAD-ON — everybody in that cell dies"
  of ekTrapped:
    alias & " is TRAPPED — " & $e.value & " free cells, length " & $e.extra
  of ekShrink:
    "HUNGER — everyone loses a segment"
  of ekDecline:
    if e.other >= 0:
      alias & " declines a free head-on with " & cogAlias(e.other)
    else:
      alias & " declines a free head-on"
  of ekSay:
    alias & ": \"" & e.text & "\""
  of ekFallback:
    alias & " MISSED THE CALL — coil move (" & e.text & ")"
  of ekDuel:
    "DUEL — two snakes left"
  of ekGameOver:
    "Last snake standing"
  else:
    ""

const LabelVocabulary* = [
  "eats — length", "runs into the north wall", "runs into the south wall",
  "runs into the west wall", "runs into the east wall", "runs into a body",
  "loses a head-on", "starves", "is out",
  "HEAD-ON — ", " wins the cell", " beats ", " both die (", " all die",
  "everybody in that cell dies",
  "is TRAPPED — ", "HUNGER — everyone loses a segment",
  "declines a free head-on", "declines a free head-on with ",
  "MISSED THE CALL — coil move",
  "DUEL — two snakes left", "Last snake standing"]

proc labelManifest*(): string =
  LabelVocabulary.join("\n") & "\n"
