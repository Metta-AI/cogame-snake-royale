## The shipped constants equal the upstream table at the head of the design
## note, and the five documented divergences are present with their citations.
## A constant edited without editing the citation fails here.

import std/strutils
import snake/[rules, upstream, sim_types]
import helpers

var c = newChecker("test_snake_upstream")

# The four upstreams, transcribed with their citations.
c.check(UpstreamFacts.len == 5, "five upstream facts are transcribed")
for fact in UpstreamFacts:
  c.check(fact.source.len > 0, "every fact names its source")
  c.check(fact.claim.len > 0, "every fact states its claim")
  c.check(fact.landsAs.len > 0, "every fact says how it lands here")

# Kaggle Hungry Geese: 4 geese, a 7-row by 11-column torus, food to grow, a
# segment lost every 40 steps.
let geese = ruleModule("geese")
c.check(geese.board.w == GeeseBoardW and geese.board.h == GeeseBoardH,
  "geese is 11 by 7")
c.check(geese.board.wrap, "geese is a torus")
c.check(geese.foodCount == GeeseFoodCount, "geese maintains two apples")
c.check(geese.shrinkEvery == GeeseShrinkEvery, "geese shrinks every 20 turns")
c.check(geese.headToHead == hhBothDie, "geese head-ons kill everybody")

# Battlesnake: health drains and resets on food; a head-to-head is won by the
# strictly longer snake.
let royale = ruleModule("royale")
c.check(royale.healthStart == RoyaleHealthStart, "royale health starts at 30")
c.check(royale.headToHead == hhLongerWins, "royale head-ons are longer_wins")
c.check(royale.startLength == RoyaleStartLength, "royale starts at length 3")

# Tron / Atari Surround: no growth mechanic, just walls.
let tron = ruleModule("tron")
c.check(tron.leaveTrail, "tron leaves a trail")
c.check(tron.foodCount == TronFoodCount, "tron has no food")
c.check(tron.startLength == TronStartLength, "tron starts at length 1")

# OpenSpiel snake: simultaneous moves, perfect information; and all four
# upstreams agree that one direction per turn is the entire action space.
c.check(UpstreamSeats == Seats, "four seats, the canonical shape")
c.check(UpstreamActionSpace == 4, "one direction per turn, four of them")

# The five documented divergences.
c.check(Divergences.len == 5, "five divergences are documented")
for i, d in Divergences:
  c.check(d.id == i + 1, "divergences are numbered in order")
  c.check(d.upstream.len > 0 and d.here.len > 0 and d.why.len > 0,
    "every divergence says upstream, here and why")
c.check("40" in Divergences[0].upstream and "20" in Divergences[0].here,
  "divergence 1 is the shrink clock")
c.check("100" in Divergences[1].upstream and "30" in Divergences[1].here,
  "divergence 2 is the health scale")
c.check("length 1" in Divergences[2].upstream, "divergence 3 is startLength")
c.check("REPAIRED" in Divergences[3].here, "divergence 4 is the neck repair")
c.check("hazards" in Divergences[4].upstream, "divergence 5 is hazards")

# docs/RULES.md carries the same five divergences.
let rules = readFile("docs/RULES.md")
c.check("Divergences from the upstreams" in rules,
  "docs/RULES.md has a divergences section")
for needle in ["shrinks every 40", "health is 100", "starts at length 1",
               "repaired", "hazards are not implemented"]:
  c.check(needle in rules, "docs/RULES.md mentions: " & needle)

c.report()
