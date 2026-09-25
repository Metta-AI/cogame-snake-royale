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

The current champions use `PLAYER_PROMPT`; the two fillers use scripted baselines.
The player image also accepts numeric Fabric choices or Jev choices through the same seat socket.

## Rule modules

One engine, three presets — `royale` (17×9, walls, food, health, longer head wins), `geese`
(the Kaggle 11×7 torus with the hunger shrink and both-die head-ons) and `tron` (21×9, no
food, the trail never clears). See [`docs/MODULES.md`](docs/MODULES.md).

## Repo layout

| Path | What |
|---|---|
| `src/snake/` | the sim: `board.nim`, `rules.nim` (the resolver), `space.nim` (one bounded BFS), `upstream.nim` (the transcribed upstream facts), plus the server, the commander layer and the replay |
| `src/snake_royale.nim` | the game server, `/bin/snake-royale` |
| `src/snake_royale_player.nim` | the seat player for scripted, prompt, numeric, and Jev policies, `/bin/snake-royale-player` |
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

## Training and serving a policy

Build the headless bridge and probe its fixed numeric codec:

```bash
nim c -d:release --path:src -o:snake-numeric-bridge src/snake/numeric_bridge.nim
uv run ./tools/run.py recipes.external.coworld.train --dry-run \
  'command=["/absolute/path/snake-numeric-bridge","royale","0"]' \
  players=4 seat=0 total_timesteps=1024
```

Run the Metta command from a Metta checkout, with the bridge path replaced by its absolute path.
The bridge uses the game's own seat view and turn resolver. It encodes 6,535 values and four directions
for `royale`, `geese`, and `tron`, with the other three seats playing `coil`.
The bridge seat argument and recipe `seat` must agree. Native training needs a CUDA host and exports
a frozen Fabric policy bundle. This local source has been probed and played through complete seeded
episodes; no trained Snake Royale checkpoint has been produced yet.

Start `metta-choice-serve` with that bundle. Set
`PLAYER_NUMERIC_URL=http://<policy-host>:<port>/choice` on the Snake Royale player image.
The player sends the seat-private values and legal mask to the service, then sends its chosen
direction over the normal `/player` socket. `PLAYER_NUMERIC_KEY` supplies an optional bearer key.
Set `PLAYER_JEV=1` for Jev instead; its model transport uses the player's Bedrock sidecar,
`METTA_CAPTURE_URL`, or `TYPESAFE_BASE_URL`. It chooses among the same legal directions.
Neither mode requires a game-side model branch.

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
