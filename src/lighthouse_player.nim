## Lighthouse player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Lighthouse strategy), then idles until the final frame. All of
## the actual decision making happens inside the game server, which sends
## this seat's prompt plus its observation to Claude every tick.
##
## PLAYER_SCRIPTED=lantern registers the seat as the built-in keeper
## baseline, PLAYER_SCRIPTED=wallhug as the runner baseline, and
## PLAYER_SCRIPTED=1 as whichever of the two the dealt slot needs. The
## server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <lighthouse-image> --name my-lighthouse \
##     --run /bin/lighthouse-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

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
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "lighthouse player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "lighthouse player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "lighthouse player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "lighthouse player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (", payload{"role"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "final":
        echo "lighthouse player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "lighthouse player: ignoring bad frame: ", error.msg
  socket.close()
