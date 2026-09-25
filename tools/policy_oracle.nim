import std/[json, os]
import lighthouse/[rules, player_policy, sim]

var records = newJArray()
for seed in [1, 7, 42, 1234, 3, 5, 11, 13, 21, 55]:
  var config = defaultGameConfig()
  config.seed = seed
  config.sampled = true
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "P" & $seat))
    config.tokens.add("t" & $seat)
  var game = initSim(config)
  while not game.done:
    var moves: array[Runners, Move]
    var notes: array[Seats, string]
    var scripted: array[Seats, bool]
    var spoke = false
    var message = ""
    for seat in game.pendingSeats():
      let action = scriptedAction(game, seat, skAuto)
      records.add(%*{"view": game.seatDecisionView(seat),
        "action": decisionJson(seat, action)})
      scripted[seat] = true
      if seat == 0:
        spoke = action.transmit
        message = action.message
      else:
        moves[seat - 1] = action.move
    game.applyTick(spoke, message, moves, notes, scripted)
writeFile(paramStr(1), $records)
