import std/[json, strutils]

type
  LighthouseError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    maxTicks*: int        ## ticks in the episode; the tide is on the clock
    width*: int           ## board width in tiles (odd, >= 9)
    height*: int          ## board height in tiles (odd, >= 9)
    tideDelay*: int       ## clock units before the first row floods
    tidePeriod*: int      ## clock units per flooded row
    keyCount*: int        ## keys that must be collected to open the gate
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Move* = enum
    mvWait = "WAIT"
    mvNorth = "N"
    mvSouth = "S"
    mvEast = "E"
    mvWest = "W"

  RunnerStatus* = enum
    rsActive = "active"
    rsEscaped = "escaped"
    rsDrowned = "drowned"

  EventKind* = enum
    evStart = "start"
    evTick = "tick"
    evSay = "say"
    evKey = "key"
    evEscape = "escape"
    evDrown = "drown"
    evEnd = "end"

  GameEvent* = object
    ## One flat record per event so eventToJson / eventFromJson stay simple.
    kind*: EventKind
    tick*: int              ## 0-based tick; end: ticks played; start: -1
    clock*: int             ## tick: the clock after the tick resolved
    tideRows*: int          ## tick: flooded rows after the tick resolved
    seat*: int              ## say: 0; key/escape/drown: 1..3; else -1
    x*: int                 ## key/drown: tile x; else -1
    y*: int                 ## key/drown: tile y; else -1
    positions*: seq[seq[int]]  ## tick: [[x, y] x 3], [-1, -1] when resolved
    alive*: seq[bool]          ## tick: [bool x 3]
    moves*: seq[string]        ## tick: ["N", "WAIT", ""] x 3
    blocked*: seq[bool]        ## tick: [bool x 3]
    keysOnFloor*: seq[seq[int]] ## tick: uncollected key tiles
    keysCollected*: int        ## tick / key: running total
    gateOpen*: bool            ## tick
    escaped*: int              ## tick / escape: running total
    drowned*: int              ## tick / drown: running total
    cost*: int                 ## say: the EXTRA clock unit the message cost
    notes*: seq[string]        ## tick: [string x 4], "" where unchanged
    scripted*: seq[bool]       ## tick: [bool x 4]
    text*: string              ## say: the message; end: the reason

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    maxTicks: 45,
    # 11 x 9, not the design note's 17 x 11: on a PERFECT maze the unique
    # start -> key -> exit path on a 17 x 11 board is 47 to 93 tiles, so
    # `escaped == 3` is unreachable inside maxTicks (capped at 55 by the
    # model-call budget) by any policy at all. See README, "Deviations".
    width: 11,
    height: 9,
    tideDelay: 10,
    # The design note's own tuning rule (Tests, test_bot #4) says to raise
    # this until a lantern + three wallhug team gets its keys and its
    # runners out. Measured: 4 and 5 do not, 7 does.
    tidePeriod: 7,
    keyCount: 3,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 18
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(LighthouseError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("maxTicks"):
    config.maxTicks = node["maxTicks"].getInt()
  if node.hasKey("width"):
    config.width = node["width"].getInt()
  if node.hasKey("height"):
    config.height = node["height"].getInt()
  if node.hasKey("tideDelay"):
    config.tideDelay = node["tideDelay"].getInt()
  if node.hasKey("tidePeriod"):
    config.tidePeriod = node["tidePeriod"].getInt()
  if node.hasKey("keyCount"):
    config.keyCount = node["keyCount"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.maxTicks < 4:
    raise newException(LighthouseError, "maxTicks must be at least 4")
  if config.width < 9 or config.width mod 2 == 0:
    raise newException(LighthouseError, "width must be odd and at least 9")
  if config.height < 9 or config.height mod 2 == 0:
    raise newException(LighthouseError, "height must be odd and at least 9")
  if config.keyCount < 1:
    raise newException(LighthouseError, "keyCount must be at least 1")
  if config.tidePeriod < 1:
    raise newException(LighthouseError, "tidePeriod must be at least 1")
