## Jev chooses among the same legal directions offered to numeric policies.

import std/[json, os, strutils]
import curly
import numeric_bridge

const DirectionNames = ["up", "right", "down", "left"]

proc chooseJevDirection*(request: JsonNode): int =
  let view = request["observation"]
  let legal = candidates(view)
  var criteria = newJObject()
  for index in 0 ..< legal.len:
    let candidate = legal[index]
    if candidate.kind != JNull:
      criteria[DirectionNames[index]] = %("Move " & DirectionNames[index] &
        " this turn")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint, model, key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Snake Royale Jev has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $request["seat"].getInt()
  let body = %*{"model": model,
    "state": "You are playing Snake Royale. Choose a direction using only " &
      "this seat's observation: " & $view,
    "questions": {"decision": {"type": "choice",
      "instructions": "Choose one legal direction for this turn.",
      "criteria": criteria}}}
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body,
    max(1, min(30, (request["deadline_ms"].getInt() - 1000) div 1000)))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answer = parseJson(response.body)["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong direction set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for direction, probability in probabilities.pairs:
    if not criteria.hasKey(direction):
      raise newException(ValueError, "Jev returned an unknown direction")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = direction
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  for index, name in DirectionNames:
    if name == selected: return index
  raise newException(ValueError, "Jev did not select a direction")
