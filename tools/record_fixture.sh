#!/usr/bin/env bash
# Re-record the three replay fixtures, one per rule module.
#
# The RECIPES are the source of truth (the starter's fixture-recipe
# discipline, and tests/test_snake_replay.nim asserts this file still carries
# them). Re-run on every GameVersion bump:
#
#   tools/record_fixture.sh            # writes tests/fixtures/*.replay
#
# recipes: <name> <module> <seed> <maxTurns>
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
mkdir -p tests/fixtures

# royale seed 42, geese seed 7, tron seed 13 -- the three module recipes.
recipes=(
  "royale-seed42 royale 42 40"
  "geese-seed7 geese 7 40"
  "tron-seed13 tron 13 40"
)

for recipe in "${recipes[@]}"; do
  set -- $recipe
  name="$1"; module="$2"; seed="$3"; turns="$4"
  echo "recording tests/fixtures/${name}.replay (${module}, seed ${seed}, ${turns} turns)"
  nim r --hints:off -d:release --path:src tools/record_fixture.nim \
    "tests/fixtures/${name}.replay" "$module" "$seed" "$turns"
done
