## Sweep the two scripted baselines over a fixed 24-episode ladder and write
## the pick to tools/ci/baseline_tuning.json.
##
## The tunables are SWEPT, NOT GUESSED. `ci.yml` re-runs this with `--check`,
## which re-plays the ladder with the recorded pick and fails if the shipped
## defaults have drifted from it; `tests/test_snake_control.nim` asserts the
## shipped constants equal the recorded numbers.
##
##   nim r --path:src tools/tune_baselines.nim            # sweep and write
##   nim r --path:src tools/tune_baselines.nim --check    # verify only

import std/[json, os, strutils]
import snake/[sim, sim_types, baselines, engine]

const
  LadderEpisodes = 24
  SeedStride = 977
  OutPath = "tools/ci/baseline_tuning.json"

proc ladderMarginWith(coil, forager: Tunables): float =
  var
    coilTotal = 0
    foragerTotal = 0
  for seed in 1 .. LadderEpisodes:
    var config = defaultGameConfig()
    config.seed = seed * SeedStride
    config.maxTurns = 50
    config.turnSpacingMs = 0
    let played = runScriptedEpisodeWith(config,
      [blCoil, blForager, blCoil, blForager], coil, forager)
    let permille = played.episode.scorePermille()
    coilTotal = coilTotal + permille[0] + permille[2]
    foragerTotal = foragerTotal + permille[1] + permille[3]
  float(coilTotal - foragerTotal) / float(LadderEpisodes * 2 * 1000)

proc toJson(t: Tunables): JsonNode =
  %*{"spaceWeight": t.spaceWeight, "spaceCap": t.spaceCap,
     "headRiskPenalty": t.headRiskPenalty, "killBonus": t.killBonus,
     "foodWeight": t.foodWeight, "hungerThreshold": t.hungerThreshold}

proc sweep() =
  ## The bounded matrix. `spaceCap` is measured in multiples of the snake's
  ## own length and cannot usefully exceed the BFS cap of four; `spaceWeight`
  ## sets how many free cells one head-on risk is worth.
  echo "coil sweep (margin = coil mean score - forager mean score, per seat)"
  for spaceWeight in [40, 100, 250, 1000]:
    for spaceCap in [1, 2, 4]:
      var coil = CoilTunables
      coil.spaceWeight = spaceWeight
      coil.spaceCap = spaceCap
      let margin = ladderMarginWith(coil, ForagerTunables)
      echo "  spaceWeight=", spaceWeight, " spaceCap=", spaceCap,
        " margin=", margin

when isMainModule:
  let params = commandLineParams()
  let check = "--check" in params
  if "--sweep" in params:
    sweep()
  let margin = ladderMarginWith(CoilTunables, ForagerTunables)
  echo "ladder margin (coil - forager, mean score per seat): ", margin
  let document = %*{
    "note": "The swept pick. tools/tune_baselines.nim plays a bounded matrix " &
      "over a fixed 24-episode ladder and writes this file; ci.yml re-runs " &
      "the sweep with --check and tests/test_snake_control.nim asserts the " &
      "shipped defaults equal the recorded pick.",
    "ladder": {"episodes": LadderEpisodes, "seedStride": SeedStride,
               "maxTurns": 50,
               "seats": ["coil", "forager", "coil", "forager"]},
    "baselines": {"coil": toJson(CoilTunables),
                  "forager": toJson(ForagerTunables)}
  }
  if check:
    let recorded = parseJson(readFile(OutPath))
    for name in ["coil", "forager"]:
      let want = recorded{"baselines"}{name}
      let got = document{"baselines"}{name}
      if want.isNil:
        quit(OutPath & " has no recorded pick for " & name, 1)
      for key in ["spaceWeight", "spaceCap", "headRiskPenalty", "killBonus",
                  "foodWeight", "hungerThreshold"]:
        if want{key}.getInt() != got{key}.getInt():
          quit("baseline tuning drifted from " & OutPath & ": " & name & "." &
            key & " is " & $got{key}.getInt() & ", recorded " &
            $want{key}.getInt(), 1)
    echo "baseline tuning matches ", OutPath
  else:
    writeFile(OutPath, document.pretty() & "\n")
    echo "wrote ", OutPath
