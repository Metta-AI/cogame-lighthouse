## Lighthouse game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - broadcast chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (lighthouse.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"role":...}
##                   {"type":"state",...} after every tick (redacted: the
##                   whole game is hidden information)
##                   {"type":"final","scores":[...],"roles":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"lantern"}
##                   (max 4000 chars; scripted plays a built-in baseline
##                   for that seat: "lantern", "wallhug", or "1" for
##                   whichever the dealt slot needs)

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.boardStateJson()
  result["type"] = %"state"
  result["game"] = %"lighthouse"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Lighthouse IS hidden information: a runner never learns the map, its
  ## own coordinates or the tide, and the keeper never learns a runner's
  ## notes. Decisions are server-side, so this redaction loses nothing.
  var seat: JsonNode
  if slot == KeeperSeat:
    seat = %*{
      "status": "keeper",
      "keys": 0,
      "lastMove": "",
      "blocked": false,
      "messages": gs.sim.messages.len
    }
  else:
    let runner = slot - 1
    seat = %*{
      "status": $gs.sim.status[runner],
      "keys": gs.sim.keysHeld[runner],
      "lastMove": $gs.sim.lastMove[runner],
      "blocked": gs.sim.blocked[runner],
      "messages": gs.sim.messages.len
    }
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "role": roleName(slot),
    "seat": seat,
    "tick": gs.sim.tick,
    "maxTicks": gs.config.maxTicks,
    "keysCollected": gs.sim.keysCollected,
    "keyCount": gs.config.keyCount,
    "gateOpen": gs.sim.gateOpen,
    "escaped": gs.sim.escapedCount,
    "drowned": gs.sim.drownedCount,
    "teamScore": gs.sim.teamScore(),
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole board; players get
  ## the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayConfigJson(gs: GameState): JsonNode =
  ## Everything the viewer needs about the board, so the only network it
  ## does is the S3 GET of this file.
  result = gs.sim.seededConfigJson()
  result["seed"] = %gs.config.seed
  result["maxTicks"] = %gs.config.maxTicks
  result["width"] = %gs.config.width
  result["height"] = %gs.config.height
  result["tideDelay"] = %gs.config.tideDelay
  result["tidePeriod"] = %gs.config.tidePeriod
  result["keyCount"] = %gs.config.keyCount
  result["messageCap"] = %MaxMessageLen
  result["sampled"] = %true

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "lighthouse.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": gs.replayConfigJson(),
    "events": events,
    "results": results
  }

proc statesFromEvents*(config: GameConfig, events: seq[GameEvent],
    recorded: JsonNode): JsonNode =
  ## One board-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events, recorded):
    result.add(frame.boardStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame
    ## goes to the player sockets — hand them the aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "roles": results["roles"],
      "names": aliasNames,
      "keys": results["keys"],
      "escaped": results["escaped"],
      "drowned": results["drowned"],
      "ticks": results["ticks"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "lighthouse: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  sleep(500)
  echo "lighthouse: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "lighthouse: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing.
    ## Play inside a fraction of it so results and the replay are written
    ## with room to spare. The hosted dispatcher hands the timeout only to
    ## its own worker sidecar, NOT to the game container, so when the env
    ## is silent assume the configured platform default rather than
    ## playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "lighthouse: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and epochTime() > playDeadline:
          ## The platform kills an episode that outruns its timeout and
          ## keeps nothing at all, so give up ticks rather than the whole
          ## result: stop here, between ticks.
          echo "lighthouse: episode deadline reached after ",
            state.sim.tick, "/", config.maxTicks, " ticks; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        echo "lighthouse: tick ", state.sim.tick, " of ", config.maxTicks,
          " (clock ", state.sim.clock, ", water line ",
          state.sim.waterLine(), ") at ", (epochTime() - gameStart).int, "s"

      ## The slow part (Claude, ONE parallel batch for the whole tick) runs
      ## outside the lock on a snapshot; only this thread mutates the sim,
      ## so the snapshot cannot go stale.
      let decisions = client.decideAll(simCopy, seats, prompts, scripted)

      withLock stateLock:
        var spoke = false
        var message = ""
        var moves: array[Runners, Move]
        var notes: array[Seats, string]
        var scriptedFlags: array[Seats, bool]
        for index, seat in seats:
          let decision = decisions[index]
          notes[seat] = decision.notes
          scriptedFlags[seat] = decision.scripted
          if seat == KeeperSeat:
            spoke = decision.transmit
            message = decision.message
            if spoke:
              echo "lighthouse: ", state.sim.names[seat], " transmits \"",
                message, "\" (+1 tick of tide)"
          else:
            moves[seat - 1] = decision.move
            echo "lighthouse: ", state.sim.names[seat], " moves ",
              $decision.move
        try:
          state.sim.applyTick(spoke, message, moves, notes, scriptedFlags)
        except LighthouseError as error:
          echo "lighthouse: tick rejected (", error.msg, "); ending early"
          state.sim.endEarly()
        state.broadcastLocked()

      ## Pace between ticks so spectators can read the board.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    ## Let the last tick land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "lighthouse: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "lighthouse.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "role": roleName(slot),
        "maxTicks": state.config.maxTicks
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let registered =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skAuto else: skNone)
            else: parseScriptKind(node.getStr())
          let playing = roleKind(slot, registered)
          if registered != skNone and registered != skAuto and
              registered != playing:
            echo "lighthouse: slot ", slot, " registered ", $registered,
              "; playing ", $playing, " for its role"
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = registered
          echo "lighthouse: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if registered != skNone: ", scripted " & $playing else: ""), ")"
      except CatchableError as error:
        echo "lighthouse: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let recorded = payload["config"]
  ## Every fallback is the shipped default, read off `defaultGameConfig()`
  ## rather than repeated here: a second copy of the board constants goes
  ## stale the moment the board is retuned.
  result.seed = recorded{"seed"}.getInt(result.seed)
  result.maxTicks = recorded{"maxTicks"}.getInt(result.maxTicks)
  result.width = recorded{"width"}.getInt(result.width)
  result.height = recorded{"height"}.getInt(result.height)
  result.tideDelay = recorded{"tideDelay"}.getInt(result.tideDelay)
  result.tidePeriod = recorded{"tidePeriod"}.getInt(result.tidePeriod)
  result.keyCount = recorded{"keyCount"}.getInt(result.keyCount)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## maze, the exit, the starts and the keys are re-derived from the seed
  ## and cross-checked against the recorded ones.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("lighthouse.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events, payload["config"])
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "lighthouse: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(LighthouseError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "lighthouse: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
