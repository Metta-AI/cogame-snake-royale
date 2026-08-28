# Rule modules

One engine, three named presets of the same eight switches. `module` selects a preset; every
switch is also independently settable in a `game_config`.

| Switch | `royale` (default) | `geese` | `tron` |
|---|---|---|---|
| `boardW` × `boardH` | 17 × 9 | 11 × 7 | 21 × 9 |
| `wrap` (torus) | `false` — walls | `true` — torus | `false` — walls |
| `foodCount` | 3 | 2 | 0 |
| `healthStart` (0 = off) | 30 | 0 | 0 |
| `shrinkEvery` (0 = off) | 0 | 20 | 0 |
| `leaveTrail` | `false` | `false` | `true` |
| `headToHead` | `longer_wins` | `both_die` | `both_die` |
| `startLength` | 3 | 3 | 1 |
| `maxTurns` | 50 | 50 | 50 |

`royale` is the merged flagship and the league's default. `geese` is the faithful Kaggle
board — 11 columns by 7 rows, a torus, the hunger shrink, both-die head-ons. `tron` is the
same engine with growth and food switched off, which is the cheapest possible proof that the
rule-module axis is real.

Why `royale` has **walls** while `geese` has a **torus**: on screen a torus is a lie — a
snake crossing the left edge reappears on the right and a spectator loses it. Walls make the
trap story readable, so the flagship module has walls and the faithful-Kaggle module keeps
the torus it is faithful to. The `geese` viewer draws **wrap ghosts** precisely because a
torus needs the help.

Why 17 × 9: 153 cells with four snakes is dense enough that turn 20 already has choke points,
and the 1.889 aspect is the embed frame's own aspect, so almost nothing is letterboxed at
360 px.
