## Lighthouse model and prompt policy. Only player processes import
## this module; the game owns rules, visibility, resolution, and replay.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim,
  rules

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  TranscriptLen = 5
  MoveHistoryLen = 6
  StandingMaxAge = 3

type
  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    sidecarEndpoint: string
    bedrockEndpoint: string ## local Bedrock transport
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable


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

proc newLlmClient*(model: string, maxOutputTokens, timeoutSeconds: int): LlmClient =
  result = LlmClient(
    model: model,
    maxOutputTokens: maxOutputTokens,
    timeoutSeconds: timeoutSeconds
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
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

proc keeperSimFromView(view: JsonNode): Sim =
  ## Rebuild only the keeper-visible rule state used by the prompt and
  ## lantern policy. No other player's private notes enter this object.
  result.config.maxTicks = view["maxTicks"].getInt()
  result.config.keyCount = view["keyCount"].getInt()
  result.config.tideDelay = view["tideDelay"].getInt()
  result.config.tidePeriod = view["tidePeriod"].getInt()
  for row in view["maze"]:
    result.grid.add(row.getStr())
  result.config.height = result.grid.len
  result.config.width = result.grid[0].len
  result.exitAt = (view["exit"][0].getInt(), view["exit"][1].getInt())
  for tile in view["keysOnFloor"]:
    result.keysOnFloor.add((tile[0].getInt(), tile[1].getInt()))
  result.names.add(view["alias"].getStr())
  for index in 0 ..< view["runners"].len:
    let runner = view["runners"][index]
    result.names.add(runner["alias"].getStr())
    result.status[index] = parseEnum[RunnerStatus](runner["status"].getStr())
    result.pos[index] = (
      runner["position"][0].getInt(), runner["position"][1].getInt())
    result.keysHeld[index] = runner["keysHeld"].getInt()
    result.lastMove[index] = parseMoveToken(runner["lastMove"].getStr())
    result.blocked[index] = runner["blocked"].getBool()
  result.keysCollected = view["keysCollected"].getInt()
  result.gateOpen = view["gateOpen"].getBool()
  result.tick = view["tick"].getInt()
  result.clock = view["clock"].getInt()
  result.notes[KeeperSeat] = view["notes"].getStr()
  for entry in view["messages"]:
    result.messages.add((entry["tick"].getInt(), entry["text"].getStr()))
  if view["lastMessageClock"].getInt() >= 0:
    result.events.add(GameEvent(kind: evTick,
      tick: result.messages[^1][0],
      clock: view["lastMessageClock"].getInt()))
  if view["keyJustCollected"].getBool():
    result.events.add(GameEvent(kind: evKey,
      tick: result.tick - 1, keysCollected: result.config.keyCount))

proc scriptedActionFromView*(view: JsonNode): Decision =
  ## A bundled scripted player computes its own action from the ordinary
  ## private observation; the game uses its full Sim only for a timeout.
  if view["role"].getStr() == "keeper":
    return lanternAction(keeperSimFromView(view))
  result.scripted = true
  result.move = mvWait
  let window: array[3, string] = [
    view["window"][0].getStr(), view["window"][1].getStr(),
    view["window"][2].getStr()]
  let alias = view["alias"].getStr()
  var order = orderedDirection(view["inbox"].getStr(), alias)
  if not order.found and view["standingAge"].getInt() in 0 .. StandingMaxAge:
    order = orderedDirection(view["standing"].getStr(), alias)
  if order.found:
    if order.move == mvWait:
      return
    if passable(window, order.move):
      result.move = order.move
      return
    for candidate in [turnRight(order.move), turnLeft(order.move),
        turnBack(order.move)]:
      if passable(window, candidate):
        result.move = candidate
        return
    return
  var heading = mvNorth
  for index in countdown(view["moveHistory"].len - 1, 0):
    let token = view["moveHistory"][index].getStr().split(' ')[0]
    if token != $mvWait:
      heading = parseMoveToken(token)
      break
  for candidate in [turnLeft(heading), heading, turnRight(heading),
      turnBack(heading)]:
    if passable(window, candidate):
      result.move = candidate
      return

proc promptsFromView*(view: JsonNode, prompt: string):
    tuple[system, user: string] =
  if view["role"].getStr() == "keeper":
    let sim = keeperSimFromView(view)
    return (systemPrompt(sim, KeeperSeat), userPrompt(sim, KeeperSeat, prompt))
  var sim: Sim
  sim.names = @["", view["alias"].getStr()]
  result.system = systemPrompt(sim, 1)
  result.user = "Tick " & $view["tick"].getInt() & " of " &
    $view["maxTicks"].getInt() & ". You are a RUNNER and you are blind.\n\n" &
    "YOUR 3x3 WINDOW (@ is you; # wall, . floor, ~ water, K key, " &
    "E shut exit, O open exit):\n" &
    view["window"][0].getStr() & "\n" &
    view["window"][1].getStr() & "\n" &
    view["window"][2].getStr() & "\n\n" &
    "YOU HOLD " & $view["keysHeld"].getInt() & " keys. The team has " &
    $view["keysCollected"].getInt() & " of " &
    $view["keyCount"].getInt() & " keys; gate open: " &
    $view["gateOpen"].getBool() & ".\n" &
    "THE KEEPER SAID THIS TICK: " & view["inbox"].getStr() & "\n" &
    "YOUR STANDING ORDER (age " & $view["standingAge"].getInt() &
    "): " & view["standing"].getStr() & "\n" &
    "YOUR LAST MOVES: " & $(view["moveHistory"]) & "\n" &
    "YOUR NOTES: " & view["notes"].getStr() & "\n\n" &
    operatorBlock(prompt) &
    "Reply with ONLY {\"move\": \"N\", \"notes\": \"…\"} — move " &
    "is one of N, S, E, W, WAIT; notes at most " &
    $MaxRunnerNotes & " characters."

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

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
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

# ---- Decisions --------------------------------------------------------------

proc choosePromptAction*(client: LlmClient, view: JsonNode,
    prompt: string, seat: int): Decision =
  let prompts = promptsFromView(view, prompt)
  var batch: RequestBatch
  var request = client.requestFor(prompts.system, prompts.user, -1)
  if client.transport == ltSidecar:
    request.headers["x-coworld-player-slot"] = $seat
  batch.post(request.url, request.headers, request.body, $seat)
  let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
  let answer = client.textOf(responses[0].response,
    responses[0].error, request.url)
  parseReply(seat, extractJsonObject(answer))
