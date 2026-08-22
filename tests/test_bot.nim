## The scripted baselines must play whole episodes without ever proposing
## an illegal move — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## `lantern` + three `wallhug` must also be a competent, watchable filler
## team, or a champion prompt has nothing to beat.

import std/[json, monotimes, times, unicode, unittest]
import lighthouse/[llm, sim]

const Seeds = [1, 7, 42, 1234]

## Legality costs milliseconds, so it is driven over a wider set than the
## four tuning fixtures. Seed 21 is a board where the tide reaches a tile
## that still holds a key — the case the legality assertion below has to
## catch, and the one it missed while it read `and` instead of `or`.
const LegalitySeeds = [1, 7, 42, 1234, 3, 5, 11, 13, 21, 55]

proc fixture(seed: int, maxTicks = 45): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

type Tally = object
  sim: Sim
  ticks: int
  talked: int
  ordered: int
  obeyed: int

proc playScripted(config: GameConfig): Tally =
  ## Exactly the loop the server runs, with every seat scripted.
  result.sim = initSim(config)
  while not result.sim.done:
    let seats = result.sim.pendingSeats()
    check seats.len >= 1
    check seats[0] == KeeperSeat
    var spoke = false
    var message = ""
    var moves: array[Runners, Move]
    var notes: array[Seats, string]
    var scripted: array[Seats, bool]
    ## Instruction following is only counted on ticks where a FRESH
    ## message named the runner.
    var orders: array[Runners, tuple[found: bool, move: Move]]
    for index in 0 ..< Runners:
      if result.sim.status[index] == rsActive:
        orders[index] = orderedDirection(result.sim.inbox,
          result.sim.names[index + 1])
    for seat in seats:
      let decision = scriptedAction(result.sim, seat, skAuto)
      check decision.scripted
      check decision.notes.len == 0
      scripted[seat] = true
      if seat == KeeperSeat:
        spoke = decision.transmit
        message = decision.message
        check message.runeLen <= MaxMessageLen
        check validateUtf8(message) == -1
      else:
        moves[seat - 1] = decision.move
        ## The reply is always one of the five legal tokens.
        check $decision.move in ["N", "S", "E", "W", "WAIT"]
    for index in 0 ..< Runners:
      if result.sim.status[index] != rsActive:
        continue
      if orders[index].found and orders[index].move != mvWait:
        inc result.ordered
        if moves[index] == orders[index].move:
          inc result.obeyed
      ## No move ever passes through a wall, off the grid, or into water.
      ## `isWall` is true off the grid, so the three cases the comment
      ## names are exactly the three this rejects — it has to be `or`:
      ## `and` would only fire on a tile that is wall AND water, which
      ## `passable` already refuses, i.e. never.
      let step = delta(moves[index])
      let target = (result.sim.pos[index].x + step.x,
        result.sim.pos[index].y + step.y)
      if moves[index] != mvWait:
        check not result.sim.isWall(target[0], target[1])
        check not result.sim.isFlooded(target[0], target[1])
    if spoke:
      inc result.talked
    inc result.ticks
    result.sim.applyTick(spoke, message, moves, notes, scripted)
    for index in 0 ..< Runners:
      if result.sim.status[index] == rsActive:
        check not result.sim.isWall(result.sim.pos[index].x,
          result.sim.pos[index].y)
        check not result.sim.isFlooded(result.sim.pos[index].x,
          result.sim.pos[index].y)

suite "scripted baselines":
  test "lantern and wallhug play whole episodes legally":
    for seed in LegalitySeeds:
      let config = fixture(seed)
      let started = getMonoTime()
      let tally = playScripted(config)
      let elapsed = (getMonoTime() - started).inMilliseconds
      check tally.sim.done
      check tally.sim.reason in ["complete", "timeup"]
      check tally.sim.tick <= config.maxTicks
      check elapsed < config.maxTicks * 50
      echo "seed ", seed, ": ", tally.sim.tick, " ticks, clock ",
        tally.sim.clock, ", keys ", tally.sim.keysCollected, ", escaped ",
        tally.sim.escapedCount, ", drowned ", tally.sim.drownedCount,
        ", score ", tally.sim.teamScore(), ", talked ", tally.talked, "/",
        tally.ticks, ", ", elapsed, " ms"
      let results = tally.sim.resultsJson()
      for seat in 0 ..< Seats:
        check results["scores"][seat].getFloat() >= 0.0
        check results["scores"][seat].getFloat() <= 42.0
      check validateUtf8($results) == -1

  test "lantern keeps its words inside the talk budget":
    ## Every transmit costs the team an extra unit of tide, so the baseline
    ## must not chatter.
    for seed in Seeds:
      let tally = playScripted(fixture(seed))
      let rate = tally.talked.float / tally.ticks.float
      echo "seed ", seed, " talk rate ", rate
      check rate <= 0.60

  test "the filler team is competent: keys in, and runners out":
    ## The tuning oracle. If this fails the fix is the tide period, not a
    ## weaker maze.
    var keyed = 0
    var allOut = 0
    for seed in Seeds:
      let tally = playScripted(fixture(seed))
      if tally.sim.keysCollected == tally.sim.config.keyCount:
        inc keyed
      if tally.sim.escapedCount == Runners:
        inc allOut
    echo "seeds with every key collected: ", keyed, "/", Seeds.len,
      "; seeds with all three out: ", allOut, "/", Seeds.len
    check keyed >= 3
    check allOut >= 2

  test "wallhug follows the keeper's orders":
    var ordered = 0
    var obeyed = 0
    for seed in Seeds:
      let tally = playScripted(fixture(seed))
      ordered += tally.ordered
      obeyed += tally.obeyed
    check ordered > 0
    let rate = obeyed.float / ordered.float
    echo "instruction following: ", obeyed, "/", ordered, " = ", rate
    check rate >= 0.80

suite "role substitution":
  test "a baseline dealt the wrong slot plays the other one":
    check roleKind(KeeperSeat, skWallhug) == skLantern
    check roleKind(1, skLantern) == skWallhug
    check roleKind(KeeperSeat, skLantern) == skLantern
    check roleKind(3, skWallhug) == skWallhug
    check roleKind(KeeperSeat, skAuto) == skLantern
    check roleKind(2, skAuto) == skWallhug
    check roleKind(KeeperSeat, skNone) == skNone
    check roleKind(1, skNone) == skNone
    check parseScriptKind("lantern") == skLantern
    check parseScriptKind("wallhug") == skWallhug
    check parseScriptKind("1") == skAuto
    check parseScriptKind("true") == skAuto
    check parseScriptKind("yes") == skAuto
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone
    ## And the decisions really are the other baseline's shape.
    let sim = initSim(fixture(7))
    let keeperSeatAsWallhug = scriptedAction(sim, KeeperSeat, skWallhug)
    check keeperSeatAsWallhug.message.len > 0
    let runnerSeatAsLantern = scriptedAction(sim, 2, skLantern)
    check $runnerSeatAsLantern.move in ["N", "S", "E", "W", "WAIT"]
    check runnerSeatAsLantern.message.len == 0

suite "no credentials":
  test "decideAll is pure scripted with no LLM env":
    ## The offline certification path: no credentials means no network at
    ## all, not a slow retry loop.
    let config = fixture(3, maxTicks = 8)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    var prompts = newSeq[string](Seats)
    prompts[0] = "talk a lot"
    var registered = newSeq[ScriptKind](Seats)
    let started = getMonoTime()
    let decisions = client.decideAll(sim, seats, prompts, registered)
    let elapsed = (getMonoTime() - started).inMilliseconds
    check elapsed < 1000
    check decisions.len == seats.len
    for index, seat in seats:
      check decisions[index].scripted
      let expected = scriptedAction(sim, seat, skAuto)
      if seat == KeeperSeat:
        check decisions[index].message == expected.message
        check decisions[index].transmit == expected.transmit
      else:
        check decisions[index].move == expected.move

suite "reply parsing":
  test "runner moves parse tolerantly and reject anything else":
    check parseRunnerReply(parseJson("""{"move":"north"}""")).move == mvNorth
    check parseRunnerReply(parseJson("""{"move":"n"}""")).move == mvNorth
    check parseRunnerReply(parseJson("""{"move":" E "}""")).move == mvEast
    check parseRunnerReply(parseJson("""{"move":"WAIT"}""")).move == mvWait
    check parseRunnerReply(parseJson("""{"move":"left"}""")).move == mvWest
    check parseRunnerReply(parseJson("""{"move":"Down"}""")).move == mvSouth
    check parseRunnerReply(parseJson("""{"move":"hold"}""")).move == mvWait
    check parseRunnerReply(
      parseJson("""{"move":"S","notes":"x"}""")).notes == "x"
    expect LighthouseError:
      discard parseRunnerReply(parseJson("""{"move":"NE"}"""))
    expect LighthouseError:
      discard parseRunnerReply(parseJson("""{"move":42}"""))
    expect LighthouseError:
      discard parseRunnerReply(parseJson("""{}"""))
    expect LighthouseError:
      discard parseRunnerReply(parseJson("""{"notes":"no move"}"""))

  test "keeper replies infer transmit and treat blank as silence":
    let plain = parseKeeperReply(
      parseJson("""{"transmit":true,"message":"Sprocket N"}"""))
    check plain.transmit
    check plain.message == "Sprocket N"
    let blank = parseKeeperReply(
      parseJson("""{"transmit":true,"message":"   "}"""))
    check not blank.transmit
    check blank.message == ""
    let inferred = parseKeeperReply(parseJson("""{"message":"go N"}"""))
    check inferred.transmit
    check inferred.message == "go N"
    let hushed = parseKeeperReply(
      parseJson("""{"transmit":false,"message":"quiet"}"""))
    check not hushed.transmit
    ## Newlines collapse before the rune-boundary truncation: one run of
    ## newline characters becomes ONE space, CRLF and blank lines included.
    let folded = parseKeeperReply(
      parseJson("""{"message":"one\ntwo","notes":"n"}"""))
    check folded.message == "one two"
    check folded.notes == "n"
    let crlf = parseKeeperReply(
      parseJson("""{"message":"a\r\n\nb\n\nc"}"""))
    check crlf.message == "a b c"
    expect LighthouseError:
      discard parseKeeperReply(parseJson("""{"order":3}"""))

  test "the transport tolerates fenced and chatty JSON":
    check extractJsonObject("```json\n{\"move\":\"N\"}\n```"){
      "move"}.getStr() == "N"
    check extractJsonObject("Sure! {\"move\":\"S\"} hope that helps"){
      "move"}.getStr() == "S"
    expect LighthouseError:
      discard extractJsonObject("I cannot help with that.")
