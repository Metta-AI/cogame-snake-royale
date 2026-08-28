## Sweep the two scripted baselines over the fixed 24-episode ladder and check
## the shipped pick against tools/ci/baseline_tuning.json.
##
## The tunables are SWEPT, NOT GUESSED: `--sweep` prints every candidate's
## margin over the ladder (eight seeds on each of the three rule modules,
## seated coil, forager, coil, forager), and that record is what pins the
## shipped numbers. `--check` re-plays the ladder with the shipped constants
## and fails if either the constants or the recorded integers have drifted --
## which is a regression pin on the rules, the scoring and both baselines at
## once. `ci.yml` runs `--sweep --check`.
##
##   nim r --path:src tools/tune_baselines.nim --sweep --check
##   nim r --path:src tools/tune_baselines.nim --write

import std/[json, os]
import snake/[sim, sim_types, baselines, engine]

const OutPath = "tools/ci/baseline_tuning.json"

proc toJson(t: Tunables): JsonNode =
  %*{"spaceWeight": t.spaceWeight, "spaceCap": t.spaceCap,
     "headRiskPenalty": t.headRiskPenalty, "killBonus": t.killBonus,
     "foodWeight": t.foodWeight, "hungerThreshold": t.hungerThreshold}

proc sweep() =
  ## The bounded matrix. `spaceCap` is measured in multiples of the snake's
  ## own length and cannot usefully exceed the BFS cap of four; `spaceWeight`
  ## sets how many free cells one head-on risk is worth; `foodWeight` is what
  ## pulls a hungry snake off its space-maximising path.
  ##
  ## FORAGER IS SWEPT TOO, on the one knob that decides how greedy it really
  ## is: holding it fixed made its shipped `spaceWeight` a guess sitting in a
  ## table of swept numbers. Its other five knobs are its CHARACTER -- always
  ## hungry, tight on space, cheap on risk -- and are the design note's, not
  ## something to optimise: forager is the player a champion should be able to
  ## beat, so tuning it for the margin would be measuring the wrong thing.
  echo "sweep over the ladder (margin = coil mean score - forager mean)"
  for foragerSpaceWeight in [40, 400]:
    var forager = ForagerTunables
    forager.spaceWeight = foragerSpaceWeight
    for spaceWeight in [100, 300, 1000]:
      for spaceCap in [2, 4]:
        for foodWeight in [8, 100, 400]:
          var coil = CoilTunables
          coil.spaceWeight = spaceWeight
          coil.spaceCap = spaceCap
          coil.foodWeight = foodWeight
          let totals = ladderTotals(coil, forager)
          echo "  foragerSpaceWeight=", foragerSpaceWeight,
            " coilSpaceWeight=", spaceWeight, " coilSpaceCap=", spaceCap,
            " coilFoodWeight=", foodWeight, " margin=", ladderMargin(totals),
            " coilTurns=", totals.coilTurns,
            " foragerTurns=", totals.foragerTurns

proc measuredJson(totals: LadderTotals): JsonNode =
  var perModule = newJObject()
  for index, module in LadderModules:
    perModule[module] = %*{
      "coilPermille": totals.perModule[index].coilPermille,
      "foragerPermille": totals.perModule[index].foragerPermille,
      "coilTurns": totals.perModule[index].coilTurns,
      "foragerTurns": totals.perModule[index].foragerTurns}
  %*{
    "total": {"coilPermille": totals.coilPermille,
              "foragerPermille": totals.foragerPermille,
              "coilTurns": totals.coilTurns,
              "foragerTurns": totals.foragerTurns},
    "margin": ladderMargin(totals),
    "perModule": perModule}

when isMainModule:
  let params = commandLineParams()
  if "--sweep" in params:
    sweep()
  let totals = ladderTotals(CoilTunables, ForagerTunables)
  echo "ladder margin (coil - forager, mean score per seat): ",
    ladderMargin(totals)
  echo "ladder survived turns: coil ", totals.coilTurns, ", forager ",
    totals.foragerTurns

  if "--write" in params:
    var document = parseJson(readFile(OutPath))
    document["baselines"] = %*{"coil": toJson(CoilTunables),
                               "forager": toJson(ForagerTunables)}
    var measured = measuredJson(totals)
    measured["comment"] = document{"measured"}{"comment"}
    document["measured"] = measured
    writeFile(OutPath, document.pretty() & "\n")
    echo "wrote ", OutPath
  if "--check" in params:
    let recorded = parseJson(readFile(OutPath))
    let shipped = %*{"coil": toJson(CoilTunables),
                     "forager": toJson(ForagerTunables)}
    for name in ["coil", "forager"]:
      for key in ["spaceWeight", "spaceCap", "headRiskPenalty", "killBonus",
                  "foodWeight", "hungerThreshold"]:
        let want = recorded{"baselines"}{name}{key}.getInt()
        let got = shipped{name}{key}.getInt()
        if want != got:
          quit("baseline tuning drifted from " & OutPath & ": " & name & "." &
            key & " is " & $got & ", recorded " & $want, 1)
    let want = recorded{"measured"}{"total"}
    if want{"coilPermille"}.getInt() != totals.coilPermille or
        want{"foragerPermille"}.getInt() != totals.foragerPermille or
        want{"coilTurns"}.getInt() != totals.coilTurns or
        want{"foragerTurns"}.getInt() != totals.foragerTurns:
      quit("the ladder no longer reproduces " & OutPath & ": measured " &
        $measuredJson(totals){"total"} & ", recorded " & $want, 1)
    echo "baseline tuning matches ", OutPath
