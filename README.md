# Lighthouse

**One cog sees the whole maze and cannot move; three cogs are blind.**

A cooperative game of structural information asymmetry for the Softmax
Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology stack
(forked from [cogame-babel](https://github.com/Metta-AI/cogame-babel), with
the simultaneous-decision batch and tick loop from
[cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip)).

A **keeper** sees the whole 11 × 9 perfect maze — every wall, every key,
every runner, the water line — and cannot move. Three blind **runners** see
only the 3 × 3 window around themselves and must collect three keys and
reach the single exit before the tide. The keeper's words are the only
bridge from the global view to the local one, and **every message costs a
tick**: there is one monotone `clock`, the tide is a pure function of it,
and a tick on which the keeper transmits advances the clock by 2 instead of
1. Water rises from the bottom row upward and never recedes.

A message transmitted on tick *t* reaches all three runners at the start of
tick *t + 1*. Runners have no channel at all — not to the keeper, not to
each other. The bridge is one-way by design; that is the asymmetry the game
is about. The gate at the exit is a single global latch that opens when all
three keys are in.

**The game is LLM-driven and a policy is just a prompt.** Every tick the
server composes each seat's observation — the whole map for the keeper, a
3 × 3 window plus the keeper's last words for a runner — adds that seat's
policy prompt, and asks Claude. Decisions are simultaneous by rule, so all
four seats' calls go out as **one parallel batch per tick**, never in
series. Player containers exist only to deliver their prompt over the
websocket.

Two built-in **scripted baselines** play any seat that registers as
scripted — and every seat when no LLM credentials are available, so
episodes (and offline certification) always complete:

- **`lantern`** (keeper): breadth-first search from the exit and from every
  uncollected key over the unflooded floor, greedy nearest-key assignment,
  and the next step of each runner's shortest path — aimed at the tile the
  runner will stand on when the words land, because a transmission always
  arrives a tick late. It transmits on a rhythm and breaks it when a runner
  bumps, when the water comes within two tiles, or when the gate opens.
- **`wallhug`** (runner): blind. Obey the keeper's last order for your alias
  while that direction is open and dry; if it is blocked, turn to the open
  direction nearest the ordered one; with no order, follow the left-hand
  wall. This is the grounded-instruction-following floor a champion prompt
  has to beat.

**Role substitution is mandatory.** The league seats fillers arbitrarily, so
a seat that registers `PLAYER_SCRIPTED=lantern` but is dealt a runner slot
plays `wallhug` instead, and vice versa. `PLAYER_SCRIPTED=1` just plays
whichever the dealt slot needs.

Seats play under **anonymous cog aliases** (Fresnel, Sprocket, Gizmo, …):
policy display names never reach the agents' prompts, so nobody can
meta-game "that seat is the champion". The spectator and replay viewers map
the aliases back to policy names for the audience; `results.json` reports
policy names. The maze and the aliases are redrawn from a fresh random seed
every episode, so no keeper–runner protocol can be pre-baked on a board.

## Scoring

```
K = keysCollected                            (0 .. keyCount)
E = escapedCount                             (0 .. 3)
B = if E == 3: clamp(1 - clock / floodClock, 0, 1) else 0

teamScore = 6 * (K / keyCount) + 10 * E + 6 * B          # range [0, 42]
```

**Higher is better**, and every one of the four seats gets the same number —
so a keeper's rank is exactly the mean of the teams it made work. The time
bonus is charged against the **clock**, not the tick count, so a chatty
keeper pays for its words twice. The episode ends `complete` (every runner
resolved, or the whole board flooded), `timeup` (the tick cap with someone
still in the maze), or `deadline` (the wall-clock play budget, 60 % of
`episodeTimeoutSeconds`, expired first).

Full rules, including the twelve numbered resolution steps and the tide
formula, are in
[`docs/plans/2026-08-22-lighthouse-design.md`](docs/plans/2026-08-22-lighthouse-design.md)
and in the manifest's `rules.md` page.

## Deviations from the design note

The accepted design note is
[`docs/plans/2026-08-22-lighthouse-design.md`](docs/plans/2026-08-22-lighthouse-design.md).
Four of its constants are **not** what shipped, because its own §Tests
`test_bot` thresholds are unreachable at them. Each is a one-line revert and
each is flagged in the code at the point of change.

| what | note | shipped | why |
|---|---|---|---|
| default board | 17 × 11 | **11 × 9** | On a *perfect* maze the unique start → key → exit path on a 17 × 11 board measures **47–93 tiles** (min over key/runner assignments of the max over runners; 47 is the best of the four fixture seeds, 93 the worst of sixty). `maxTicks` is 45 and is capped at 55 by `EpisodeCallBudget div CallsPerTick`, so `escaped == 3` was unreachable **by any policy at all**, LLM or scripted. |
| key placement | the *farthest* dead ends (`descending`) | the **nearest** dead ends (`ascending`) | Same measurement: a key in the far tail of a perfect maze cannot be fetched and carried back inside the tick budget. The dead-end + non-adjacent + `y ≤ height − 4` filters are unchanged, so a blind runner still cannot find a key without the keeper. |
| `tidePeriod` | 4 (`spring-tide` 3) | **7** (`spring-tide` **5**) | This is the note's *own* documented decision rule (§Tests, `test_bot` #4: "the fix is to raise `standard`'s `tidePeriod` … rather than to weaken the maze"). Measured: 4 and 5 do not clear its bar, 7 does. |
| `lantern` transmit | rhythm + three exceptions | same, plus **never twice in a row**, and an exception may only break the rhythm to say something **new** | With three runners, "any runner's step differs from the last message" fires almost every tick, giving a 64–68 % talk rate against the note's own ≤ 60 % bar. Not speaking twice in a row bounds it structurally at ~51 %. |
| `lantern` targeting | first step of the shortest path **from the runner's tile** | first step from the tile it will stand on **when the words land** | A message transmitted on tick *t* arrives at *t + 1*, by which time the runner has moved. Ordering the current tile's step is permanently one tile stale and oscillates on every corner. |

Everything else is the note as written: the twelve-step resolution order, the
tide formula, the scoring formula and its sign, the event vocabulary, both
protocols, the observation split, the reply schema and its rune caps,
`maxTicks` 45, `keyCount` 3, `num_agents` 4, the viewer composition, and the
policy set.

With the shipped values, `lantern` + three `wallhug` over the note's fixture
seeds `[1, 7, 42, 1234]`: **all three keys on 4 of 4** seeds, **all three
runners out on 3 of 4**, talk rate **51–52 %**, instruction-following
**89 %**, team scores **26–39** of a possible 42. Every threshold in the
note's §Tests passes as written; none was weakened.

## Field a policy

```bash
coworld upload-policy coworld-lighthouse:latest --name my-lighthouse \
  --run /bin/lighthouse-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Your prompt must work in **either** role — the platform may seat it
anywhere. `tools/ci/policies.json` holds the shipped set: two LLM champions
(`lighthouse-beacon`, `lighthouse-pilot`) and the two scripted baselines.

## Layout

```
src/lighthouse/types.nim    config, moves, statuses, the flat event record
src/lighthouse/sim.nim      pure rules: maze, tide, the twelve steps, replay
src/lighthouse/llm.nim      Claude transport, one parallel batch per tick,
                            lantern and wallhug
src/lighthouse/server.nim   the Coworld game contract and the tick loop
src/lighthouse.nim          game entrypoint            -> /bin/lighthouse
src/lighthouse_player.nim   prompt delivery            -> /bin/lighthouse-player
client/                     renderer.js, chrome.css, the three live pages
client/fixtures/            gen_fixture.js + sample_replay.json + dev_shell
replay-viewer/              the static wasm bundle (same sim, in the browser)
tools/build_replay_viewer.sh  the `coworld build` hook
tools/ci/                   docker_smoke.sh, policies.json
tests/                      test_sim, test_bot, test_replay
```

## Watching

Replays are a **static wasm bundle**, never a pod: the manifest declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`, and
`tools/build_replay_viewer.sh` compiles the *same* `sim` module to wasm and
bundles it with `renderer.js`, `chrome.css` and the sprites. The viewer
re-derives every frame in the browser from the recorded events; the only
network it does is the S3 `GET` of the `.replay` file.

The stage is one canvas: the god-view maze in chiselled stone, the
portcullis counting keys, amber keys bobbing on their tiles, a dark scrim
over everything outside the runners' 3 × 3 windows (the audience sees the
whole maze **and** exactly how little each runner does), the tide creeping
up as translucent teal with a crest and foam, the keeper's words running as
radio subtitles with a `◉ +1 TICK` cost badge, three corner thumbnails of
the cramped views, and a lighthouse whose beam flares on every transmit.

To eyeball it without a live episode:

```bash
node client/fixtures/gen_fixture.js       # regenerates sample_replay.json
python3 -m http.server -d client 8000     # then open /fixtures/dev_shell.html
```

## Development

The committed `nim.cfg` pins the author's package paths and is `.gitignore`d;
regenerate it per machine exactly as the Dockerfile and CI do:

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg
nim r --path:src tests/test_sim.nim
```

CI runs every `tests/*.nim` twice (debug and `-d:release`), then a raw-Docker
one-episode smoke in the production image with **no** `ANTHROPIC_API_KEY` —
so the all-scripted completion path is the one that has to work — then the
wasm viewer build.

## License

MIT. `data/font.ttf` ships with its own licence in `data/FONT_LICENSE.txt`.
