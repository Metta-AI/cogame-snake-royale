# Snake Royale — rules

Four snakes on a small rectangular grid. Every turn all four move **one cell at the same
time** — nobody sees anybody else's move before it lands. Run into a wall, into anybody's
body (your own included), or out of health, and you are gone. Run your head into somebody
else's head and, on the default board, the **longer snake lives** and the shorter one does
not. Food makes you longer and refills your health; length is the only thing that wins a
head-on; and the board only ever gets smaller. The last snake alive takes the round.

## The board

An integer grid of `boardW × boardH` cells. Coordinates are `[x, y]` with **x growing right
and y growing down**; `[0,0]` is the top-left. `up` = y−1, `right` = x+1, `down` = y+1,
`left` = x−1.

The four **spawn anchors** are the fixed points `(w div 4, h div 4)`,
`(w − 1 − w div 4, h div 4)`, `(w div 4, h − 1 − h div 4)`,
`(w − 1 − w div 4, h − 1 − h div 4)` — derived from the dimensions, not authored. A snake
starts with `startLength` segments all stacked on its anchor, and its `last_dir` is the axis
with the larger absolute delta toward the board centre, x winning a tie. On turn 1 there is
no neck, so all four directions are legal.

## Turn structure — the exact resolution order

1. `turn += 1`.
2. **Neck repair.** If `head + dir` is the second body segment, use `alt` if it is present
   and is not the neck, else `last_dir`. `reverseRepaired` counts it either way. The repair
   never invents a *legal* move — if `last_dir` walks into a wall, step 4 kills the snake.
3. **Targets.** `target = head + d`, modulo the board when it wraps. `last_dir = d`.
4. **Wall deaths** (walled boards only), cause `wall`.
5. **Heads move.**
6. **Eat.** Remove the food, keep the tail this turn, `health = healthStart`.
7. **Tails.** Unless the board leaves a trail and unless the snake ate, pop the last segment.
8. **Hunger.** `health -= 1` and zero kills, cause `starve`. On a shrink turn every live
   snake pops one more segment; length zero dies.
9. **Head-to-head.** `longer_wins` and exactly one strictly greatest post-step-8 length →
   that one survives; otherwise everybody in the cell dies. Head-ons resolve **before** body
   collisions on purpose: without that ordering the winner would immediately be killed by the
   loser's neck.
10. **Body collisions**, against occupancy frozen after steps 5–9. A snake may legally follow
    a **vacating tail**, but not the tail of a snake that ate this turn. A snake killed in
    step 4, 8 or 9 still occupies the board for this test — with exactly one exception, the
    head cell of a head-on **loser**, which the winner legitimately holds (§Divergences 6).
11. **Remove the dead.**
12. **Food respawn** from a separate seeded stream (`seed xor 0x5EED`), so a change to seat
    behaviour can never shift the food draw.
13. **Derived measurements**: `freeSpace`, the `trapped` flag, the alliance audit.
14. **Bubbles age**, the `gameHash` folds over the whole board state, and the turn's
    direction byte plus the hash are appended to the replay.
15. **End evaluation**: one or zero snakes alive ends it (`last_standing`); `maxTurns` ends
    it (`full_time`).

## Scoring

Every seat is ranked, descending, by `(survivedTurns, finalLength, foodEaten)`. Places 1..4
pay `[+1000, +333, −333, −1000]` permille; a tied group splits its slice exactly with
`floorDiv` / `floorMod`, the first `rem` members in ascending slot order taking one extra
permille. `scores[s] = scorePermille[s] / 1000`, **higher is better**, and the four scores
sum to exactly zero.

`finalLength`, `maxLength`, `foodEaten`, `declinedKills`, `trappedTurns`, `reverseRepaired`
and `saidTurns` are measured and shown, never scored.

## The alliance audit

`declinedKills[s]` counts the turns on which seat `s` had a **free kill and did not take it**:
some direction was legal, its target was reachable by exactly one opponent's head, the
head-on outcome was `win`, the move's free space was at least the seat's own length — and the
seat moved somewhere else. It is computed by the same `headOnOutcome` / `willOccupy` /
`freeSpaceFrom` procs the resolver uses, and it is **not** in `scores`.

## Divergences from the upstreams

1. Hungry Geese shrinks every 40 steps; `geese` uses 20 so the hunger clock bites twice in a
   50-turn episode.
2. Battlesnake health is 100; `royale` uses 30 across 50 turns for the same pressure.
3. Hungry Geese starts at length 1; every module except `tron` starts at 3.
4. Naming your own neck is a death upstream; here it is **repaired** and counted. A model's
   formatting slip must not be an instant loss.
5. Battlesnake hazards are not implemented in v1.

### From this game's own design note

6. **Step 10 and the head-on winner.** The note's step 10 says a snake killed in step 4, 8 or
   9 "still occupies the board for this test" without qualification, while its step 9 says
   head-ons resolve *before* body collisions precisely so that the winner is not "immediately
   killed by the loser's neck". The two sentences disagree about exactly one cell: after step
   5 a head-on loser's head IS the winner's head cell, so leaving it blocked would kill the
   winner on its victim's corpse and `longer_wins` would decide nothing. The resolver
   (`src/snake/rules.nim`, step 10) therefore frees that ONE cell and blocks everything else a
   corpse holds — the loser's neck and the rest of its body, and the whole body **including
   the head** of a snake killed by a wall or by hunger. `tests/test_snake_sim.nim` blocks 8
   and 9 pin both halves: the head-on winner lives and holds the contested cell, and a
   starved snake's corpse still kills a rival that walks into it on the same turn.
