## Lighthouse action parsing and scripted rule policies. The game and
## bundled player share this code for validation and timeout fallback.

import std/[algorithm, json, strutils, unicode]
import sim

const StandingMaxAge = 3

type
  ScriptKind* = enum
    skNone = "none"
    skLantern = "lantern"
    skWallhug = "wallhug"
    skAuto = "auto"       ## PLAYER_SCRIPTED=1: whatever the role needs

  Decision* = object
    move*: Move           ## runner seats
    transmit*: bool       ## keeper seat
    message*: string      ## keeper seat
    notes*: string        ## "" when the reply carried none
    scripted*: bool       ## decided by a scripted baseline


proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "lantern" the keeper baseline, "wallhug" the
  ## runner baseline, "1"/"true"/"yes" whichever the dealt slot needs.
  case text.strip().toLowerAscii()
  of "lantern", "keeper": skLantern
  of "wallhug", "runner", "wall-hug": skWallhug
  of "1", "true", "yes": skAuto
  else: skNone

proc roleKind*(seat: int, registered: ScriptKind): ScriptKind =
  ## Role substitution is mandatory: the league seats fillers arbitrarily,
  ## so a baseline dealt the wrong slot plays the other one rather than
  ## stranding the episode.
  if registered == skNone:
    return skNone
  if seat == KeeperSeat: skLantern else: skWallhug

# ---- Text hygiene -----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A
  ## byte-boundary cut renders in a browser and fails a strict JSON parser,
  ## which is how a replay ends up unreadable by everything downstream.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc collapseNewlines*(text: string): string =
  ## Newlines are COLLAPSED to single spaces, per the keeper reply schema:
  ## one run of `\n`/`\r` becomes one space, so a CRLF or a blank line does
  ## not leave two or three spaces in the middle of a subtitle. Spacing the
  ## model typed itself is left alone.
  var index = 0
  while index < text.len:
    if text[index] in {'\n', '\r'}:
      result.add(' ')
      while index < text.len and text[index] in {'\n', '\r'}:
        inc index
    else:
      result.add(text[index])
      inc index

# ---- Direction vocabulary ---------------------------------------------------

proc parseMoveToken*(text: string): Move =
  ## The five legal tokens, case-insensitive, with the obvious aliases.
  ## Anything else is a parse failure.
  case text.strip().toUpperAscii()
  of "N", "NORTH", "UP": mvNorth
  of "S", "SOUTH", "DOWN": mvSouth
  of "E", "EAST", "RIGHT": mvEast
  of "W", "WEST", "LEFT": mvWest
  of "WAIT", "STAY", "HOLD", "H": mvWait
  else:
    raise newException(LighthouseError, "not a move token: " & text)

proc stepWord(move: Move): string =
  if move == mvWait: "hold" else: $move

proc turnRight*(move: Move): Move =
  case move
  of mvNorth: mvEast
  of mvEast: mvSouth
  of mvSouth: mvWest
  of mvWest: mvNorth
  of mvWait: mvWait

proc turnLeft*(move: Move): Move =
  turnRight(turnRight(turnRight(move)))

proc turnBack*(move: Move): Move =
  turnRight(turnRight(move))

# ---- Scripted baseline: lantern (keeper) ------------------------------------

proc firstStep(sim: Sim, field: seq[int], origin: Tile): Move =
  ## The first step of the shortest path to whatever `field` was built
  ## from. Neighbour order N, E, S, W; the maze is a tree, so the path is
  ## unique and the order only fixes the degenerate cases.
  let here = sim.distanceTo(field, origin)
  if here <= 0:
    return mvWait
  for step in Neighbours:
    let nx = origin.x + step[0]
    let ny = origin.y + step[1]
    if sim.isWall(nx, ny) or sim.isFlooded(nx, ny):
      continue
    if sim.distanceTo(field, (nx, ny)) == here - 1:
      return moveOfDelta(step[0], step[1])
  mvWait

proc lanternSteps*(sim: Sim): array[Runners, Move] =
  ## Targets: the nearest uncollected key per runner while keys remain,
  ## then the exit for everyone.
  for index in 0 ..< Runners:
    result[index] = mvWait
  let exitField = sim.bfsFrom(@[sim.exitAt], avoidFlooded = true)
  var keyFields: seq[seq[int]]
  for key in sim.keysOnFloor:
    keyFields.add(sim.bfsFrom(@[key], avoidFlooded = true))

  var target: array[Runners, int]   ## -1 the exit, else a key index
  for index in 0 ..< Runners:
    target[index] = -1
  if sim.keysCollected < sim.config.keyCount and keyFields.len > 0:
    ## Every (active runner, uncollected key) pair, nearest first; ties by
    ## runner index then key index. Greedy over that order.
    var pairs: seq[tuple[distance, runner, key: int]]
    for index in 0 ..< Runners:
      if sim.status[index] != rsActive:
        continue
      for slot in 0 ..< keyFields.len:
        let d = sim.distanceTo(keyFields[slot], sim.pos[index])
        if d >= 0:
          pairs.add((d, index, slot))
    pairs.sort()
    var runnerTaken: array[Runners, bool]
    var keyTaken = newSeq[bool](keyFields.len)
    for entry in pairs:
      if runnerTaken[entry.runner] or keyTaken[entry.key]:
        continue
      runnerTaken[entry.runner] = true
      keyTaken[entry.key] = true
      target[entry.runner] = entry.key

  for index in 0 ..< Runners:
    if sim.status[index] != rsActive:
      continue
    let field = if target[index] < 0: exitField else: keyFields[target[index]]
    ## A transmission lands at the START of the next tick, by which time
    ## the runner has already taken one more step. Aim the order at the
    ## tile it will be standing on when the words arrive, not the one it
    ## is standing on now; ordering the current tile's step produces a
    ## permanent one-tile phase error that oscillates on every corner.
    let now = firstStep(sim, field, sim.pos[index])
    if now == mvWait:
      result[index] = mvWait
      continue
    let step = delta(now)
    let ahead: Tile = (sim.pos[index].x + step.x, sim.pos[index].y + step.y)
    result[index] = firstStep(sim, field, ahead)

proc lanternMessage*(sim: Sim, steps: array[Runners, Move]): string =
  var parts: seq[string]
  for index in 0 ..< Runners:
    if sim.status[index] != rsActive:
      continue
    parts.add(sim.names[index + 1] & " " & stepWord(steps[index]))
  cleanText(parts.join("; "), MaxMessageLen)

proc orderedDirection*(message, alias: string): tuple[found: bool, move: Move] =
  ## The direction this message gives `alias`: the alias, then `:` or
  ## whitespace, then a direction token.
  result = (false, mvWait)
  if message.len == 0 or alias.len == 0:
    return
  let lower = message.toLowerAscii()
  let key = alias.toLowerAscii()
  var start = lower.find(key)
  while start >= 0:
    block probe:
      if start > 0 and lower[start - 1] in {'a'..'z'}:
        break probe
      var index = start + key.len
      if index < lower.len and lower[index] in {'a'..'z'}:
        break probe
      while index < lower.len and
          lower[index] in {' ', '\t', ':', ',', '-', '=', '>', '\n'}:
        inc index
      var stop = index
      while stop < lower.len and lower[stop] in {'a'..'z'}:
        inc stop
      if stop > index:
        try:
          return (true, parseMoveToken(lower[index ..< stop]))
        except LighthouseError:
          discard
    start = lower.find(key, start + 1)

proc clockAtLastMessage(sim: Sim): int =
  ## The clock as it stood when the last transmission went out — the clock
  ## recorded on that tick's `evTick`, which is the tide the runners were
  ## looking at when the words landed. -1 when the keeper has not spoken.
  ## Read from the event log rather than stored: `messages` carries the
  ## tick, and the clock advances by 1 or 2 per tick, so the tick alone
  ## does not give it.
  if sim.messages.len == 0:
    return -1
  let spokenOn = sim.messages[^1][0]
  for index in countdown(sim.events.high, 0):
    if sim.events[index].kind == evTick and sim.events[index].tick == spokenOn:
      return sim.events[index].clock
  -1

proc lanternTransmits*(sim: Sim, steps: array[Runners, Move]): bool =
  ## The baseline pays the tick cost on purpose, on a rhythm plus three
  ## exceptions.
  if sim.tick mod 2 == 0:
    return true
  let last = if sim.messages.len > 0: sim.messages[^1][1] else: ""
  ## "The tide rose SINCE THE LAST MESSAGE" — measured from the clock that
  ## message was sent on, not from a fixed two-clock window: the last word
  ## may be many ticks, and many clock units, older than that.
  let spokenAt = clockAtLastMessage(sim)
  let roseSinceLastWord = spokenAt < 0 or
    tideRowsAt(sim.config, sim.clock) != tideRowsAt(sim.config, spokenAt)
  for index in 0 ..< Runners:
    if sim.status[index] != rsActive:
      continue
    let told = orderedDirection(last, sim.names[index + 1])
    if not told.found:
      return true
    if sim.blocked[index] and told.move != steps[index]:
      return true
    if roseSinceLastWord and sim.pos[index].y + 2 >= sim.waterLine():
      return true
  ## The horn just sounded: everyone needs re-aiming at the exit.
  if sim.gateOpen:
    for event in sim.events:
      if event.kind == evKey and event.tick == sim.tick - 1 and
          event.keysCollected >= sim.config.keyCount:
        return true
  false

proc lanternAction*(sim: Sim): Decision =
  let steps = lanternSteps(sim)
  result.message = lanternMessage(sim, steps)
  ## Never twice in a row: a runner needs the tick in between to act on
  ## what it was told, and a back-to-back pair costs the team two extra
  ## units of tide for one instruction. This is what bounds the baseline
  ## at about half the ticks it plays. An exception may only break the
  ## rhythm to say something NEW — re-sending the standing order verbatim
  ## tells the runners nothing and still costs a unit of tide.
  let justSpoke = sim.messages.len > 0 and
    sim.messages[^1][0] == sim.tick - 1
  let repeat = sim.messages.len > 0 and sim.messages[^1][1] == result.message
  result.transmit = result.message.len > 0 and not justSpoke and
    (sim.tick mod 2 == 0 or (not repeat and lanternTransmits(sim, steps)))
  result.scripted = true

# ---- Scripted baseline: wallhug (runner) ------------------------------------

proc passable*(window: array[3, string], move: Move): bool =
  let step = delta(move)
  let cell = window[step.y + 1][step.x + 1]
  cell notin {'#', '~'}

proc headingOf(sim: Sim, runner: int): Move =
  ## Derived, not stored: the last direction this runner actually took,
  ## north before it has taken one.
  for index in countdown(sim.moveHistory[runner].high, 0):
    let entry = sim.moveHistory[runner][index]
    let token = entry.split(' ')[0]
    if token != $mvWait:
      try:
        return parseMoveToken(token)
      except LighthouseError:
        discard
  mvNorth

proc wallhugAction*(sim: Sim, runner: int): Decision =
  ## Blind: the 3 x 3 window, the inbox or a fresh standing order, and its
  ## own heading. Obeying comes first — that is the grounded
  ## instruction-following floor a champion prompt has to beat.
  result.scripted = true
  result.move = mvWait
  let window = sim.runnerWindow(runner)
  let alias = sim.names[runner + 1]

  var order = orderedDirection(sim.inbox, alias)
  if not order.found:
    let age = sim.standingAge()
    if age >= 0 and age <= StandingMaxAge:
      order = orderedDirection(sim.standing, alias)

  if order.found:
    if order.move == mvWait:
      return
    if passable(window, order.move):
      result.move = order.move
      return
    ## Blocked: the open, unflooded neighbour nearest the ordered compass
    ## angle, clockwise on a tie.
    for candidate in [turnRight(order.move), turnLeft(order.move),
        turnBack(order.move)]:
      if passable(window, candidate):
        result.move = candidate
        return
    return

  ## Left-hand wall following.
  let heading = headingOf(sim, runner)
  for candidate in [turnLeft(heading), heading, turnRight(heading),
      turnBack(heading)]:
    if passable(window, candidate):
      result.move = candidate
      return

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Always legal; never produces notes.
  if roleKind(seat, (if kind == skNone: skAuto else: kind)) == skLantern:
    lanternAction(sim)
  else:
    wallhugAction(sim, seat - 1)

proc decisionJson*(seat: int, decision: Decision): JsonNode =
  ## Complete normal player action for the dealt role.
  if seat == KeeperSeat:
    %*{"transmit": decision.transmit, "message": decision.message,
      "notes": decision.notes}
  else:
    %*{"move": $decision.move, "notes": decision.notes}

# ---- Reply parsing ----------------------------------------------------------

proc parseKeeperReply*(payload: JsonNode): Decision =
  ## `transmit` absent is inferred from a non-empty message; an empty or
  ## whitespace-only message is silence whatever the flag says.
  if payload.kind != JObject or
      not (payload.hasKey("transmit") or payload.hasKey("message") or
        payload.hasKey("notes")):
    raise newException(LighthouseError,
      "no transmit/message/notes in response")
  result.notes = cleanText(payload{"notes"}.getStr(), MaxKeeperNotes)
  result.message = cleanText(
    collapseNewlines(payload{"message"}.getStr()), MaxMessageLen)
  let flag = payload{"transmit"}
  var wants = result.message.len > 0
  if not flag.isNil:
    case flag.kind
    of JBool: wants = flag.getBool()
    of JString: wants = flag.getStr().strip().toLowerAscii() in
      ["1", "true", "yes"]
    of JInt: wants = flag.getInt() != 0
    else: discard
  result.transmit = wants and result.message.len > 0
  if not result.transmit:
    result.message = ""

proc parseRunnerReply*(payload: JsonNode): Decision =
  if payload.kind != JObject:
    raise newException(LighthouseError, "reply is not a JSON object")
  result.notes = cleanText(payload{"notes"}.getStr(), MaxRunnerNotes)
  let node = payload{"move"}
  if node.isNil:
    raise newException(LighthouseError, "no move in response")
  if node.kind != JString:
    raise newException(LighthouseError, "move must be a string: " & $node)
  result.move = parseMoveToken(node.getStr())

proc parseReply*(seat: int, payload: JsonNode): Decision =
  if seat == KeeperSeat: parseKeeperReply(payload)
  else: parseRunnerReply(payload)
