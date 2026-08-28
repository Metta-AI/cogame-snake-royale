## Engine-wide constants, the runtime `GameConfig`, and the rune caps every
## recorded string is measured against.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`: the same
## `GameVersion` / `ReplayFps` / `TargetFps` / `MaxSayRunes` / `MaxNoteRunes` /
## `MaxPromptRunes` discipline, retargeted from a continuous 2-D arena to an
## integer grid. The paintball wire types, the weapon/paint/flag/hill state and
## the fog-of-war fields are deleted, not disabled (design note §Sim module).

import std/strutils

const
  GameVersion* = "1"    ## the initial snake-royale rules
    ## Bumped whenever the recorded replay stream changes meaning. Every
    ## committed fixture carries it and `tests/test_snake_replay.nim` sweeps
    ## for a stale one. The HEADLINE on the declaration line is what
    ## `tools/ci/check_gameversion.sh` compares across branches: two branches
    ## can pick the same next number without seeing each other, and the same
    ## number attached to two different rules is the collision that makes an
    ## old replay re-simulate wrong.

  ReplayFps* = 24
    ## The VIEWER's render rate. A tick is not a turn here: the sim's atom is
    ## one simultaneous move by every snake, and `renderFramesPerTurn` frames
    ## of playback are drawn per turn.
  TargetFps* = 24

  MaxSayRunes* = 24
    ## The public one-line channel. Measured in RUNES; every cut lands on a
    ## rune boundary (`src/snake/directives.nim`).
  MaxNoteRunes* = 160
  MaxPromptRunes* = 4000
  MaxFallbackDetailRunes* = 200
  MaxPolicyLabelRunes* = 64
  MaxDirectiveRunes* = 4000
  MaxReplyBytes* = 4096
    ## Hard cap on the bytes read from one model reply before the tolerant
    ## JSON extraction runs.
  MaxStopDetailRunes* = 200

  Seats* = 4
    ## `num_agents`, fixed. Design note §The game → Seats: four is Hungry
    ## Geese's own number, the smallest free-for-all in which "who blocks
    ## whom" exists, one parallel batch of four calls per turn inside the
    ## sidecar's rate cap, and the exact integer zero-sum placement vector.

  PlacementPermille*: array[Seats, int] = [1000, 333, -333, -1000]
    ## Places 1..4. The four scores always sum to exactly zero.

  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
  ProtocolName* = "snake-royale/v1"
  ReplayMagic* = "COWLDSNK"
  ReplayFormatVersion* = 1
  GameName* = "snake-royale"

type
  SnakeError* = object of CatchableError

  GameConfig* = object
    ## The runtime config, parsed from `COGAME_CONFIG_URI`. Every field is
    ## also a `config_schema` property in `coworld_manifest_template.json`.
    seed*: int
    module*: string             ## royale | geese | tron
    boardW*, boardH*: int
    wrap*: bool
    foodCount*: int
    healthStart*: int           ## 0 = health off
    shrinkEvery*: int           ## 0 = off
    leaveTrail*: bool
    headToHead*: string         ## longer_wins | both_die
    startLength*: int
    maxTurns*: int
    renderFramesPerTurn*: int
    sayTurns*: int
    numAgents*: int
    minPlayers*: int
    fastMode*: bool
    showPlayerLabels*: bool
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutSeconds*: int
    gameOverTurns*: int
    model*: string
    maxOutputTokens*: int
    playerNames*: seq[string]
    tokens*: seq[string]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 1,
    module: "royale",
    boardW: 17, boardH: 9, wrap: false,
    foodCount: 3, healthStart: 30, shrinkEvery: 0, leaveTrail: false,
    headToHead: "longer_wins", startLength: 3, maxTurns: 50,
    renderFramesPerTurn: 12, sayTurns: 2,
    numAgents: Seats, minPlayers: Seats,
    fastMode: true, showPlayerLabels: false,
    attempt1Ms: 6000, retryMs: 3000,
    turnBudgetMs: 11000, turnSpacingMs: 9000,
    wallClockBudgetSeconds: 640, lobbyJoinTimeoutSeconds: 90,
    gameOverTurns: 2,
    model: "claude-haiku-4-5-20251001", maxOutputTokens: 900,
    playerNames: @[], tokens: @[])

proc turnBudgetSeconds*(config: GameConfig): int =
  (config.turnBudgetMs + 999) div 1000

proc normalizedModule*(text: string): string =
  let key = text.strip().toLowerAscii()
  if key in ["royale", "geese", "tron"]: key else: "royale"
