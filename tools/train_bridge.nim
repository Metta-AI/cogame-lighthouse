## JSONL numeric bridge over the native Lighthouse simulator.

import std/[hashes, json, os, strutils]
import lighthouse/[sim, rules, player_policy]

var
  game: Sim
  cursor: int
  decisionId: int
  choices: array[Seats, int]
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let seat = game.pendingSeats()[cursor]
  let prompts = promptsFromView(game.seatDecisionView(seat), "")
  let system = prompts.system
  let user = prompts.user
  %*{"kind": "decision", "game": "lighthouse",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.tick,
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(hash(command["seed"].getStr()) and 0x7FFFFFFF)
  var config = defaultGameConfig()
  config.update($variantConfig)
  config = config.sampleEpisode()
  game = initSim(config)
  cursor = 0
  decisionId = 0
  choices = [0, 0, 0, 0]
  currentDecision()

proc encode(): JsonNode =
  let seat = game.pendingSeats()[cursor]
  var values = newJArray()
  for name in ["standard", "spring-tide"]:
    values.add(%(if variant == name: 1 else: 0))
  for player in 0 ..< Seats:
    values.add(%(if seat == player: 1 else: 0))
  values.add(%(float(game.tick) / float(game.config.maxTicks)))
  values.add(%(if seat == KeeperSeat:
    float(game.clock) / float(game.floodClock()) else: 0.0))
  values.add(%(float(game.keysCollected) / float(game.config.keyCount)))
  values.add(%(if game.gateOpen: 1 else: 0))
  values.add(%(if seat == KeeperSeat:
    float(game.escapedCount) / float(Runners) else: 0.0))
  values.add(%(if seat == KeeperSeat:
    float(game.drownedCount) / float(Runners) else: 0.0))
  var visible: seq[char]
  if seat == KeeperSeat:
    for line in game.keeperView().splitLines():
      for glyph in line: visible.add(glyph)
  else:
    for line in game.runnerWindow(seat - 1):
      for glyph in line: visible.add(glyph)
  for slot in 0 ..< 99:
    let glyph = if slot < visible.len: visible[slot] else: '\0'
    values.add(%(float(ord(glyph)) / 126.0))
    values.add(%(if slot < visible.len: 1 else: 0))
  if seat == KeeperSeat:
    for unused in 0 ..< 9: values.add(%0.0)
  else:
    let runner = seat - 1
    values.add(%(float(game.keysHeld[runner]) / float(game.config.keyCount)))
    for move in Move:
      values.add(%(if game.lastMove[runner] == move: 1 else: 0))
    values.add(%(if game.blocked[runner]: 1 else: 0))
    values.add(%(float(game.standingAge()) / float(game.config.maxTicks)))
    values.add(%(if game.inbox.len > 0: 1 else: 0))
  doAssert values.len == 219
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  let seats = game.pendingSeats()
  choices[seats[cursor]] = choice
  inc decisionId
  inc cursor
  if cursor == seats.len:
    var
      spoke = false
      message = ""
      moves: array[Runners, Move]
      notes: array[Seats, string]
      scripted: array[Seats, bool]
    for seat in seats:
      var decision = scriptedAction(game, seat, skAuto)
      if choices[seat] == 1:
        if seat == KeeperSeat:
          decision.transmit = false
          decision.message = ""
        else:
          decision.move = mvWait
      scripted[seat] = true
      notes[seat] = decision.notes
      if seat == KeeperSeat:
        spoke = decision.transmit
        message = decision.message
      else:
        moves[seat - 1] = decision.move
    game.applyTick(spoke, message, moves, notes, scripted)
    cursor = 0
  let observation = if game.done:
    let score = game.teamScore()
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 ..< Seats:
      scores[$seat] = %score
      utilities[$seat] = %(score / 42.0)
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: lighthouse-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "spring-tide"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
