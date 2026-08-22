## Pure game rules for Lighthouse. No IO, no networking, no LLM — the
## server, the tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded maze with its exit, runner
## starts and keys, the live positions and statuses, the keeper's message
## history, each seat's private notes, and the append-only event log.
## Everything random is drawn from the seed at `initSim`, so a replay
## re-derives the episode from the recorded tick events alone.

import std/[algorithm, json, math, random, strutils], types

export types

const
  ## An episode's whole model-call allowance (four calls per tick: the
  ## keeper and three runners). A hosted episode is killed if it outlives
  ## the platform's artifact timeout, so `maxTicks` is capped to this at
  ## sample time.
  EpisodeCallBudget* = 220
  CallsPerTick* = 4
  MinTicks* = 4
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 15_000
  Seats* = 4
  Runners* = 3
  KeeperSeat* = 0
  ## Rune caps on everything a reply can put into the replay.
  MaxMessageLen* = 160
  MaxKeeperNotes* = 400
  MaxRunnerNotes* = 200
  ## The keeper is in the lantern room; lighthouse names for it.
  KeeperNames* = [
    "Fresnel", "Beacon", "Lantern", "Halyard", "Pharos", "Argand"
  ]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## Neighbour order for every deterministic scan: N, E, S, W.
  Neighbours* = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  ## Rooms are the odd/odd tiles; a room's four neighbours are +-2 away.
  RoomSteps = [(0, -2), (2, 0), (0, 2), (-2, 0)]

type
  Tile* = tuple[x, y: int]

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## 4 anonymous aliases, keeper first
    grid*: seq[string]               ## height strings of width '#'/'.'
    exitAt*: Tile
    starts*: array[Runners, Tile]
    keysAt*: seq[Tile]               ## where the keys started
    keysOnFloor*: seq[Tile]          ## uncollected keys
    pos*: array[Runners, Tile]       ## (-1, -1) once resolved
    status*: array[Runners, RunnerStatus]
    keysHeld*: array[Runners, int]
    lastMove*: array[Runners, Move]
    blocked*: array[Runners, bool]
    moveHistory*: array[Runners, seq[string]]
    keysCollected*: int
    gateOpen*: bool
    escapedCount*: int
    drownedCount*: int
    tick*: int
    clock*: int
    messages*: seq[(int, string)]    ## (tick transmitted, text)
    inbox*: string                   ## delivered at the start of this tick
    standing*: string                ## latest non-empty message
    standingTick*: int               ## the tick it was transmitted on
    notes*: array[Seats, string]
    scripted*: array[Seats, bool]
    done*: bool
    reason*: string                  ## "complete" | "timeup" | "deadline"
    events*: seq[GameEvent]

# ---- Geometry ---------------------------------------------------------------

proc delta*(move: Move): Tile =
  case move
  of mvWait: (0, 0)
  of mvNorth: (0, -1)
  of mvSouth: (0, 1)
  of mvEast: (1, 0)
  of mvWest: (-1, 0)

proc moveOfDelta*(dx, dy: int): Move =
  if dx == 0 and dy == -1: mvNorth
  elif dx == 0 and dy == 1: mvSouth
  elif dx == 1 and dy == 0: mvEast
  elif dx == -1 and dy == 0: mvWest
  else: mvWait

proc inBounds*(sim: Sim, x, y: int): bool =
  x >= 0 and y >= 0 and x < sim.config.width and y < sim.config.height

proc isWall*(sim: Sim, x, y: int): bool =
  if not sim.inBounds(x, y):
    return true
  sim.grid[y][x] == '#'

proc tideRows*(sim: Sim): int =
  ## Flooded rows, counted from the bottom. Monotone in the clock.
  clamp((sim.clock - sim.config.tideDelay) div sim.config.tidePeriod, 0,
    sim.config.height)

proc tideRowsAt*(config: GameConfig, clock: int): int =
  clamp((clock - config.tideDelay) div config.tidePeriod, 0, config.height)

proc waterLine*(sim: Sim): int =
  ## y of the topmost flooded row; == height while the board is dry.
  sim.config.height - sim.tideRows()

proc floodClock*(sim: Sim): int =
  sim.config.tideDelay + sim.config.height * sim.config.tidePeriod

proc isFlooded*(sim: Sim, x, y: int): bool =
  if not sim.inBounds(x, y):
    return false
  y >= sim.waterLine()

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the maze: every seat plays under an
  ## anonymous alias, drawn deterministically from the seed so replays and
  ## the live stage agree. Slot 0 is the keeper and draws from the lantern
  ## names; the runners draw from the cog names.
  var rng = initRand(int64(seed) * 6779 + 31)
  var keepers = @KeeperNames
  var cogs = @CogNames
  rng.shuffle(keepers)
  rng.shuffle(cogs)
  for index in 0 ..< players.len:
    if index == KeeperSeat:
      result.add(keepers[0])
    elif index - 1 < cogs.len:
      result.add(cogs[index - 1])
    else:
      result.add("Cog " & $index)

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the tick count into one episode's call budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  result.maxTicks =
    max(min(config.maxTicks, EpisodeCallBudget div CallsPerTick), MinTicks)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.maxTicks, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, tick: -1, seat: -1, x: -1, y: -1)

proc carveMaze(rng: var Rand, width, height: int): seq[string] =
  ## Randomised depth-first search (recursive backtracker) over the odd/odd
  ## rooms: a PERFECT maze, exactly one path between any two floor tiles.
  var grid = newSeq[string](height)
  for y in 0 ..< height:
    grid[y] = repeat('#', width)
  var visited = newSeq[bool](width * height)
  ## An explicit stack, in the exact order the recursion would visit: on
  ## entering a room, shuffle its four neighbours and take the first
  ## unvisited one, carving the wall tile between.
  var stack: seq[tuple[x, y, cursor: int, order: array[4, int]]]
  var order = [0, 1, 2, 3]
  rng.shuffle(order)
  grid[height - 2][1] = '.'
  visited[(height - 2) * width + 1] = true
  stack.add((x: 1, y: height - 2, cursor: 0, order: order))
  while stack.len > 0:
    let top = stack[^1]
    if top.cursor >= RoomSteps.len:
      discard stack.pop()
      continue
    stack[^1].cursor = top.cursor + 1
    let step = RoomSteps[top.order[top.cursor]]
    let nx = top.x + step[0]
    let ny = top.y + step[1]
    if nx <= 0 or ny <= 0 or nx >= width - 1 or ny >= height - 1:
      continue
    if visited[ny * width + nx]:
      continue
    grid[top.y + step[1] div 2][top.x + step[0] div 2] = '.'
    grid[ny][nx] = '.'
    visited[ny * width + nx] = true
    var next = [0, 1, 2, 3]
    rng.shuffle(next)
    stack.add((x: nx, y: ny, cursor: 0, order: next))
  grid

proc bfsFrom*(sim: Sim, sources: seq[Tile], avoidFlooded: bool): seq[int] =
  ## Distance field over floor tiles, -1 where unreachable. When
  ## `avoidFlooded` the water is impassable.
  let width = sim.config.width
  let height = sim.config.height
  result = newSeq[int](width * height)
  for index in 0 ..< result.len:
    result[index] = -1
  var frontier: seq[Tile]
  for source in sources:
    if not sim.inBounds(source.x, source.y):
      continue
    if sim.isWall(source.x, source.y):
      continue
    if avoidFlooded and sim.isFlooded(source.x, source.y):
      continue
    if result[source.y * width + source.x] >= 0:
      continue
    result[source.y * width + source.x] = 0
    frontier.add(source)
  var head = 0
  while head < frontier.len:
    let cell = frontier[head]
    inc head
    let base = result[cell.y * width + cell.x]
    for step in Neighbours:
      let nx = cell.x + step[0]
      let ny = cell.y + step[1]
      if sim.isWall(nx, ny):
        continue
      if avoidFlooded and sim.isFlooded(nx, ny):
        continue
      if result[ny * width + nx] >= 0:
        continue
      result[ny * width + nx] = base + 1
      frontier.add((nx, ny))

proc distanceTo*(sim: Sim, field: seq[int], tile: Tile): int =
  if not sim.inBounds(tile.x, tile.y):
    return -1
  field[tile.y * sim.config.width + tile.x]

proc openNeighbourCount*(sim: Sim, x, y: int): int =
  for step in Neighbours:
    if not sim.isWall(x + step[0], y + step[1]):
      inc result

proc placeExit(rng: var Rand, sim: var Sim) =
  let odds = (sim.config.width - 1) div 2       ## odd x in 1 .. width - 2
  let exitX = 1 + 2 * rng.rand(odds - 1)
  sim.grid[0][exitX] = '.'
  sim.exitAt = (exitX, 0)

proc placeStarts(rng: var Rand, sim: var Sim) =
  let row = sim.config.height - 2
  var rooms: seq[int]
  var x = 1
  while x <= sim.config.width - 2:
    rooms.add(x)
    x += 2
  var chosen: seq[int]
  for attempt in 0 ..< 50:
    var pool = rooms
    rng.shuffle(pool)
    var trial = pool[0 ..< min(Runners, pool.len)]
    trial.sort()
    var ok = trial.len == Runners
    if ok:
      for a in 0 ..< trial.len:
        for b in a + 1 ..< trial.len:
          if abs(trial[a] - trial[b]) < 4:
            ok = false
    if ok:
      chosen = trial
      break
  if chosen.len != Runners:
    chosen = @[rooms[0], rooms[rooms.len div 2], rooms[^1]]
  for index in 0 ..< Runners:
    sim.starts[index] = (chosen[index], row)
    sim.pos[index] = sim.starts[index]

proc rankByExitDistance(field: seq[int], width: int, tiles: seq[Tile],
    nearestFirst = false): seq[Tile] =
  ## Ordered by maze distance from the exit; (y, x) breaks ties so the
  ## order is total and the draw is reproducible from the seed.
  var ranked: seq[tuple[distance, y, x: int]]
  for tile in tiles:
    let d = field[tile.y * width + tile.x]
    ranked.add(((if nearestFirst: d else: -d), tile.y, tile.x))
  ranked.sort()
  for entry in ranked:
    result.add((entry.x, entry.y))

proc placeKeys(rng: var Rand, sim: var Sim) =
  let width = sim.config.width
  let exitField = sim.bfsFrom(@[sim.exitAt], avoidFlooded = false)
  let limit = sim.config.height - 4
  var startSet: seq[Tile]
  for index in 0 ..< Runners:
    startSet.add(sim.starts[index])
  var candidates: seq[Tile]
  var y = 1
  while y <= limit:
    var x = 1
    while x <= sim.config.width - 2:
      let tile: Tile = (x, y)
      if sim.openNeighbourCount(x, y) == 1 and
          tile notin startSet and tile != sim.exitAt and
          abs(x - sim.exitAt.x) + abs(y - sim.exitAt.y) > 1 and
          sim.distanceTo(exitField, tile) >= 0:
        candidates.add(tile)
      x += 2
    y += 2
  ## Nearest dead ends first, not farthest: a key in the far tail of a
  ## perfect maze cannot be fetched and carried back inside the tick
  ## budget. See README, "Deviations". The dead-end filter still means a
  ## blind runner cannot find one without the keeper.
  candidates = rankByExitDistance(exitField, width, candidates,
    nearestFirst = true)

  let want = sim.config.keyCount
  if candidates.len < want:
    ## Total fallback: the farthest floor tiles above the drowning rows.
    var tiles: seq[Tile]
    for yy in 0 .. limit:
      for xx in 0 ..< width:
        let tile: Tile = (xx, yy)
        if not sim.isWall(xx, yy) and tile != sim.exitAt and
            tile notin startSet and
            abs(xx - sim.exitAt.x) + abs(yy - sim.exitAt.y) > 1 and
            sim.distanceTo(exitField, tile) >= 0:
          tiles.add(tile)
    tiles = rankByExitDistance(exitField, width, tiles)
    var picked: seq[Tile]
    for tile in tiles:
      if picked.len >= want:
        break
      var far = true
      for taken in picked:
        if sim.distanceTo(sim.bfsFrom(@[taken], avoidFlooded = false),
            tile) < 6:
          far = false
      if far:
        picked.add(tile)
    for tile in tiles:
      if picked.len >= want:
        break
      if tile notin picked:
        picked.add(tile)
    sim.keysAt = picked
    sim.keysOnFloor = picked
    return

  let pool = candidates[0 ..< min(8, candidates.len)]
  var chosen: seq[Tile]
  if pool.len >= want:
    for attempt in 0 ..< 50:
      var order: seq[int]
      for index in 0 ..< pool.len:
        order.add(index)
      rng.shuffle(order)
      var trial: seq[Tile]
      for index in order[0 ..< want]:
        trial.add(pool[index])
      var ok = true
      for a in 0 ..< trial.len:
        let field = sim.bfsFrom(@[trial[a]], avoidFlooded = false)
        for b in a + 1 ..< trial.len:
          if sim.distanceTo(field, trial[b]) < 6:
            ok = false
      if ok:
        chosen = trial
        break
  if chosen.len != want:
    chosen = candidates[0 ..< want]
  ## A stable board order so the viewer and the keeper's map agree.
  var ordered: seq[tuple[y, x: int]]
  for tile in chosen:
    ordered.add((tile.y, tile.x))
  ordered.sort()
  sim.keysAt = @[]
  for entry in ordered:
    sim.keysAt.add((entry.x, entry.y))
  sim.keysOnFloor = sim.keysAt

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(LighthouseError,
      "lighthouse needs exactly " & $Seats & " players")
  if config.maxTicks < MinTicks:
    raise newException(LighthouseError,
      "maxTicks must be at least " & $MinTicks)
  if config.width < 9 or config.width mod 2 == 0 or
      config.height < 9 or config.height mod 2 == 0:
    raise newException(LighthouseError,
      "the board must be odd by odd and at least 9 x 9")
  if config.tidePeriod < 1:
    raise newException(LighthouseError, "tidePeriod must be at least 1")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: maze, exit, starts, keys.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  result.grid = carveMaze(rng, config.width, config.height)
  placeExit(rng, result)
  placeStarts(rng, result)
  placeKeys(rng, result)
  for index in 0 ..< Runners:
    result.status[index] = rsActive
    result.lastMove[index] = mvWait
  result.standingTick = -1
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc pendingSeats*(sim: Sim): seq[int] =
  ## The seats whose decision this tick is still due: the keeper always,
  ## plus every runner still in the maze. Empty once the episode is over.
  if sim.done:
    return
  result.add(KeeperSeat)
  for index in 0 ..< Runners:
    if sim.status[index] == rsActive:
      result.add(index + 1)

proc runnerAt(sim: Sim, x, y: int): int =
  ## 1..3 when a live runner stands on the tile, else -1.
  for index in 0 ..< Runners:
    if sim.status[index] == rsActive and sim.pos[index] == (x, y):
      return index + 1
  -1

proc glyphAt*(sim: Sim, x, y: int): char =
  ## The keeper's map glyph for one tile: runner over exit over key over
  ## water over floor over wall.
  if not sim.inBounds(x, y):
    return '#'
  let runner = sim.runnerAt(x, y)
  if runner > 0:
    return char(ord('0') + runner)
  if (x, y) == sim.exitAt:
    return (if sim.gateOpen: 'O' else: 'E')
  if (x, y) in sim.keysOnFloor:
    return 'K'
  if sim.isWall(x, y):
    return '#'
  if sim.isFlooded(x, y):
    return '~'
  '.'

proc keeperView*(sim: Sim): string =
  ## The whole board, `height` lines of `width` characters.
  var lines: seq[string]
  for y in 0 ..< sim.config.height:
    var line = newString(sim.config.width)
    for x in 0 ..< sim.config.width:
      line[x] = sim.glyphAt(x, y)
    lines.add(line)
  lines.join("\n")

proc runnerWindow*(sim: Sim, runner: int): array[3, string] =
  ## The runner's 3 x 3 window, `@` for itself, `#` off the grid.
  let here = sim.pos[runner]
  for dy in -1 .. 1:
    var line = newString(3)
    for dx in -1 .. 1:
      let x = here.x + dx
      let y = here.y + dy
      line[dx + 1] =
        if dx == 0 and dy == 0: '@'
        else: sim.glyphAt(x, y)
    result[dy + 1] = line

proc teamScore*(sim: Sim): float =
  ## Fully cooperative and identical for every seat. Higher is better.
  let k = sim.keysCollected.float / max(sim.config.keyCount, 1).float
  let e = sim.escapedCount.float
  var bonus = 0.0
  if sim.escapedCount == Runners:
    bonus = clamp(1.0 - sim.clock.float / max(sim.floodClock(), 1).float,
      0.0, 1.0)
  6.0 * clamp(k, 0.0, 1.0) + 10.0 * e + 6.0 * bonus

proc roleName*(seat: int): string =
  if seat == KeeperSeat: "keeper" else: "runner"

proc standingAge*(sim: Sim): int =
  if sim.standingTick < 0: -1 else: sim.tick - sim.standingTick

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  var event = blankEvent(evEnd)
  event.tick = sim.tick
  event.text = reason
  sim.addEvent(event)

proc applyTick*(sim: var Sim, spoke: bool, message: string,
    moves: array[Runners, Move], notes: array[Seats, string],
    scripted: array[Seats, bool]) =
  ## Steps 3 to 12 of the resolution order, in that order, in one call.
  ## A blocked move is a bump, not an error.
  if sim.done:
    raise newException(LighthouseError, "the episode is over")
  var wasActive: array[Runners, bool]
  for index in 0 ..< Runners:
    wasActive[index] = sim.status[index] == rsActive
    if not wasActive[index] and moves[index] != mvWait:
      raise newException(LighthouseError,
        "runner " & $(index + 1) & " has already left the maze")
  let tick = sim.tick

  for seat in 0 ..< Seats:
    if notes[seat].len > 0:
      sim.notes[seat] = notes[seat]
  sim.scripted = scripted

  # 3. Keeper transmit.
  let text = message.strip()
  let talking = spoke and text.len > 0
  if talking:
    sim.messages.add((tick, text))
    var event = blankEvent(evSay)
    event.tick = tick
    event.seat = KeeperSeat
    event.cost = 1
    event.text = text
    sim.addEvent(event)

  # 4. Runner moves, in seat order.
  for index in 0 ..< Runners:
    sim.blocked[index] = false
    if not wasActive[index]:
      sim.lastMove[index] = mvWait
      continue
    let move = moves[index]
    sim.lastMove[index] = move
    let step = delta(move)
    let target: Tile = (sim.pos[index].x + step.x, sim.pos[index].y + step.y)
    if sim.isWall(target.x, target.y) or sim.isFlooded(target.x, target.y):
      sim.blocked[index] = true
    else:
      sim.pos[index] = target
    sim.moveHistory[index].add(
      $move & (if sim.blocked[index]: " (blocked)" else: ""))

  # 5. Key pickup, in seat order.
  for index in 0 ..< Runners:
    if not wasActive[index]:
      continue
    let here = sim.pos[index]
    let slot = sim.keysOnFloor.find(here)
    if slot >= 0:
      sim.keysOnFloor.delete(slot)
      inc sim.keysCollected
      inc sim.keysHeld[index]
      var event = blankEvent(evKey)
      event.tick = tick
      event.seat = index + 1
      event.x = here.x
      event.y = here.y
      event.keysCollected = sim.keysCollected
      sim.addEvent(event)

  # 6. Gate: a single global latch that never closes.
  if sim.keysCollected >= sim.config.keyCount:
    sim.gateOpen = true

  # 7. Exit, in seat order.
  for index in 0 ..< Runners:
    if not wasActive[index] or sim.status[index] != rsActive:
      continue
    if sim.gateOpen and sim.pos[index] == sim.exitAt:
      sim.status[index] = rsEscaped
      inc sim.escapedCount
      var event = blankEvent(evEscape)
      event.tick = tick
      event.seat = index + 1
      event.escaped = sim.escapedCount
      sim.addEvent(event)
      sim.pos[index] = (-1, -1)

  # 8. Clock: a transmit costs the team one extra unit of tide.
  sim.clock += 1 + (if talking: 1 else: 0)

  # 9/10. Tide is a pure function of the clock; drown whoever it caught.
  for index in 0 ..< Runners:
    if sim.status[index] != rsActive:
      continue
    let here = sim.pos[index]
    if sim.isFlooded(here.x, here.y):
      sim.status[index] = rsDrowned
      inc sim.drownedCount
      var event = blankEvent(evDrown)
      event.tick = tick
      event.seat = index + 1
      event.x = here.x
      event.y = here.y
      event.drowned = sim.drownedCount
      sim.addEvent(event)
      sim.pos[index] = (-1, -1)

  # 11. Tick record: the post-resolution board.
  var record = blankEvent(evTick)
  record.tick = tick
  record.clock = sim.clock
  record.tideRows = sim.tideRows()
  for index in 0 ..< Runners:
    record.positions.add(@[sim.pos[index].x, sim.pos[index].y])
    record.alive.add(sim.status[index] == rsActive)
    record.moves.add(if wasActive[index]: $moves[index] else: "")
    record.blocked.add(sim.blocked[index])
  for key in sim.keysOnFloor:
    record.keysOnFloor.add(@[key.x, key.y])
  record.keysCollected = sim.keysCollected
  record.gateOpen = sim.gateOpen
  record.escaped = sim.escapedCount
  record.drowned = sim.drownedCount
  for seat in 0 ..< Seats:
    record.notes.add(notes[seat])
    record.scripted.add(scripted[seat])
  sim.addEvent(record)
  inc sim.tick

  ## The message reaches the runners at the START of the next tick.
  sim.inbox = if talking: text else: ""
  if talking:
    sim.standing = text
    sim.standingTick = tick

  # 12. End check, in order.
  if sim.escapedCount + sim.drownedCount == Runners:
    sim.settle("complete")
  elif sim.clock >= sim.floodClock():
    sim.settle("complete")
  elif sim.tick >= sim.config.maxTicks:
    sim.settle("timeup")

proc endEarly*(sim: var Sim) =
  ## Stop now, between ticks. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode
  ## always beats a long one that never lands.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var roles = newJArray()
  let score = sim.teamScore()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%score)
    roles.add(%roleName(seat))
  %*{
    "names": names,
    "scores": scores,
    "roles": roles,
    "teamScore": score,
    "keys": sim.keysCollected,
    "keyCount": sim.config.keyCount,
    "escaped": sim.escapedCount,
    "drowned": sim.drownedCount,
    "messages": sim.messages.len,
    "ticks": sim.tick,
    "maxTicks": sim.config.maxTicks,
    "clock": sim.clock,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc boardStateJson*(sim: Sim): JsonNode =
  ## One frame; the viewer draws exactly this and nothing else.
  let pending = sim.pendingSeats()
  var seats = newJArray()
  seats.add(%*{
    "name": sim.names[KeeperSeat],
    "role": "keeper",
    "status": "keeper",
    "pos": newJNull(),
    "keys": 0,
    "notes": sim.notes[KeeperSeat],
    "messages": sim.messages.len,
    "scripted": sim.scripted[KeeperSeat],
    "pending": KeeperSeat in pending
  })
  for index in 0 ..< Runners:
    let seat = index + 1
    var window = newJArray()
    var position = newJNull()
    if sim.status[index] == rsActive:
      for line in sim.runnerWindow(index):
        window.add(%line)
      position = %[sim.pos[index].x, sim.pos[index].y]
    seats.add(%*{
      "name": sim.names[seat],
      "role": "runner",
      "status": $sim.status[index],
      "pos": position,
      "keys": sim.keysHeld[index],
      "lastMove": $sim.lastMove[index],
      "blocked": sim.blocked[index],
      "window": window,
      "notes": sim.notes[seat],
      "scripted": sim.scripted[seat],
      "pending": seat in pending
    })
  var grid = newJArray()
  for line in sim.grid:
    grid.add(%line)
  var keys = newJArray()
  for key in sim.keysOnFloor:
    keys.add(%[key.x, key.y])
  var message = ""
  var messageAge = 0
  if sim.messages.len > 0:
    message = sim.messages[^1][1]
    messageAge = max(0, sim.tick - 1 - sim.messages[^1][0])
  %*{
    "seats": seats,
    "grid": grid,
    "exit": %[sim.exitAt.x, sim.exitAt.y],
    "gateOpen": sim.gateOpen,
    "keysOnFloor": keys,
    "keysCollected": sim.keysCollected,
    "keyCount": sim.config.keyCount,
    "tick": sim.tick,
    "maxTicks": sim.config.maxTicks,
    "clock": sim.clock,
    "tideRows": sim.tideRows(),
    "waterLine": sim.waterLine(),
    "message": message,
    "messageAge": messageAge,
    "messageCost": 1,
    "escaped": sim.escapedCount,
    "drowned": sim.drownedCount,
    "score": sim.teamScore(),
    "phase": (if sim.done: "done" else: "running"),
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc seededConfigJson*(sim: Sim): JsonNode =
  ## The board the seed produced, as the replay records it.
  var grid = newJArray()
  for line in sim.grid:
    grid.add(%line)
  var starts = newJArray()
  for index in 0 ..< Runners:
    starts.add(%[sim.starts[index].x, sim.starts[index].y])
  var keys = newJArray()
  for key in sim.keysAt:
    keys.add(%[key.x, key.y])
  %*{
    "grid": grid,
    "exit": %[sim.exitAt.x, sim.exitAt.y],
    "starts": starts,
    "keys": keys
  }

proc checkRecordedBoard(sim: Sim, recorded: JsonNode) =
  ## A wasm/native RNG divergence must fail loudly rather than draw a
  ## different maze under the same events.
  if recorded.isNil or recorded.kind != JObject:
    return
  let seeded = sim.seededConfigJson()
  for key in ["grid", "exit", "starts", "keys"]:
    if not recorded.hasKey(key):
      continue
    if $recorded[key] != $seeded[key]:
      raise newException(LighthouseError,
        "the recorded maze does not match the seeded one")

proc replayMatch*(config: GameConfig, events: seq[GameEvent],
    recorded: JsonNode = nil): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## every tick through the rules (the maze comes from the seed).
  ## frames[i] = state after events[0 ..< i], so frames.len == events.len + 1.
  var sim = initSim(config)
  sim.checkRecordedBoard(recorded)
  ## initSim already logged the start event; the recorded log's first
  ## event is that same start.
  sim.events = @[]
  result.add(sim)
  var spoke = false
  var message = ""
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evSay:
      ## Buffered: applyTick writes the say event itself.
      spoke = true
      message = event.text
    of evKey, evEscape, evDrown:
      ## Derived by applyTick from the tick that follows.
      discard
    of evTick:
      var moves: array[Runners, Move]
      var notes: array[Seats, string]
      var scripted: array[Seats, bool]
      for index in 0 ..< Runners:
        moves[index] =
          if index < event.moves.len and event.moves[index].len > 0:
            parseEnum[Move](event.moves[index])
          else:
            mvWait
      for seat in 0 ..< Seats:
        if seat < event.notes.len:
          notes[seat] = event.notes[seat]
        if seat < event.scripted.len:
          scripted[seat] = event.scripted[seat]
      sim.applyTick(spoke, message, moves, notes, scripted)
      spoke = false
      message = ""
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the ticks alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.tick >= 0:
    result["tick"] = %event.tick
  case event.kind
  of evStart:
    discard
  of evSay:
    result["seat"] = %event.seat
    result["cost"] = %event.cost
  of evKey:
    result["seat"] = %event.seat
    result["x"] = %event.x
    result["y"] = %event.y
    result["keysCollected"] = %event.keysCollected
  of evEscape:
    result["seat"] = %event.seat
    result["escaped"] = %event.escaped
  of evDrown:
    result["seat"] = %event.seat
    result["x"] = %event.x
    result["y"] = %event.y
    result["drowned"] = %event.drowned
  of evTick:
    result["clock"] = %event.clock
    result["tideRows"] = %event.tideRows
    var positions = newJArray()
    for entry in event.positions:
      positions.add(%entry)
    result["positions"] = positions
    var alive = newJArray()
    for entry in event.alive:
      alive.add(%entry)
    result["alive"] = alive
    var moves = newJArray()
    for entry in event.moves:
      moves.add(%entry)
    result["moves"] = moves
    var blocked = newJArray()
    for entry in event.blocked:
      blocked.add(%entry)
    result["blocked"] = blocked
    var keys = newJArray()
    for entry in event.keysOnFloor:
      keys.add(%entry)
    result["keysOnFloor"] = keys
    result["keysCollected"] = %event.keysCollected
    result["gateOpen"] = %event.gateOpen
    result["escaped"] = %event.escaped
    result["drowned"] = %event.drowned
    var notes = newJArray()
    for entry in event.notes:
      notes.add(%entry)
    result["notes"] = notes
    var scripted = newJArray()
    for entry in event.scripted:
      scripted.add(%entry)
    result["scripted"] = scripted
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    tick: node{"tick"}.getInt(-1),
    clock: node{"clock"}.getInt(0),
    tideRows: node{"tideRows"}.getInt(0),
    seat: node{"seat"}.getInt(-1),
    x: node{"x"}.getInt(-1),
    y: node{"y"}.getInt(-1),
    keysCollected: node{"keysCollected"}.getInt(0),
    gateOpen: node{"gateOpen"}.getBool(false),
    escaped: node{"escaped"}.getInt(0),
    drowned: node{"drowned"}.getInt(0),
    cost: node{"cost"}.getInt(0),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("positions"):
    for entry in node["positions"]:
      var tile: seq[int]
      for value in entry:
        tile.add(value.getInt())
      result.positions.add(tile)
  if node.hasKey("alive"):
    for entry in node["alive"]:
      result.alive.add(entry.getBool())
  if node.hasKey("moves"):
    for entry in node["moves"]:
      result.moves.add(entry.getStr())
  if node.hasKey("blocked"):
    for entry in node["blocked"]:
      result.blocked.add(entry.getBool())
  if node.hasKey("keysOnFloor"):
    for entry in node["keysOnFloor"]:
      var tile: seq[int]
      for value in entry:
        tile.add(value.getInt())
      result.keysOnFloor.add(tile)
  if node.hasKey("notes"):
    for entry in node["notes"]:
      result.notes.add(entry.getStr())
  if node.hasKey("scripted"):
    for entry in node["scripted"]:
      result.scripted.add(entry.getBool())
