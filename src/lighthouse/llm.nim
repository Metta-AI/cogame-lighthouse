## Claude-backed decision making for Lighthouse. Each seat's policy is just
## a prompt: the game server composes the seat's observation (the whole map
## for the keeper, a 3 x 3 window and the keeper's last words for a runner)
## plus that seat's prompt and asks Claude what it transmits or which way it
## steps.
##
## Decisions within a tick are simultaneous by rule, so every active seat's
## request goes out as ONE parallel batch (curly.makeRequests); invalid
## replies are retried as a smaller batch with a hint, and anything still
## failing falls back to the role-appropriate scripted baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[algorithm, json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## How many past transmissions the keeper is shown.
  TranscriptLen = 5
  ## How many of its own past moves a runner is shown.
  MoveHistoryLen = 6
  ## A standing order older than this is stale to the wallhug baseline.
  StandingMaxAge = 3

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

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

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

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "lighthouse llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "lighthouse llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "lighthouse llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "lighthouse llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "lighthouse llm: no LLM credentials; using scripted fallback"

# ---- Text hygiene -----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A
  ## byte-boundary cut renders in a browser and fails a strict JSON parser,
  ## which is how a replay ends up unreadable by everything downstream.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

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

proc turnRight(move: Move): Move =
  case move
  of mvNorth: mvEast
  of mvEast: mvSouth
  of mvSouth: mvWest
  of mvWest: mvNorth
  of mvWait: mvWait

proc turnLeft(move: Move): Move =
  turnRight(turnRight(turnRight(move)))

proc turnBack(move: Move): Move =
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

proc passable(window: array[3, string], move: Move): bool =
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

# ---- Prompt building --------------------------------------------------------

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  let common = """

Rules:
- The maze is a perfect maze: exactly one path between any two floor
  tiles, no loops. The only gap in the outer wall is the EXIT on the top
  row.
- Three KEYS lie in the maze. When all of them have been picked up the
  gate at the exit opens (a horn everyone hears) and runners standing on
  the exit tile escape.
- The TIDE rises from the bottom row upward and never recedes. It is a
  function of one number, the CLOCK. Every tick the clock advances by 1,
  and by 2 instead if the keeper transmitted that tick. Nobody may step
  into water; a runner the water reaches drowns.
- SCORE is a single team number shared by all four seats: 6 points for
  the keys, 10 for every runner that escapes, and up to 6 more for
  escaping with all three while the clock is still low. Higher is better.
  Drowning simply earns nothing.
- The keeper may transmit ONE short message per tick. It reaches all
  three runners at the start of the NEXT tick. Runners have no channel at
  all: not to the keeper, not to each other.
- Your notes are private to you and fed back to you every tick.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after
the object. Your reply must begin with the character { and end with }."""
  if seat == KeeperSeat:
    "You are " & me & ", the KEEPER of the lighthouse. You see the whole " &
      "maze and you cannot move. Three blind runners are in it. Your " &
      "words are the only bridge from what you can see to what they can " &
      "do, and every word costs a tick of tide." & common
  else:
    "You are " & me & ", a blind RUNNER in a flooding maze. You see only " &
      "the three-by-three window around yourself. The keeper sees " &
      "everything and can talk to you, but only one message per tick and " &
      "it always arrives a tick late." & common

proc floodCountdown(sim: Sim): tuple[silent, talking: int] =
  let rows = sim.tideRows()
  if rows >= sim.config.height:
    return (0, 0)
  let next = sim.config.tideDelay + (rows + 1) * sim.config.tidePeriod
  let need = max(next - sim.clock, 0)
  (need, (need + 1) div 2)

proc keeperPrompt*(sim: Sim, prompt: string): string =
  result.add("Tick " & $sim.tick & " of " & $sim.config.maxTicks &
    ". You are the KEEPER.\n\n")
  result.add("THE MAZE (# wall, . floor, ~ water, K key, E exit with the " &
    "gate shut, O exit with the gate open, 1/2/3 a runner):\n" &
    sim.keeperView() & "\n\n")
  result.add("YOUR RUNNERS:\n")
  for index in 0 ..< Runners:
    let seat = index + 1
    var line = $seat & ". " & sim.names[seat] & " — "
    case sim.status[index]
    of rsActive:
      line.add("at (" & $sim.pos[index].x & ", " & $sim.pos[index].y &
        "), carrying " & $sim.keysHeld[index] & " key" &
        (if sim.keysHeld[index] == 1: "" else: "s") & ", last move " &
        $sim.lastMove[index] &
        (if sim.blocked[index]: " (BUMPED a wall or the water)" else: ""))
    of rsEscaped:
      line.add("OUT of the maze, safe.")
    of rsDrowned:
      line.add("taken by the tide.")
    result.add(line & "\n")
  let countdown = sim.floodCountdown()
  result.add("\nTHE TIDE: " & $sim.tideRows() & " row" &
    (if sim.tideRows() == 1: "" else: "s") & " flooded; the water line is " &
    "at y=" & $sim.waterLine() & " (every tile with y >= " &
    $sim.waterLine() & " is under water). The clock is " & $sim.clock &
    " of " & $sim.floodClock() & ".\n")
  if sim.tideRows() >= sim.config.height:
    result.add("The whole board is under water.\n")
  else:
    result.add("The next row floods in " & $countdown.silent &
      " tick(s) if you stay silent, in " & $countdown.talking &
      " tick(s) if you transmit every tick.\n")
  result.add("\nKEYS: " & $sim.keysCollected & " of " &
    $sim.config.keyCount & " collected; the gate is " &
    (if sim.gateOpen: "OPEN" else: "shut") & ".\n\n")
  result.add("YOUR NOTES:\n" &
    (if sim.notes[KeeperSeat].len > 0: sim.notes[KeeperSeat]
     else: "(none)") & "\n\n")
  var transcript: seq[string]
  let first = max(0, sim.messages.len - TranscriptLen)
  for index in first ..< sim.messages.len:
    transcript.add("tick " & $sim.messages[index][0] & ": \"" &
      sim.messages[index][1] & "\"")
  result.add("YOUR LAST TRANSMISSIONS:\n" &
    (if transcript.len > 0: transcript.join("\n")
     else: "(you have not spoken yet)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"transmit\": true, \"message\": \"…\", " &
    "\"notes\": \"…\"} — message at most " & $MaxMessageLen &
    " characters and reaching the runners next tick (transmit false for " &
    "silence, which costs the tide one unit instead of two); notes at " &
    "most " & $MaxKeeperNotes & " characters.")

proc runnerPrompt*(sim: Sim, runner: int, prompt: string): string =
  let seat = runner + 1
  result.add("Tick " & $sim.tick & " of " & $sim.config.maxTicks &
    ". You are a RUNNER and you are blind.\n\n")
  result.add("YOUR 3x3 WINDOW (you are @ in the middle; # wall, . floor, " &
    "~ water, K key, E exit with the gate shut, O exit with the gate " &
    "open, 1/2/3 another runner):\n")
  for line in sim.runnerWindow(runner):
    result.add(line & "\n")
  result.add("\nYOU HOLD " & $sim.keysHeld[runner] & " key" &
    (if sim.keysHeld[runner] == 1: "" else: "s") & ". The team has " &
    $sim.keysCollected & " of " & $sim.config.keyCount &
    " keys; the gate is " & (if sim.gateOpen: "OPEN — get to the exit"
      else: "shut") & ".\n\n")
  result.add("THE KEEPER SAID THIS TICK: " &
    (if sim.inbox.len > 0: "\"" & sim.inbox & "\"" else: "(silence)") &
    "\n")
  let age = sim.standingAge()
  if sim.standing.len > 0:
    result.add("YOUR STANDING ORDER (" & $age & " tick(s) old): \"" &
      sim.standing & "\"\n")
  else:
    result.add("YOUR STANDING ORDER: (none yet)\n")
  var history: seq[string]
  let first = max(0, sim.moveHistory[runner].len - MoveHistoryLen)
  for index in first ..< sim.moveHistory[runner].len:
    history.add(sim.moveHistory[runner][index])
  result.add("\nYOUR LAST MOVES: " &
    (if history.len > 0: history.join(", ") else: "(none yet)") & "\n\n")
  result.add("YOUR NOTES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"move\": \"N\", \"notes\": \"…\"} — move " &
    "is one of N, S, E, W, WAIT (N is up, S is down); notes at most " &
    $MaxRunnerNotes & " characters.")

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  if seat == KeeperSeat: keeperPrompt(sim, prompt)
  else: runnerPrompt(sim, seat - 1, prompt)

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    let head = cleanText(text, 160)
    raise newException(LighthouseError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a LighthouseError describing why
  ## there is none. Auth failures disable the client; model-access and
  ## throttle failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(LighthouseError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LighthouseError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LighthouseError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(LighthouseError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LighthouseError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LighthouseError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LighthouseError, "reply cut off at max_tokens " &
      "before any JSON: " & cleanText(result, 160).replace("\n", " "))

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
    payload{"message"}.getStr().replace("\n", " ").replace("\r", " "),
    MaxMessageLen)
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

proc retryHint(seat: int): string =
  if seat == KeeperSeat:
    "\nYour previous reply was invalid. Respond with ONLY the requested " &
      "JSON object, with \"transmit\" a boolean and \"message\" a string."
  else:
    "\nYour previous reply was invalid. Respond with ONLY the requested " &
      "JSON object, with \"move\" one of N, S, E, W, WAIT."

# ---- Decisions --------------------------------------------------------------

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Decisions are simultaneous
  ## by rule, so every LLM seat goes out in ONE parallel batch. Never
  ## raises: any failure falls back to the role-appropriate scripted
  ## baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let registered = if seat < scripted.len: scripted[seat] else: skNone
    if registered != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat, registered)
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat,
        (if seat < prompts.len: prompts[seat] else: ""))
      if attempt > 0:
        user.add(retryHint(seat))
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        result[index] = parseReply(seat, extractJsonObject(text))
      except CatchableError as error:
        echo "lighthouse llm: seat ", seat, " attempt ", attempt,
          " failed: ", error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "lighthouse llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skAuto)
