import std/[json, sets, strutils, unicode, unittest]
import lighthouse/[llm, sim]

const Seeds = [1, 7, 42, 1234]

proc fixtureConfig(seed = 0, maxTicks = 45): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc handConfig(): GameConfig =
  ## A hand-built board for the resolution-order assertions: one open room,
  ## the exit in the top wall, and a tide of one row per clock unit.
  result = defaultGameConfig()
  result.width = 9
  result.height = 9
  result.maxTicks = 20
  result.tideDelay = 0
  result.tidePeriod = 4
  result.keyCount = 1
  result.seed = 3
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc handSim(keys: seq[Tile] = @[(7, 1)],
    starts: array[Runners, Tile] = [(1, 7), (3, 7), (5, 7)]): Sim =
  result = initSim(handConfig())
  result.grid = @[
    "#.#######",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#########"
  ]
  result.exitAt = (1, 0)
  result.starts = starts
  result.pos = starts
  result.keysAt = keys
  result.keysOnFloor = keys
  result.keysCollected = 0
  result.gateOpen = false
  for index in 0 ..< Runners:
    result.status[index] = rsActive
    result.keysHeld[index] = 0

proc silent(): array[Seats, string] =
  discard

proc noScript(): array[Seats, bool] =
  discard

proc step(sim: var Sim, moves: array[Runners, Move], spoke = false,
    message = "") =
  sim.applyTick(spoke, message, moves, silent(), noScript())

proc floorTiles(sim: Sim): int =
  for y in 0 ..< sim.config.height:
    for x in 0 ..< sim.config.width:
      if not sim.isWall(x, y):
        inc result

proc floorEdges(sim: Sim): int =
  for y in 0 ..< sim.config.height:
    for x in 0 ..< sim.config.width:
      if sim.isWall(x, y):
        continue
      if not sim.isWall(x + 1, y):
        inc result
      if not sim.isWall(x, y + 1):
        inc result

suite "maze":
  test "the maze is perfect and the border is sealed but for the exit":
    for seed in Seeds:
      let sim = initSim(fixtureConfig(seed = seed))
      let tiles = sim.floorTiles()
      ## A tree: exactly one path between any two floor tiles, no loops.
      check sim.floorEdges() == tiles - 1
      let field = sim.bfsFrom(@[sim.exitAt], avoidFlooded = false)
      var reachable = 0
      for value in field:
        if value >= 0:
          inc reachable
      check reachable == tiles
      ## The exit is the only gap in the outer wall.
      for x in 0 ..< sim.config.width:
        check sim.isWall(x, sim.config.height - 1)
        if (x, 0) != sim.exitAt:
          check sim.isWall(x, 0)
      for y in 0 ..< sim.config.height:
        check sim.isWall(0, y)
        check sim.isWall(sim.config.width - 1, y)
      check not sim.isWall(sim.exitAt.x, sim.exitAt.y)
      check sim.exitAt.y == 0
      check sim.exitAt.x mod 2 == 1

  test "the exit reaches every start and every key":
    for seed in Seeds:
      let sim = initSim(fixtureConfig(seed = seed))
      let field = sim.bfsFrom(@[sim.exitAt], avoidFlooded = false)
      for index in 0 ..< Runners:
        check sim.distanceTo(field, sim.starts[index]) > 0
      for key in sim.keysAt:
        check sim.distanceTo(field, key) > 0

  test "keys and starts are placed to the documented constraints":
    for seed in Seeds:
      let sim = initSim(fixtureConfig(seed = seed))
      check sim.keysAt.len == sim.config.keyCount
      var seen = initHashSet[Tile]()
      for key in sim.keysAt:
        seen.incl(key)
        check key notin sim.starts
        check key != sim.exitAt
        check abs(key.x - sim.exitAt.x) + abs(key.y - sim.exitAt.y) > 1
        check key.y <= sim.config.height - 4
        check not sim.isWall(key.x, key.y)
      check seen.len == sim.config.keyCount
      for a in 0 ..< sim.keysAt.len:
        let field = sim.bfsFrom(@[sim.keysAt[a]], avoidFlooded = false)
        for b in a + 1 ..< sim.keysAt.len:
          check sim.distanceTo(field, sim.keysAt[b]) >= 6
      for index in 0 ..< Runners:
        check sim.starts[index].y == sim.config.height - 2
        check sim.starts[index].x mod 2 == 1
      for a in 0 ..< Runners:
        for b in a + 1 ..< Runners:
          check abs(sim.starts[a].x - sim.starts[b].x) >= 4

suite "tide":
  test "the tide is a monotone function of the clock alone":
    var sim = initSim(fixtureConfig(seed = 5))
    check sim.floodClock() ==
      sim.config.tideDelay + sim.config.height * sim.config.tidePeriod
    var previous = 0
    for clock in 0 .. sim.floodClock() + 8:
      sim.clock = clock
      let rows = sim.tideRows()
      check rows >= previous
      previous = rows
      if clock < sim.config.tideDelay:
        check rows == 0
      if clock == sim.floodClock():
        check rows == sim.config.height
      check sim.waterLine() == sim.config.height - rows
      for y in 0 ..< sim.config.height:
        check sim.isFlooded(1, y) == (y >= sim.waterLine())

suite "resolution order":
  test "a wall bump leaves the runner where it was":
    var sim = handSim()
    sim.step([mvWest, mvWait, mvWait])
    check sim.pos[0] == (1, 7)
    check sim.blocked[0]
    check sim.status[0] == rsActive
    check sim.events[^1].moves == @["W", "WAIT", "WAIT"]
    check sim.events[^1].blocked == @[true, false, false]

  test "a move into water is a bump, not a drowning":
    var sim = handSim(starts = [(1, 6), (3, 6), (5, 6)])
    ## clock 8 floods rows 7 and 8 (height 9, tideDelay 0, tidePeriod 4).
    sim.clock = 8
    check sim.waterLine() == 7
    sim.step([mvSouth, mvWait, mvWait])
    check sim.pos[0] == (1, 6)
    check sim.blocked[0]
    check sim.status[0] == rsActive

  test "a key is taken on entry and the gate latches open":
    var sim = handSim(keys = @[(2, 7), (4, 7)])
    sim.config.keyCount = 2
    sim.step([mvEast, mvWait, mvWait])
    check sim.keysCollected == 1
    check sim.keysHeld[0] == 1
    check not sim.gateOpen
    check sim.events[^2].kind == evKey
    check sim.events[^2].seat == 1
    check sim.events[^2].x == 2
    sim.step([mvWait, mvEast, mvWait])
    check sim.keysCollected == 2
    check sim.keysHeld[1] == 1
    check sim.gateOpen
    check sim.events[^1].kind == evTick
    check sim.events[^1].gateOpen
    ## Never closes.
    sim.step([mvWait, mvWait, mvWait])
    check sim.gateOpen

  test "a runner escapes on an open gate and waits on a closed one":
    var sim = handSim(keys = @[(2, 1)], starts = [(1, 1), (3, 7), (5, 7)])
    sim.step([mvNorth, mvWait, mvWait])
    ## The gate is shut: standing on the exit tile is just standing there.
    check sim.pos[0] == (1, 0)
    check sim.status[0] == rsActive
    check sim.escapedCount == 0
    sim.step([mvSouth, mvWait, mvWait])
    sim.step([mvEast, mvWait, mvWait])
    check sim.keysCollected == 1
    check sim.gateOpen
    sim.step([mvWest, mvWait, mvWait])
    sim.step([mvNorth, mvWait, mvWait])
    check sim.status[0] == rsEscaped
    check sim.escapedCount == 1
    check sim.pos[0] == (-1, -1)

  test "the clock advances by one on silence and by two on a transmit":
    var sim = handSim()
    sim.step([mvWait, mvWait, mvWait])
    check sim.clock == 1
    sim.step([mvWait, mvWait, mvWait], spoke = true, message = "Sprocket N")
    check sim.clock == 3
    check sim.messages.len == 1
    check sim.inbox == "Sprocket N"
    ## An empty message is silence whatever the flag says.
    sim.step([mvWait, mvWait, mvWait], spoke = true, message = "   ")
    check sim.clock == 4
    check sim.messages.len == 1
    check sim.inbox == ""
    check sim.standing == "Sprocket N"

  test "drowning happens after the move, the pickup and the escape chance":
    var sim = handSim(keys = @[(3, 6)], starts = [(2, 6), (5, 6), (7, 6)])
    ## clock 11 now; the tick below takes it to 12, flooding row 6.
    sim.clock = 11
    check sim.waterLine() == 7
    sim.step([mvEast, mvWait, mvWait])
    check sim.keysCollected == 1
    check sim.keysHeld[0] == 1
    check sim.gateOpen
    check sim.waterLine() == 6
    check sim.status[0] == rsDrowned
    check sim.drownedCount == 3
    check sim.done
    check sim.reason == "complete"

  test "a resolved seat keeps the scripted flag it played under":
    ## Phase 60 counts scripted fallbacks off the tick events and the final
    ## board state, so a seat that escaped must not have its flag zeroed by
    ## the ticks it no longer plays: the server only reports flags for
    ## `pendingSeats()`.
    var sim = handSim(keys = @[(2, 7)], starts = [(1, 1), (3, 7), (5, 7)])
    var flags: array[Seats, bool]
    flags[1] = true
    sim.applyTick(false, "", [mvWait, mvWest, mvWait], silent(), flags)
    check sim.gateOpen
    sim.applyTick(false, "", [mvNorth, mvWait, mvWait], silent(), flags)
    check sim.status[0] == rsEscaped
    sim.applyTick(false, "", [mvWait, mvWait, mvWait], silent(), noScript())
    check sim.scripted[1]
    check sim.events[^1].kind == evTick
    check sim.events[^1].scripted[1]
    check sim.boardStateJson()["seats"][1]["scripted"].getBool()

suite "collisions":
  test "runners share tiles and may swap":
    var sim = handSim(starts = [(2, 5), (4, 5), (7, 7)])
    sim.step([mvEast, mvWest, mvWait])
    check sim.pos[0] == (3, 5)
    check sim.pos[1] == (3, 5)
    sim.step([mvEast, mvWest, mvWait])
    check sim.pos[0] == (4, 5)
    check sim.pos[1] == (2, 5)
    check not sim.blocked[0]
    check not sim.blocked[1]

suite "scoring":
  test "the team score is hand-computable, positive and shared":
    ## All three out, early: 6 for the keys, 30 for the escapes, plus the
    ## clock bonus.
    var sim = handSim(keys = @[(2, 7)], starts = [(1, 1), (2, 1), (3, 1)])
    sim.step([mvWait, mvWait, mvWait])          # clock 1
    sim.keysCollected = 1
    sim.gateOpen = true
    sim.pos = [(1, 1), (1, 1), (1, 1)]
    sim.step([mvNorth, mvNorth, mvNorth])       # clock 2, everyone out
    check sim.escapedCount == 3
    check sim.done
    let bonus = 1.0 - sim.clock.float / sim.floodClock().float
    check abs(sim.teamScore() - (6.0 + 30.0 + 6.0 * bonus)) < 1e-9
    check sim.teamScore() > 0.0
    check sim.teamScore() <= 42.0
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() == sim.teamScore()
    check results["roles"][0].getStr() == "keeper"
    check results["roles"][3].getStr() == "runner"

  test "two out of three scores no time bonus":
    var sim = handSim(keys = @[(2, 7)], starts = [(1, 1), (2, 1), (5, 5)])
    sim.keysCollected = 1
    sim.gateOpen = true
    sim.step([mvWait, mvWest, mvWait])
    check sim.pos[1] == (1, 1)
    sim.step([mvNorth, mvNorth, mvWait])
    check sim.escapedCount == 2
    ## 6 * (1/1) + 10 * 2 + 0
    check abs(sim.teamScore() - 26.0) < 1e-9

  test "a total wipeout scores zero":
    var sim = handSim(keys = @[(7, 1)])
    sim.clock = 11
    sim.step([mvWait, mvWait, mvWait])
    check sim.drownedCount == 3
    check sim.keysCollected == 0
    check sim.teamScore() == 0.0
    check sim.resultsJson()["scores"][0].getFloat() == 0.0

suite "endings":
  test "complete, timeup and deadline are the only reasons":
    var complete = handSim(keys = @[(7, 1)])
    complete.clock = 11
    complete.step([mvWait, mvWait, mvWait])
    check complete.reason == "complete"

    var timeup = initSim(fixtureConfig(seed = 4, maxTicks = 4))
    for tick in 0 ..< 4:
      timeup.step([mvWait, mvWait, mvWait])
    check timeup.done
    check timeup.reason == "timeup"
    check timeup.tick == 4
    check timeup.escapedCount + timeup.drownedCount < Runners

    var deadline = initSim(fixtureConfig(seed = 4, maxTicks = 40))
    deadline.step([mvWait, mvWait, mvWait])
    deadline.endEarly()
    check deadline.done
    check deadline.reason == "deadline"
    check deadline.tick == 1
    let before = deadline.events.len
    deadline.endEarly()                     # idempotent
    check deadline.events.len == before
    check deadline.resultsJson()["reason"].getStr() == "deadline"
    expect LighthouseError:
      deadline.step([mvWait, mvWait, mvWait])

    for sim in [complete, timeup, deadline]:
      check sim.reason in ["complete", "timeup", "deadline"]

suite "text hygiene":
  test "messages and notes truncate on rune boundaries":
    var long = ""
    for index in 0 ..< 400:
      long.add("é")
    let message = cleanText(long, MaxMessageLen)
    check message.runeLen == MaxMessageLen
    check message.endsWith("…")
    check validateUtf8(message) == -1
    check cleanText(long, MaxKeeperNotes).runeLen == MaxKeeperNotes
    check cleanText(long, MaxRunnerNotes).runeLen == MaxRunnerNotes
    var sim = handSim()
    var notes: array[Seats, string]
    notes[KeeperSeat] = cleanText(long, MaxKeeperNotes)
    notes[1] = cleanText(long, MaxRunnerNotes)
    sim.applyTick(true, message, [mvWait, mvWait, mvWait], notes, noScript())
    for event in sim.events:
      check validateUtf8($event.eventToJson()) == -1
    check validateUtf8($sim.resultsJson()) == -1
    check validateUtf8($sim.boardStateJson()) == -1

suite "replay":
  test "re-deriving frames from the event log reproduces the episode":
    var sim = initSim(fixtureConfig(seed = 9, maxTicks = 12))
    var rng = 17
    while not sim.done:
      rng = (rng * 1103515245 + 12345) mod 2147483648
      var moves: array[Runners, Move]
      for index in 0 ..< Runners:
        moves[index] =
          if sim.status[index] == rsActive:
            Move((rng div (index + 3)) mod 5)
          else:
            mvWait
      var notes: array[Seats, string]
      if rng mod 3 == 0:
        notes[0] = "keeper note " & $rng
      if rng mod 5 == 0:
        notes[2] = "runner note " & $rng
      var scripted: array[Seats, bool]
      scripted[1] = rng mod 2 == 0
      let spoke = rng mod 4 != 0
      sim.applyTick(spoke, (if spoke: "Go " & $rng else: ""), moves, notes,
        scripted)
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    let recorded = sim.seededConfigJson()
    let frames = replayMatch(sim.config, events, recorded)
    check frames.len == events.len + 1
    check frames[^1].done
    check frames[^1].reason == sim.reason
    check frames[^1].keysCollected == sim.keysCollected
    check frames[^1].escapedCount == sim.escapedCount
    check frames[^1].notes == sim.notes
    check $frames[^1].boardStateJson() == $sim.boardStateJson()
    check frames[0].tick == 0
    check frames[0].events.len == 0
    check frames[^1].events.len == events.len

  test "a mutated maze in the recorded config is rejected":
    var sim = initSim(fixtureConfig(seed = 2, maxTicks = 6))
    sim.step([mvWait, mvWait, mvWait])
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    var recorded = sim.seededConfigJson()
    ## Flip one character of one grid row.
    var rows = newJArray()
    for index, node in recorded["grid"].getElems():
      var row = node.getStr()
      if index == 1:
        row[1] = (if row[1] == '#': '.' else: '#')
      rows.add(%row)
    recorded["grid"] = rows
    expect LighthouseError:
      discard replayMatch(sim.config, events, recorded)

  test "event JSON round-trips for every kind":
    var sim = handSim(keys = @[(2, 7)], starts = [(1, 1), (1, 7), (5, 7)])
    sim.step([mvWait, mvEast, mvWait], spoke = true, message = "Gizmo E")
    check sim.gateOpen
    sim.step([mvNorth, mvWait, mvWait])
    check sim.escapedCount == 1
    sim.clock = 11
    sim.step([mvWait, mvWait, mvWait])
    check sim.drownedCount == 2
    check sim.done
    var kinds = initHashSet[EventKind]()
    for event in sim.events:
      kinds.incl(event.kind)
      let node = event.eventToJson()
      check eventFromJson(node) == event
      check $eventFromJson(node).eventToJson() == $node
    for kind in EventKind:
      check kind in kinds

suite "determinism":
  test "the seed fixes the maze, the placement and the aliases":
    let a = initSim(fixtureConfig(seed = 7))
    let b = initSim(fixtureConfig(seed = 7))
    check a.grid == b.grid
    check a.exitAt == b.exitAt
    check a.starts == b.starts
    check a.keysAt == b.keysAt
    check a.names == b.names
    let c = initSim(fixtureConfig(seed = 8))
    check c.grid != a.grid
    check a.names[0] in KeeperNames
    for index in 1 ..< Seats:
      check a.names[index] in CogNames

  test "the budget caps ticks and pacing":
    var config = fixtureConfig(seed = 0, maxTicks = 500)
    config.sampled = false
    config.turnDelayMs = 10_000
    let fitted = sampleEpisode(config)
    check fitted.maxTicks == EpisodeCallBudget div CallsPerTick
    check fitted.maxTicks == 55
    check fitted.turnDelayMs == PacingBudgetMs div 55
    check fitted.sampled
    check sampleEpisode(fitted) == fitted
    var small = fixtureConfig(seed = 0, maxTicks = 4)
    small.sampled = false
    check sampleEpisode(small).maxTicks == MinTicks
    ## The shipped default survives the cap untouched.
    var shipped = fixtureConfig(seed = 0)
    shipped.sampled = false
    check sampleEpisode(shipped).maxTicks == 45
    check sampleEpisode(shipped).turnDelayMs == 250

suite "views":
  test "the keeper sees the board and a runner sees three by three":
    var sim = handSim(keys = @[(4, 3)], starts = [(2, 3), (6, 6), (7, 7)])
    let view = sim.keeperView().splitLines()
    check view.len == sim.config.height
    for line in view:
      check line.len == sim.config.width
    check view[0][1] == 'E'
    check view[3][2] == '1'
    check view[3][4] == 'K'
    sim.gateOpen = true
    check sim.keeperView().splitLines()[0][1] == 'O'
    let window = sim.runnerWindow(0)
    check window.len == 3
    for line in window:
      check line.len == 3
    check window[1][1] == '@'
    ## Off-grid renders as wall: a runner standing on the exit tile has
    ## nothing but board edge above it.
    var edge = handSim(starts = [(1, 1), (6, 6), (7, 7)])
    edge.pos[0] = edge.exitAt
    let corner = edge.runnerWindow(0)
    check corner[0] == "###"
    check corner[1][0] == '#'
    ## Water outranks a key: a key still lying on a flooded tile renders
    ## `~`, never `K`, in the keeper's map and in a runner's window — the
    ## glyph is the only legality test a blind runner has.
    var drowned = handSim(keys = @[(4, 3)], starts = [(3, 2), (6, 1), (7, 1)])
    drowned.clock = 24
    check drowned.waterLine() == 3
    check drowned.isFlooded(4, 3)
    check drowned.glyphAt(4, 3) == '~'
    check drowned.keeperView().splitLines()[3][4] == '~'
    check drowned.runnerWindow(0)[2][2] == '~'

  test "pendingSeats is the keeper plus the live runners":
    var sim = handSim(keys = @[(7, 1)])
    check sim.pendingSeats() == @[0, 1, 2, 3]
    sim.clock = 11
    sim.step([mvWait, mvWait, mvWait])
    check sim.done
    check sim.pendingSeats().len == 0

  test "boardStateJson carries exactly what the viewer draws":
    var sim = handSim(keys = @[(4, 3)])
    sim.step([mvNorth, mvWait, mvWait], spoke = true,
      message = "Sprocket N; Gizmo hold")
    let state = sim.boardStateJson()
    check state["seats"].len == Seats
    check state["seats"][0]["role"].getStr() == "keeper"
    check state["seats"][0]["pos"].kind == JNull
    check state["seats"][0]["messages"].getInt() == 1
    check state["seats"][1]["role"].getStr() == "runner"
    check state["seats"][1]["pos"][1].getInt() == 6
    check state["seats"][1]["window"].len == 3
    check state["grid"].len == sim.config.height
    check state["exit"][0].getInt() == 1
    check state["keyCount"].getInt() == 1
    check state["message"].getStr() == "Sprocket N; Gizmo hold"
    check state["messageAge"].getInt() == 0
    check state["messageCost"].getInt() == 1
    check state["waterLine"].getInt() == sim.waterLine()
    check state["phase"].getStr() == "running"
    check not state["gameDone"].getBool()
