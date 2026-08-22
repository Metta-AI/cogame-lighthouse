## Lighthouse static replay viewer, wasm side.
##
## JS hands the raw replay bytes to lh_load_replay; this module parses
## them with the SAME sim code the game server runs, re-derives the
## per-event board states, and exposes the enriched payload (identical
## shape to the game's /replay websocket message) for the shared
## renderer.js to draw.

import
  std/json,
  lighthouse/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc lhLoadReplay*(data: ptr uint8, length: cint): cint
    {.exportc: "lh_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    let recorded = replay["config"]
    var config = defaultGameConfig()
    config.seed = recorded{"seed"}.getInt(0)
    config.maxTicks = recorded{"maxTicks"}.getInt(45)
    config.width = recorded{"width"}.getInt(17)
    config.height = recorded{"height"}.getInt(11)
    config.tideDelay = recorded{"tideDelay"}.getInt(10)
    config.tidePeriod = recorded{"tidePeriod"}.getInt(4)
    config.keyCount = recorded{"keyCount"}.getInt(3)
    config.sampled = true
    for name in replay["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    var states = newJArray()
    ## replayMatch cross-checks the recorded maze against the one the seed
    ## re-derives here, so a wasm/native RNG divergence fails loudly
    ## instead of drawing a different board under the same events.
    for frame in replayMatch(config, events, recorded):
      states.add(frame.boardStateJson())
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("lighthouse.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": states
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc lhPayloadPointer*(): ptr uint8 {.exportc: "lh_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc lhPayloadLength*(): cint {.exportc: "lh_payload_len", cdecl.} =
  cint(payload.len)

proc lhErrorPointer*(): ptr uint8 {.exportc: "lh_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc lhErrorLength*(): cint {.exportc: "lh_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
