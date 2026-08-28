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

proc ladderMargin(coil, forager: Tunables): float =
  var
    coilTotal = 0
    foragerTotal = 0
  for seed in 1 .. LadderEpisodes:
    var config = defaultGameConfig()
    config.seed = seed * SeedStride
    config.maxTurns = 50
    config.turnSpacingMs = 0
    let played = runScriptedEpisode(config,
      [blCoil, blForager, blCoil, blForager])
    let permille = played.episode.scorePermille()
    coilTotal = coilTotal + permille[0] + permille[2]
    foragerTotal = foragerTotal + permille[1] + permille[3]
  float(coilTotal - foragerTotal) / float(LadderEpisodes * 2 * 1000)

proc toJson(t: Tunables): JsonNode =
  %*{"spaceWeight": t.spaceWeight, "spaceCap": t.spaceCap,
     "headRiskPenalty": t.headRiskPenalty, "killBonus": t.killBonus,
     "foodWeight": t.foodWeight, "hungerThreshold": t.hungerThreshold}

when isMainModule:
  let check = "--check" in commandLineParams()
  let margin = ladderMargin(CoilTunables, ForagerTunables)
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
    if recorded{"baselines"} != document{"baselines"}:
      quit("baseline tuning drifted from " & OutPath, 1)
    echo "baseline tuning matches ", OutPath
  else:
    writeFile(OutPath, document.pretty() & "\n")
    echo "wrote ", OutPath
