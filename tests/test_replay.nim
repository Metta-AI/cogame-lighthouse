## Strict-UTF-8 replay parse. A string truncated on a BYTE boundary
## mid-rune still renders in a browser and still fails a strict JSON
## parser, which is how a replay becomes unreadable to everything
## downstream. Everything a reply can put into the replay is cut on RUNE
## boundaries, and this test proves it end to end — through the very proc
## the wasm viewer exports, compiled natively here.

import std/[json, unicode, unittest]
import lighthouse/[llm, sim]
import "../replay-viewer/lighthouse_replay"

const MultiByte = ["\u2264", "\u2192", "\U0001F30A", "\u00E9", "\u6C34"]

proc runeFill(count: int): string =
  ## `count` runes, none of them ASCII, so every cut position lands
  ## mid-multi-byte unless the truncator is rune-aware.
  for index in 0 ..< count:
    result.add(MultiByte[index mod MultiByte.len])

proc config(): GameConfig =
  result = defaultGameConfig()
  result.seed = 21
  result.maxTicks = 6
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "lighthouse-policy-" & $index))
    result.tokens.add("t" & $index)

proc runeEpisode(): Sim =
  ## Every keeper message and every seat's notes sit exactly on their
  ## truncation boundary.
  result = initSim(config())
  let message = cleanText(runeFill(400), MaxMessageLen)
  var notes: array[Seats, string]
  notes[KeeperSeat] = cleanText(runeFill(900), MaxKeeperNotes)
  for seat in 1 ..< Seats:
    notes[seat] = cleanText(runeFill(500), MaxRunnerNotes)
  check message.runeLen == MaxMessageLen
  check notes[KeeperSeat].runeLen == MaxKeeperNotes
  check notes[1].runeLen == MaxRunnerNotes
  var scripted: array[Seats, bool]
  while not result.done:
    var moves: array[Runners, Move]
    for index in 0 ..< Runners:
      if result.status[index] == rsActive:
        moves[index] = [mvNorth, mvEast, mvSouth, mvWest][
          (result.tick + index) mod 4]
    result.applyTick(true, message & " " & $result.tick, moves, notes,
      scripted)

proc replayPayload(sim: Sim): string =
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  var recorded = sim.seededConfigJson()
  recorded["seed"] = %sim.config.seed
  recorded["maxTicks"] = %sim.config.maxTicks
  recorded["width"] = %sim.config.width
  recorded["height"] = %sim.config.height
  recorded["tideDelay"] = %sim.config.tideDelay
  recorded["tidePeriod"] = %sim.config.tidePeriod
  recorded["keyCount"] = %sim.config.keyCount
  recorded["messageCap"] = %MaxMessageLen
  recorded["sampled"] = %true
  $ %*{
    "protocol": "lighthouse.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": recorded,
    "events": events,
    "results": sim.resultsJson()
  }

suite "replay bytes":
  test "a rune-truncated episode serialises as strict UTF-8 JSON":
    let sim = runeEpisode()
    check sim.messages.len > 0
    let payload = replayPayload(sim)
    check validateUtf8(payload) == -1
    let parsed = parseJson(payload)
    check parsed["protocol"].getStr() == "lighthouse.replay.v1"
    check parsed["events"].len == sim.events.len
    for node in parsed["events"]:
      if node["kind"].getStr() == "say":
        check node["text"].getStr().runeLen <= MaxMessageLen + 6
    ## Byte-identical round trip through the event codec.
    var again = newJArray()
    for node in parsed["events"]:
      again.add(eventFromJson(node).eventToJson())
    check $again == $parsed["events"]

  test "the wasm entry point re-derives every frame from those bytes":
    let sim = runeEpisode()
    var payload = replayPayload(sim)
    ## The SAME proc replay-viewer/lighthouse_replay.nim exports to wasm.
    let ok = lhLoadReplay(cast[ptr uint8](payload[0].addr),
      cint(payload.len))
    if ok != 1:
      var error = newString(lhErrorLength())
      if error.len > 0:
        copyMem(error[0].addr, lhErrorPointer(), error.len)
      echo "lh_load_replay rejected the replay: ", error
    check ok == 1
    var enriched = newString(lhPayloadLength())
    check enriched.len > 0
    copyMem(enriched[0].addr, lhPayloadPointer(), enriched.len)
    check validateUtf8(enriched) == -1
    let node = parseJson(enriched)
    check node["type"].getStr() == "replay"
    check node["states"].len == node["events"].len + 1
    check node["states"].len == sim.events.len + 1
    check $node["states"][^1] == $sim.boardStateJson()

  test "a replay whose recorded maze was edited is rejected":
    let sim = runeEpisode()
    var broken = parseJson(replayPayload(sim))
    var rows = newJArray()
    for index, row in broken["config"]["grid"].getElems():
      var line = row.getStr()
      if index == 3:
        line[1] = (if line[1] == '#': '.' else: '#')
      rows.add(%line)
    broken["config"]["grid"] = rows
    var bytes = $broken
    check lhLoadReplay(cast[ptr uint8](bytes[0].addr), cint(bytes.len)) == 0
    var error = newString(lhErrorLength())
    copyMem(error[0].addr, lhErrorPointer(), error.len)
    check error == "the recorded maze does not match the seeded one"
