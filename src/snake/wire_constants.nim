## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the colourways). Historically
## each HTML client re-typed these as literals and nothing enforced agreement.
## This module renders them ONCE, from the same Nim consts the engine runs on;
## `server.nim` splices the block into every served client page, and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle. Clients
## read `window.SNAKE_WIRE` and keep their old literals only as fallbacks for
## raw file opens of the un-spliced sources.

import std/strutils
import roster, sim_types

proc jsNumArray(values: openArray[float]): string =
  ## Playback multipliers are floats now that 0.5x exists. Whole values are
  ## emitted without a fractional part so `speeds` still reads [0.5,1,2,...]
  ## and a chip's key compares equal to the frame packet's integral `sp`.
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    if v == float(int(v)): result.add $int(v)
    else: result.add formatFloat(v, ffDecimal, 1)
  result.add "]"

proc jsStrArray(values: openArray[string]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add "\"" & v & "\""
  result.add "]"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.SNAKE_WIRE).

const WireConstantsJs* =
  "window.SNAKE_WIRE={speeds:" & jsNumArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",seats:" & $Seats &
  ",maxSayRunes:" & $MaxSayRunes &
  ",colours:" & jsStrArray(Colours) &
  ",colourHex:" & jsStrArray(ColourHex) &
  ",aliases:" & jsStrArray(["COG-alpha", "COG-beta", "COG-gamma", "COG-delta"]) &
  "};"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
