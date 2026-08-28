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

proc feedRow*(episode: Episode, e: TurnEvent): string =
  ## One plain-language match-feed row, or an empty string for a kind the feed
  ## does not carry.
  let alias = cogAlias(e.slot)
  case e.kind
  of ekEat:
    alias & " eats — length " & $e.value
  of ekDeath:
    if e.text == $dcHeadOn: ""            ## the head-on row already said it
    elif e.text == $dcWall: alias & " runs into a wall"
    elif e.text == $dcStarve: alias & " starves"
    else: alias & " runs into a body"
  of ekHeadOn:
    if e.other >= 0:
      "HEAD-ON — " & cogAlias(e.other) & " wins the cell"
    else:
      "HEAD-ON — everybody in that cell dies"
  of ekTrapped:
    alias & " is TRAPPED — " & $e.value & " free cells, length " & $e.extra
  of ekShrink:
    "HUNGER — everyone loses a segment"
  of ekDecline:
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
  "eats — length", "runs into a wall", "runs into a body", "starves",
  "HEAD-ON — ", " wins the cell", "everybody in that cell dies",
  "is TRAPPED — ", "HUNGER — everyone loses a segment",
  "declines a free head-on", "MISSED THE CALL — coil move",
  "DUEL — two snakes left", "Last snake standing"]

proc labelManifest*(): string =
  LabelVocabulary.join("\n") & "\n"
