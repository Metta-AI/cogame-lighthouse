## Export complete native episodes with the exact hosted prompts and replies.

import std/[json, os, osproc, strutils]
import lighthouse/[sim, rules, player_policy, evidence]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: lighthouse-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  doAssert selection.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference},
    "held-out wording is evaluation only"
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "commit qualified source before exporting pinned candidates"
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
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    records: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    let family = "lighthouse-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant
    var rows: seq[JsonNode]
    while not game.done:
      let seats = game.pendingSeats()
      var
        spoke = false
        message = ""
        moves: array[Runners, Move]
        notes: array[Seats, string]
        scripted: array[Seats, bool]
      for seat in seats:
        let view = game.seatDecisionView(seat)
        let decision = scriptedActionFromView(view)
        let prompts = promptsFromView(selection, view, "")
        let completion = decisionJson(seat, decision)
        let accepted = parseReply(seat, completion)
        doAssert accepted.move == decision.move
        doAssert accepted.transmit == decision.transmit
        doAssert accepted.message == (if decision.transmit: decision.message else: "")
        let messages = %*[{"role": "system", "content": prompts.system},
          {"role": "user", "content": prompts.user}]
        let attemptId = $rows.len & "-teacher"
        rows.add(%*{"schema_version": "1", "event_type": "decision",
          "episode_id": episode, "decision_id": $rows.len, "decision_index": rows.len,
          "game": "lighthouse", "game_version": "source-" & revision,
          "source_revision": revision, "seat": $seat, "visibility": "private",
          "observation": {"view": view,
            "prompt_template": selection.promptMetadata(prompts.system, prompts.user)},
          "prompt": messages, "attempts": [{"attempt_id": attemptId,
            "policy": "private-view-teacher", "origin": "teacher", "inference_mode": "text_action",
            "prompt": messages, "response": $completion, "parsed_action": decisionJson(seat, accepted),
            "accepted": true, "rejection_reason": newJNull(), "request": newJNull(),
            "platform_call_id": newJNull(), "behavior_logprobs": newJNull()}],
          "selected_attempt_id": attemptId, "executed_action": decisionJson(seat, accepted),
          "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
        notes[seat] = accepted.notes
        scripted[seat] = true
        if seat == KeeperSeat:
          spoke = accepted.transmit
          message = accepted.message
        else:
          moves[seat - 1] = accepted.move
      game.applyTick(spoke, message, moves, notes, scripted)
    let results = game.resultsJson()
    doAssert game.tick <= config.maxTicks
    doAssert game.reason in ["complete", "timeup"]
    let replayConfig = game.seededConfigJson()
    replayConfig["seed"] = %config.seed
    replayConfig["maxTicks"] = %config.maxTicks
    replayConfig["width"] = %config.width
    replayConfig["height"] = %config.height
    replayConfig["tideDelay"] = %config.tideDelay
    replayConfig["tidePeriod"] = %config.tidePeriod
    replayConfig["keyCount"] = %config.keyCount
    replayConfig["messageCap"] = %MaxMessageLen
    replayConfig["sampled"] = %true
    let frames = replayMatch(config, game.events, replayConfig)
    doAssert frames[^1].resultsJson() == results
    doAssert frames[^1].events.len == game.events.len
    for index, event in game.events:
      doAssert frames[^1].events[index].eventToJson() == event.eventToJson()
    var events = newJArray()
    for event in game.events: events.add(event.eventToJson())
    var participants = newJObject()
    for seat in 0 ..< Seats: participants[$seat] = %*{"score": results["scores"][seat]}
    var gameRecords: seq[string]
    for index, row in rows:
      row["terminal"] = %(index == rows.high)
      gameRecords.add($row)
    gameRecords.add($(%*{"schema_version": "1", "event_type": "episode",
      "episode_id": episode, "seed_family": family, "game": "lighthouse",
      "game_version": "source-" & revision, "source_revision": revision,
      "status": "completed", "outcome": results, "participant_outcomes": participants}))
    records.add(gameRecords)
    writePrivate(output / (episode & ".jsonl"), gameRecords.join("\n") & "\n")
    writePrivate(output / (episode & ".replay.json"), $(%*{
      "protocol": "lighthouse.replay.v1", "names": game.names,
      "policyNames": results["names"], "config": replayConfig,
      "events": events, "results": results}) & "\n")
    runs.add(%*{"seed": seed, "episode_id": episode, "turns": game.tick,
      "decisions": rows.len, "score": results["teamScore"], "reason": results["reason"],
      "trajectory": episode & ".jsonl", "replay": episode & ".replay.json"})
  writePrivate(output / "trajectories.jsonl", records.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": "1", "format": "coworld-private-candidates-v1", "review_required": true,
    "game": "lighthouse", "variant": variant, "source_revision": revision,
    "teacher": "private-view-teacher", "prompt_selection": selection.selectionMetadata(),
    "runs": runs}) & "\n")
  echo "complete games=", episodes
