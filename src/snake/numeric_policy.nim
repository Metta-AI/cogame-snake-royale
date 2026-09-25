## Player-side adapter from a frozen numeric policy to a Snake Royale order.

import std/[json, os]
import curly
import numeric_bridge

proc chooseNumericDirection*(request: JsonNode, session: string): int =
  let
    view = request["observation"]
    legal = candidates(view)
    endpoint = getEnv("PLAYER_NUMERIC_URL")
  doAssert endpoint.len > 0
  var mask = newJArray()
  for candidate in legal:
    mask.add(%(candidate.kind != JNull))
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  let key = getEnv("PLAYER_NUMERIC_KEY")
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{"session": session, "seat": request["seat"],
    "decision_id": request["turn"], "values": values(view),
    "action_mask": mask}
  let response = newCurly().post(endpoint, headers, $body,
    max(1, request["deadline_ms"].getInt() div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "numeric policy HTTP " & $response.code)
  result = parseJson(response.body)["choice"].getInt()
  if result notin 0 ..< legal.len or legal[result].kind == JNull:
    raise newException(ValueError, "numeric policy returned an illegal direction")
