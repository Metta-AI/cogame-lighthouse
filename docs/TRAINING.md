# Lighthouse training

## Episode wording

Set `promptVariant` and `promptSeed` in game configuration or bridge resets.
The `lighthouse-rules-v1` bank provides five training introductions: `canonical`,
`plain`, `numbered`, `questions`, and `reordered`. `mixed` requires a nonnegative
prompt seed and resolves modulo five once per episode, independently of maze randomness.
Both native and ordinary Python players consume the game-owned selection and reject
changes within an episode. Their existing prompt formats remain separate.

Only the introduction varies. Shared role rules, private views, and reply schemas
stay fixed. The native keeper description now correctly charges an extra tide tick
per transmission; the previous text incorrectly charged each word. Other canonical
prompt bytes remain unchanged.

`heldout-briefing` and `heldout-reference` are evaluation-only. Training resets and
source exports reject them. Private metadata hashes the actual rendered messages.
The bridge's `--language` mode accepts full role actions, including private notes;
numeric observations and action choices are unchanged.

`LIGHTHOUSE_CAPTURE_DIR` enables private host and bundled-player JSONL evidence.
The host records private observations, received frames, resolved actions, and applied
events. The bundled player records actual request bodies, responses, parsed actions,
and acknowledgements. Interrupted or rejected calls retain only evidence that occurred;
provider authorization headers are excluded. These diagnostic traces are not automatically
admitted to training.

## Ordinary player collection

Build `Dockerfile.ordinary-player` and seat it through the normal Coworld
player socket. The default policy chooses the role-specific scripted action.
`LIGHTHOUSE_ADAPTER_DIR` selects a trained adapter when the player image
also packages its base model, PyTorch, Transformers, and PEFT. The keeper
sends `transmit`, `message`, and `notes`; runners send `move` and `notes`.
All actions pass through the game's existing parser and tick resolver.

Set `LIGHTHOUSE_CAPTURE_TRAINING=1` and `LIGHTHOUSE_SOURCE_REVISION` on the
player to upload schema-2 accepted-decision archives. Local files have owner-only
permissions. Also enable host evidence with `LIGHTHOUSE_CAPTURE_DIR`; keep its
`host.jsonl` under each run's `private/` directory alongside config, results, and replay.
Export at least ten complete seed families:

```sh
python3 players/ordinary/export.py /tmp/lighthouse-candidates \
  /tmp/lighthouse-run-{1..10} \
  --source-revision <game-source-sha> --replay-verifier /tmp/lighthouse-replay
```

The exporter verifies source identity, actual private views, prompt hashes, received
frames, resolved actions, and complete replay events. It rejects held-out wording,
deadline endings, and incomplete decision coverage. It emits private review-required
candidates, not training splits. Canned decisions are teachers; adapter decisions
have unknown origin because these archives do not retain model-generation evidence.
The shared importer owns review, admission, and scenario-family splits. Older schema-1
archives lack operator guidance and cannot qualify through this exporter; recollect
those runs without modifying retained archives.

The native source exporter plays at least ten complete episodes per certified variant.
It records prompts built from each private view and scripted replies passed through
the production parser. Decisions within a tick use the same simulator state, then
the native simulator resolves them together. Every event and final score must
rederive from the replay. Export requires clean, committed source.

```sh
nim c -d:release --path:src -o:/tmp/lighthouse-posttrain tools/export_posttrain.nim
/tmp/lighthouse-posttrain /tmp/lighthouse-data 10 standard
# Optional wording and independent prompt seed:
/tmp/lighthouse-posttrain /tmp/lighthouse-plain 10 spring-tide plain 0
```

The output contains private canonical trajectories, per-episode replays, and a
review-required manifest. The shared importer owns admission and dataset splits.
All wording and game variants share `lighthouse-SEED` scenario families. Scripted
source evidence does not establish hosted sampling parity or model quality.

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
nim c -d:release --path:src -o:/tmp/lighthouse-replay tools/check_replay.nim
python3 tools/test_training.py /tmp/lighthouse-posttrain /tmp/lighthouse-train-bridge /tmp/lighthouse-replay
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
