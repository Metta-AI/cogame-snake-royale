# Wire protocol

## The Coworld contract

| Direction | Variable | Meaning |
|---|---|---|
| in | `COGAME_CONFIG_URI` | the episode's `game_config` |
| out | `COGAME_RESULTS_URI` | the results document (closed schema) |
| out | `COGAME_SAVE_REPLAY_URI` | the binary `COWLDSNK` replay |
| out | `COGAME_PLAYER_FAILURE_URI` | one `{"message","failed_policy_index"}` payload |
| out | `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream |
| local | `COGAME_LOAD_REPLAY_URI` | developer replay mode, never declared to the platform |
| — | `COGAME_HOST` / `COGAME_PORT` | where to listen (`HOST` / `PORT` also accepted) |

Player sockets live at `/player?slot=<i>&token=<t>` and are **closed unless the token matches
the seat**. `/global` is the spectator stream; `/healthz`, `/client/player` and
`/client/global` answer the certifier's browser probes and keep answering for a bounded
shutdown grace after the artifacts are written.

## Per-seat observation

Perfect information: the whole board is in every observation, in board cells, integers only.

```json
{
  "module": "royale",
  "board": {"w": 17, "h": 9, "wrap": false},
  "turn": 17, "max_turns": 50, "turns_left": 33, "alive": 3,
  "rules": {"head_to_head": "longer_wins", "food_count": 3,
            "health_start": 30, "shrink_every": 0, "leave_trail": false},
  "you": {"id": "COG-beta", "colour": "teal", "alive": true,
          "head": [7,4], "body": [[7,4],[7,5],[6,5],[6,6]],
          "length": 4, "health": 21, "last_dir": "up",
          "free_space": 62, "food_eaten": 2},
  "snakes": [ ... every other seat, same order every turn, dead ones included ... ],
  "food": [[0,7],[11,1],[14,6]],
  "moves": [
    {"dir":"up","to":[7,3],"legal":true,"wall":false,"body":"none","food":false,
     "head_risk":"safe","free_space":58}
  ],
  "said": [{"id":"COG-delta","text":"north lane is mine"}],
  "your_notes": "hold the north corridor, alpha is short"
}
```

`moves[]` always has exactly four entries in the wire order `up, right, down, left`, and it
is the **precomputed legal choice set**: `legal` is the resolver's own `willOccupy` plus
bounds, `head_risk` is the resolver's own `headOnOutcome`, and `free_space` is the resolver's
own bounded flood fill. One predicate, four callers — the observation can never claim
something the resolver disagrees with.

**Hidden from a seat:** every seat's real policy name, the other seats' `notes`, the other
seats' pending direction for this turn, the future of the food stream, and `spawnDeal`.

## Reply schema

```json
{"dir":"up","alt":"left","say":"north lane is mine","notes":"cut alpha off at 7,3"}
```

| Field | Cap | Repair |
|---|---|---|
| `dir` | — | unparseable or absent → `alt`, then `last_dir`, then the first legal direction |
| `alt` | — | absent or unparseable → skipped in the ladder |
| `say` | **24 runes**, public | rune-boundary truncation, then the printable shout filter |
| `notes` | **160 runes**, private | newlines collapsed, then rune-boundary truncation |

The whole reply is read with a 4096-byte cap and the JSON is extracted tolerantly (markdown
fences and surrounding prose survive). **Every truncation lands on a rune boundary.** The
validator repairs, never rejects: there is no reply that leaves a snake unactuated.

## The replay

Binary `COWLDSNK`: a header, the config JSON (seed, module, the whole board document, the
cadence constants, `spawnDeal`, the real player names, aliases and colours), the join
records, one direction byte per seat per turn plus a per-turn `gameHash`, and the chat
records (`register`, `directive`, `fallback`, `budget_guard`, `stop`, `result`). Food is not
recorded and does not need to be: the food stream is a pure function of the seed and the
resolution order, so the wasm viewer re-derives every apple and the hash chain proves it.

`python3 tools/replay_summary.py <file>` prints one strict-UTF-8 JSON object describing a
replay, using only the Python 3 standard library.
