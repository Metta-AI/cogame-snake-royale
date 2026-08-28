## The replay chat records, in one pure module.
##
## They are written by the server, re-applied at playback into NON-HASHED
## fields only, and they drive the broadcast feed and
## `tools/replay_summary.py`. They can never affect the sim.
##
## `coworld-ctf` keeps these beside the decision loop in `decide.nim`; they
## live here instead so the headless episode runner, the fixture recorder and
## the tests can build a replay without importing the LLM transport (and its
## libcurl dependency) at all.

import std/json
import sim, directives

proc fallbackRecord*(turn, slot, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "turn": turn, "slot": slot, "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(slot: int, alias, colour, policy, kind,
                     baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register", "slot": slot, "alias": alias, "colour": colour,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(turn: int, endRule: string): string =
  ## The load-bearing wall-clock or fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is recorded as ONE record applied by the
  ## SAME proc on record and on playback (the particle-worlds scar).
  $(%*{"k": "stop", "turn": turn, "endRule": endRule})

proc resultRecord*(episode: Episode): string =
  ## The episode's whole results document, written once into the replay chat
  ## stream at episode end. It is what makes the replay SELF-SUFFICIENT:
  ## without it the outcome exists only at COGAME_RESULTS_URI and
  ## replay_summary.py's `results` reads {} for a spectator holding the bytes.
  "{\"k\":\"result\",\"results\":" & episode.snakeResultsJson() & "}"
