## A forked ctf endcard silently ships paintbot's vocabulary: nothing in the
## starter's tests, in viewer_smoke.mjs or in the label manifest covers
## spectator chrome strings. This test is what enforces the re-labelings.

import std/[strutils]
import helpers

var c = newChecker("test_snake_endcard_labels")

proc stripComments(text: string): string =
  ## Drops HTML comments, CSS block comments and JS line comments, so a scar
  ## note that MENTIONS the old vocabulary is not a finding.
  var kept = ""
  var i = 0
  while i < text.len:
    if text.continuesWith("<!--", i):
      let close = text.find("-->", i)
      i = if close < 0: text.len else: close + 3
    elif text.continuesWith("/*", i):
      let close = text.find("*/", i)
      i = if close < 0: text.len else: close + 2
    elif text.continuesWith("//", i) and (i == 0 or text[i - 1] notin {':', '/'}):
      let close = text.find('\n', i)
      i = if close < 0: text.len else: close
    else:
      kept.add(text[i])
      inc i
  kept

let page = stripComments(readFile("client/replay_broadcast.html"))
let core = stripComments(readFile("client/broadcast_core.js"))

const Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart",
                   "paint", "hopper", "hill", "POV", "spray", "grenade",
                   "med kit", "kill", "HP pips", "RED", "BLUE"]

for word in Forbidden:
  c.check(word notin page,
    "paintbot vocabulary in the page, outside comments: " & word)
  c.check(word notin core,
    "paintbot vocabulary in the renderer, outside comments: " & word)

const Replacements = [
  "<span>Cog</span>", "<span>Place</span>", "<span>Turns</span>",
  "<span>Length</span>", "<span>Ate</span>", "<span>Soft</span>",
  "Coiling up", "Before the first move",
  "showing recorded moves",
  "deaths / head-ons / winner on the timeline ahead of the playhead (o)",
  ">LENGTH<", "len-label", "hp-label"]

let raw = readFile("client/replay_broadcast.html")
for replacement in Replacements:
  let count = raw.count(replacement)
  c.check(count >= 1, "the re-mapped string is present: " & replacement)

c.report()
