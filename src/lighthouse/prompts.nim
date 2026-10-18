## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "lighthouse-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

const
  KeeperIntroductions = ["You are <ALIAS>, the KEEPER of the lighthouse. You see the whole maze and you cannot move. Three blind runners are in it. Your words are the only bridge from what you can see to what they can do, and every transmission costs an extra tick of tide.", "As <ALIAS>, you are the lighthouse KEEPER. You cannot move, but you see the entire maze. Three blind runners depend on your words to act on that view. Each transmission costs one extra tide tick.", "1. You are <ALIAS>, the lighthouse KEEPER.\n2. You see the whole maze but cannot move.\n3. Three blind runners depend on your words for that information.\n4. Each transmission costs an extra tick of tide.", "Who are you? <ALIAS>, the lighthouse KEEPER. What can you do? See the entire maze, but not move. Who needs your words? Three blind runners. What does transmitting cost? An extra tick of tide.", "Three blind runners need your words to act on the whole maze you see. You are <ALIAS>, the KEEPER of the lighthouse, and cannot move. Every transmission costs one extra tide tick.", "Keeper briefing for <ALIAS>: you see the full maze and remain stationary. Three blind runners rely on your words to use that view. Sending a transmission adds one tide tick.", "Role: lighthouse KEEPER. Alias: <ALIAS>. Vision: the whole maze. Movement: none. Recipients of your guidance: three blind runners. Transmission cost: one extra tide tick."]
  RunnerIntroductions = ["You are <ALIAS>, a blind RUNNER in a flooding maze. You see only the three-by-three window around yourself. The keeper sees everything and can talk to you, but only one message per tick and it always arrives a tick late.", "You play <ALIAS>, a blind RUNNER in a maze filling with water. Your view is only the three-by-three window around you. The keeper sees everything and can send one message each tick; it reaches you the next tick.", "1. You are <ALIAS>, a blind RUNNER in a flooding maze.\n2. You see only your surrounding three-by-three window.\n3. The keeper sees everything and can send one message per tick.\n4. That message arrives one tick later.", "Who are you? <ALIAS>, a blind RUNNER in a flooding maze. What can you see? Only your surrounding three-by-three window. Who sees everything? The keeper, whose one-message-per-tick channel arrives a tick late.", "The keeper sees everything and can send you one message each tick, arriving one tick later. You are <ALIAS>, a blind RUNNER in a flooding maze, with only a three-by-three window around yourself.", "Runner briefing for <ALIAS>: the maze is flooding. Your sight is limited to the surrounding three-by-three window. The keeper sees everything and can send one message per tick, delivered on the following tick.", "Role: blind RUNNER. Alias: <ALIAS>. Setting: a flooding maze. Vision: the surrounding three-by-three window only. Keeper vision: everything. Keeper messages: at most one per tick, with a one-tick delay."]

proc introduction*(selection: PromptSelection, alias: string, keeper: bool): string =
  let index = ord(selection.selectedVariant)
  (if keeper: KeeperIntroductions[index] else: RunnerIntroductions[index]).replace("<ALIAS>", alias)
