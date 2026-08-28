## The upstreams this game merges, transcribed with their citations, plus the
## five documented divergences. `tests/test_snake_upstream.nim` asserts the
## shipped rule modules still match these constants, so a constant edited
## without its citation fails the build.

import board, sim_types

type
  UpstreamFact* = object
    source*: string
    claim*: string
    landsAs*: string

  Divergence* = object
    id*: int
    upstream*: string
    here*: string
    why*: string

const
  UpstreamFacts*: array[5, UpstreamFact] = [
    UpstreamFact(
      source: "kaggle-environments hungry_geese",
      claim: "4 geese on a 7-row by 11-column torus, food to grow, a segment " &
        "lost every 40 steps, last goose standing",
      landsAs: "the `geese` rule module: an 11 by 7 wrapping board, " &
        "foodCount 2, shrinkEvery on, headToHead both_die"),
    UpstreamFact(
      source: "docs.battlesnake.com",
      claim: "health drains one per turn and resets on food; a head-to-head " &
        "is won by the strictly longer snake, equal lengths both die; a " &
        "snake may enter a tail cell that vacates this turn",
      landsAs: "the `royale` module: healthStart 30, headToHead " &
        "longer_wins, the tail rule in resolution steps 7 and 10"),
    UpstreamFact(
      source: "Tron / Atari Surround",
      claim: "light cycles: no growth mechanic, just walls; the trail never " &
        "vacates and there is no food",
      landsAs: "the `tron` module: leaveTrail true, foodCount 0, " &
        "startLength 1"),
    UpstreamFact(
      source: "OpenSpiel snake",
      claim: "simultaneous moves, perfect information",
      landsAs: "one direction per seat per turn resolved simultaneously; " &
        "every seat sees the whole board every turn"),
    UpstreamFact(
      source: "all four upstreams",
      claim: "one direction per turn is the entire action space",
      landsAs: "the reply schema's `dir`, plus an optional `alt` used only " &
        "against the neck rule")
  ]

  Divergences*: array[5, Divergence] = [
    Divergence(id: 1,
      upstream: "hungry_geese shrinks every 40 steps across a 200-step episode",
      here: "geese uses shrinkEvery = 20",
      why: "a 50-turn episode would show that clock once; at 20 the hunger " &
        "clock bites twice and a spectator can see it working"),
    Divergence(id: 2,
      upstream: "Battlesnake health is 100 across long games",
      here: "royale uses healthStart = 30 across 50 turns",
      why: "the same 'you must eat about twice per episode' pressure at this " &
        "episode length"),
    Divergence(id: 3,
      upstream: "hungry_geese starts a goose at length 1",
      here: "every module except tron starts at 3, Battlesnake's convention",
      why: "the neck rule is meaningful from turn 2 and a snake reads as a " &
        "snake on the first drawn frame"),
    Divergence(id: 4,
      upstream: "naming your own neck is a death in hungry_geese and Battlesnake",
      here: "the neck is REPAIRED (alt, then last_dir) and counted in " &
        "results.reverseRepaired",
      why: "a model's formatting slip must not be an instant loss; the " &
        "transport is not the game. Every other death cause is upstream's"),
    Divergence(id: 5,
      upstream: "Battlesnake hazards (sauce)",
      here: "not implemented in v1",
      why: "a hazard region is a fourth rule-module axis and a fourth board " &
        "layer; it needs a module of its own, not a switch bolted onto royale")
  ]

  # The shipped constants the citations above bind. A rule-module edit that
  # does not move these fails tests/test_snake_upstream.nim.
  GeeseBoardW* = 11
  GeeseBoardH* = 7
  GeeseFoodCount* = 2
  GeeseShrinkEvery* = 20
  RoyaleHealthStart* = 30
  RoyaleStartLength* = 3
  TronStartLength* = 1
  TronFoodCount* = 0
  UpstreamSeats* = Seats
  UpstreamActionSpace* = DirOrder.len
