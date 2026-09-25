## Export complete native episodes with the exact hosted prompts and replies.

import std/[json, os, osproc, strutils]
import lighthouse/[sim, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: lighthouse-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      let seats = game.pendingSeats()
      var
        spoke = false
        message = ""
        moves: array[Runners, Move]
        notes: array[Seats, string]
        scripted: array[Seats, bool]
      for seat in seats:
        let decision = scriptedAction(game, seat, skAuto)
        let completion = decisionJson(seat, decision)
        let accepted = parseReply(seat, completion)
        doAssert accepted.move == decision.move
        doAssert accepted.transmit == decision.transmit
        doAssert accepted.message == (if decision.transmit: decision.message else: "")
        rows.add($(%*{
          "episode_id": "lighthouse-" & variant & "-" & $seed,
          "seed": "lighthouse-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat)},
            {"role": "user", "content": userPrompt(game, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "lighthouse",
          "action_schema_revision": "lighthouse-reply-v1"
        }))
        notes[seat] = decision.notes
        scripted[seat] = true
        if seat == KeeperSeat:
          spoke = decision.transmit
          message = decision.message
        else:
          moves[seat - 1] = decision.move
      game.applyTick(spoke, message, moves, notes, scripted)
    let results = game.resultsJson()
    doAssert game.tick <= config.maxTicks
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "turns": game.tick, "decisions": rows.len,
      "score": results["teamScore"], "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "lighthouse", "variant": variant,
    "source_revision": revision, "teacher": "lantern-and-wallhug",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
