# Lighthouse training

The exporter plays ten complete native episodes per certified variant.
It records each seat's exact hosted system and user prompts, plus replies
accepted by the production parser. Decisions within a tick use the same
simulator state, then the native simulator resolves them together. Train
and validation sets split complete episodes by seed.

```sh
nim c -d:release --path:src -o:/tmp/lighthouse-posttrain tools/export_posttrain.nim
/tmp/lighthouse-posttrain /tmp/lighthouse-data 10 standard
```

The other certified variant is `spring-tide`. The output has
`train.jsonl`, `validation.jsonl`, and a manifest with source revision,
seeds, ticks, scores, and row counts. Ten matches yielded 976/221
standard and 797/214 spring-tide train/validation decisions.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/lighthouse-data --output /tmp/lighthouse-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes the hosted prompts and 219 numeric values.
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
