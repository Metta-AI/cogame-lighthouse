## Lighthouse bundled prompt and scripted policies. Every decision is made
## here from the ordinary private turn observation and submitted to the game.
##
## To field a prompt policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <lighthouse-image> --name my-lighthouse \
##     --run /bin/lighthouse-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky,
  lighthouse/[rules, player_policy, evidence]

const DefaultPrompt = """
As KEEPER: you are the only one who can see. Spend ticks on words only
when the words change what a runner will do - every transmit costs one
extra tick of tide. Batch all three runners into one line in the
grounded form "<Alias> <N|S|E|W|hold>", semicolon separated. Give the
NEXT SINGLE STEP, never a route: a blind runner cannot hold a route.
Re-issue a runner's step only when it changed, when it bumped, or when
water is within two tiles of it; otherwise stay silent and let the
standing order run. Send runners at the nearest uncollected key first,
and the instant all keys are in, drive everyone at the exit.
As RUNNER: you are blind. Obey the keeper's last order for your alias as
long as that direction is open in your 3x3 window. If it is blocked,
take the open direction closest to the ordered one. With no order, hug
the left wall consistently so the keeper can predict you. Never step
into water. Keep your last few moves and bumps in your notes so the
keeper's corrections make sense.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = parseScriptKind(getEnv("PLAYER_SCRIPTED")) != skNone
  let client =
    if scripted: nil
    else: newLlmClient(
      getEnv("PLAYER_MODEL", "claude-sonnet-5"),
      parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")),
      parseInt(getEnv("PLAYER_TIMEOUT_SECONDS", "18")))

  echo "lighthouse player: connecting to game"
  let socket = newWebSocket(url)
  let captureDirectory = getEnv("LIGHTHOUSE_CAPTURE_DIR")
  var trace = ""
  var slot = -1
  var episodeSelection = none(PromptSelection)

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "lighthouse player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    let payload = parseJson(message.data)
    case payload{"type"}.getStr()
    of "welcome":
      slot = payload["slot"].getInt()
      if captureDirectory.len > 0:
        trace = captureDirectory / ("player-" & $slot & ".jsonl")
        writePrivate(trace, $(%*{"event_type": "player_started", "visibility": "private",
          "seat": slot, "source_revision": staticExec("git rev-parse HEAD").strip(),
          "source_dirty": staticExec("git status --porcelain").strip().len > 0}) & "\n")
      echo "lighthouse player: seated at slot ", slot,
        " as ", payload["name"].getStr(),
        " (", payload["role"].getStr(), ")"
    of "turn":
      let metadata = payload["prompt_configuration"]
      let selection = promptSelection(%*{"promptVariant": metadata["selection"], "promptSeed": metadata["seed"]})
      doAssert metadata == selection.selectionMetadata()
      if episodeSelection.isSome:
        doAssert episodeSelection.get() == selection, "prompt selection changed during episode"
      else:
        episodeSelection = some(selection)
      let view = payload["view"]
      let fallback = scripted or client.disabled
      let decision =
        if fallback: scriptedActionFromView(view)
        else: choosePromptAction(client, selection, view, prompt, slot)
      if captureDirectory.len > 0:
        appendPrivate(trace, %*{"event_type": "decision_sent", "visibility": "private",
          "seat": slot, "tick": payload["tick"], "view": view,
          "prompt_selection": selection.selectionMetadata(), "scripted": fallback,
          "action": decisionJson(slot, decision)})
      socket.send($ %*{
        "type": "decision", "tick": payload["tick"],
        "source": (if fallback: "scripted" else: "player"),
        "action": decisionJson(slot, decision)
      })
    of "decision_result":
      if captureDirectory.len > 0:
        appendPrivate(trace, %*{"event_type": "decision_result", "visibility": "private",
          "seat": slot, "tick": payload["tick"], "accepted": payload["accepted"]})
      if not payload["accepted"].getBool():
        raise newException(ValueError,
          "game rejected player action on tick " & $payload["tick"].getInt())
    of "final":
      if captureDirectory.len > 0:
        appendPrivate(trace, %*{"event_type": "player_completed", "visibility": "private",
          "seat": slot, "result": payload})
      echo "lighthouse player: final scores ", payload{"scores"}
      break
    else:
      discard
  socket.close()
