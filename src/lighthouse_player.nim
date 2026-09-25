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
  lighthouse/[rules, player_policy]

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
  var slot = -1

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
      echo "lighthouse player: seated at slot ", slot,
        " as ", payload["name"].getStr(),
        " (", payload["role"].getStr(), ")"
    of "turn":
      let view = payload["view"]
      let fallback = scripted or client.disabled
      let decision =
        if fallback: scriptedActionFromView(view)
        else: choosePromptAction(client, view, prompt, slot)
      socket.send($ %*{
        "type": "decision", "tick": payload["tick"],
        "source": (if fallback: "scripted" else: "player"),
        "action": decisionJson(slot, decision)
      })
    of "decision_result":
      if not payload["accepted"].getBool():
        raise newException(ValueError,
          "game rejected player action on tick " & $payload["tick"].getInt())
    of "final":
      echo "lighthouse player: final scores ", payload{"scores"}
      break
    else:
      discard
  socket.close()
