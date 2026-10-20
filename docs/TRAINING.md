# Lighthouse training

## Episode wording

The shared `players/ordinary/prompt_bank.json` contains five training presentations
and two evaluation-only presentations. Native and ordinary players use the same
complete rules for maze geometry, keys, tide timing, team score, and communication.
Role visibility, private notes, and action syntax stay fixed. Ordinary players now
receive the scoring and maze rules that their shorter prompt previously omitted.

Set `promptVariant` and `promptSeed` in game configuration or bridge resets.
`mixed` resolves once per episode without consuming simulation randomness.
The `lighthouse-rules-v3` bank keeps native canonical text, including the correction
that each transmission costs an extra tide tick, rather than each word.
Deploy the game and players together; players reject a different bank or changed
selection within an episode. Held-out presentations cannot enter training.

## Source exports

```sh
lighthouse-posttrain PRIVATE_OUTPUT 10 standard mixed 0
```

The original train/validation JSONL and manifest are retained. Teacher actions pass
through the production parser and simulator with the exact private view and selected
prompt. Every fifth seed is validation; mixed wordings cycle separately within each
split so all five presentations appear in training. Families use `lighthouse-SEED`
across game variants. Run from clean committed source for reproducible revision pins.

## Ordinary player collection

Build `Dockerfile.ordinary-player` and use the normal player socket. The default
policy is scripted; `LIGHTHOUSE_ADAPTER_DIR` selects an adapter when its model and
training dependencies are installed. Set `LIGHTHOUSE_CAPTURE_TRAINING=1` and
`LIGHTHOUSE_SOURCE_REVISION` to retain accepted decisions in ordinary artifacts.
Captures include exact prompt hashes and use owner-only local permissions.

```sh
python3 players/ordinary/export.py PRIVATE_OUTPUT RUN_DIRECTORY... \
  --source-revision SOURCE_SHA
```

The original train/validation exporter accepts complete or tick-capped episodes.
Stored version-one archives without prompt metadata and version-two archives remain
readable. New metadata is verified, and held-out wording is rejected. Source and
scenario families must match before training. These checks do not qualify model
sampling evidence or establish improved learned robustness.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes the bundled player's prompts and 219 numeric values.
The keeper sees the complete maze; runners see only their own 3×3 window,
last move, keys, bump flag, and public team state. Invisible map cells are
zero and masked. Two choices select the published scripted policy or a
legal silent/wait action. The cooperative score is divided by 42 for a
bounded [0, 1] utility. Post-training above retains arbitrary legal JSON
replies and keeper messages.

```sh
nim c -d:release --path:src -o:/tmp/lighthouse-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/lighthouse-posttrain /tmp/lighthouse-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=4` and choose `standard` or `spring-tide`.

Both variants completed 512 Metta RL timesteps with checkpoints and held-out
evaluation. Native PufferLib trained 4,096 CUDA timesteps per variant in
Slurm job 9054, then reloaded each checkpoint for four games on each of
seeds 101 and 102. Standard scored 28.91 and 18.47; spring-tide scored 12.50
and 18.50. These bounded runs verify execution, not stronger league play.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.

Exported episode IDs include the selected wording and prompt seed, so matched
wording collections remain distinct. The gameplay seed still groups related scenarios.

Version three gives numbered, question-led, reordered, and both held-out briefings
independent rule phrasing. Canonical and plain text remain unchanged. Historical
version-one and version-two captures remain readable with their recorded hashes.
