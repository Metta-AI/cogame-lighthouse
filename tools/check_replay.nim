## Re-derive the complete native event stream and score from the recorded board.
import std/[json, os]
import lighthouse/[sim, server]

let args = commandLineParams()
doAssert args.len == 1, "usage: check_replay REPLAY"
let payload = parseFile(args[0])
var config = configFromReplay(payload)
for seat in 0 ..< Seats:
  config.players[seat].name = payload["results"]["names"][seat].getStr()
var events: seq[GameEvent]
for event in payload["events"]: events.add(eventFromJson(event))
let frames = replayMatch(config, events, payload["config"])
doAssert frames[^1].resultsJson() == payload["results"]
doAssert frames[^1].events.len == events.len
for index, event in frames[^1].events:
  doAssert event.eventToJson() == events[index].eventToJson()
echo "replay verified"
