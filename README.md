# Snake Royale

Four snakes on a small rectangular grid. Every turn all four move **one cell at the same
time** — nobody sees anybody else's move before it lands. Run into a wall, into anybody's
body (your own included), or out of health, and you are gone. Run your head into somebody
else's head and, on the default board, the **longer snake lives** and the shorter one does
not. Food makes you longer and refills your health; length is the only thing that wins a
head-on; and the board only ever gets smaller. The last snake alive takes the round. It takes
about ninety seconds to watch and one sentence to explain.

The strategy this game is buying is **"who blocks whom"**: with four snakes on 153 cells,
cutting a rival's escape route is far cheaper than out-eating it, and cutting one rival's
route usually helps a third snake more than it helps you. There is a public one-line `say`
channel, so a snake can announce which lane it is taking — and everyone, including the snake
it is about to seal in, reads it.

**A policy is just a prompt.** Both champions are `PLAYER_PROMPT` policies; the two fillers
are scripted baselines; all four run the same image, switched by environment.

## Rule modules

One engine, three presets — `royale` (17×9, walls, food, health, longer head wins), `geese`
(the Kaggle 11×7 torus with the hunger shrink and both-die head-ons) and `tron` (21×9, no
food, the trail never clears). See [`docs/MODULES.md`](docs/MODULES.md).

## Repo layout

| Path | What |
|---|---|
| `src/snake/` | the sim: `board.nim`, `rules.nim` (the resolver), `space.nim` (one bounded BFS), `upstream.nim` (the transcribed upstream facts), plus the server, the commander layer and the replay |
| `src/snake_royale.nim` | the game server, `/bin/snake-royale` |
| `src/snake_royale_player.nim` | the thin seat registrar, `/bin/snake-royale-player` |
| `client/` | the broadcast chrome: `chrome_common.js` (byte-identical to the starter's), `broadcast_core.js` (the grid renderer) and `replay_broadcast.html` (the starter's page plus the appended SNAKE-ROYALE block) |
| `replay-viewer/` | the wasm entry, the emscripten link flags and the static shell |
| `data/` | the board art: nano-banana renders of the Softmax cog, one kit per colourway |
| `scripts/art/` | the source sheets and the split script that made `data/` |
| `tools/ci/` | the CI harness: the docker smoke, the viewer smoke, the renderer fixture, the policy set |
| `docs/` | the rules, the modules, the wire protocol, and the accepted design note |

## Playing a seat

```bash
coworld upload-policy coworld-snake-royale:latest \
  --name my-snake --run /bin/snake-royale-player \
  --secret-env PLAYER_PROMPT="take the direction with the most free space, \
and only eat when your health is under 12"
```

`PLAYER_SCRIPTED=coil` or `PLAYER_SCRIPTED=forager` seats one of the two shipped baselines
instead. A seat that sets neither is `coil`.

## Building

The game is Nim. `ci.yml` is the harness: it runs every `tests/*.nim` in debug and release,
builds the production image and plays one real episode through raw docker
(`tools/ci/docker_smoke.sh`), then builds the static replay-viewer bundle and **opens it in
headless chromium** against the replay that episode produced.

```bash
nim c -r tests/tests.nim                      # the whole suite
docker build -t coworld-snake-royale:ci .     # the production image
./tools/ci/docker_smoke.sh coworld-snake-royale:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

## Watching

Replays are a **static file plus a browser wasm viewer, never a pod**: the manifest declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`, `tools/build_replay_viewer.sh`
compiles the *same* sim module to wasm, and the viewer re-derives every frame from the
recorded direction bytes in the browser. Everything the viewer needs — names, config,
per-turn direction bytes, the seed — lives in the replay bytes; no server is contacted except
S3 for the file.

`python3 tools/replay_summary.py <file>` prints one strict-UTF-8 JSON object describing any
replay, using only the Python 3 standard library.
