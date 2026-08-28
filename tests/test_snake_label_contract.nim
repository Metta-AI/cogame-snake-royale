## The emitted board-label vocabulary equals tests/label_manifest.txt,
## regenerated in the same commit as any label change.

import std/[strutils]
import snake/[labels]
import helpers

var c = newChecker("test_snake_label_contract")

let manifest = readFile("tests/label_manifest.txt")
let emitted = labelManifest()
c.check(manifest == emitted,
  "tests/label_manifest.txt is stale; regenerate it in the same commit as " &
  "the label change. Emitted:\n" & emitted)

for phrase in LabelVocabulary:
  c.check(phrase in manifest, "the manifest carries: " & phrase)
  ## Plain language, never internal notation.
  c.check("slot" notin phrase.toLowerAscii(), phrase & " names no slot index")

c.report()
