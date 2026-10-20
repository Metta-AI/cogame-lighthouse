"""Export accepted ordinary-player decisions from complete Lighthouse episodes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import zipfile
from pathlib import Path

from prompt_selection import PromptSelection


def export(
    runs: list[Path],
    output: Path,
    revision: str,
    source: str,
    validation_modulus: int = 5,
) -> dict:
    if validation_modulus < 2:
        raise ValueError("validation modulus must be at least two")
    splits: dict[str, list[str]] = {"train": [], "validation": []}
    episodes: list[dict] = []
    episode_ids: set[str] = set()
    for run in runs:
        config = json.loads((run / "config.json").read_text())
        results = json.loads((run / "results.json").read_text())
        seed = config["seed"]
        if results["reason"] not in ("complete", "timeup"):
            raise ValueError(f"incomplete game {run}")
        split = "validation" if seed % validation_modulus == 0 else "train"
        count = 0
        for artifact in sorted(run.glob("policy_artifact_*.zip")):
            slot = int(artifact.stem.removeprefix("policy_artifact_"))
            with zipfile.ZipFile(artifact) as archive:
                content = archive.read("trajectory.json")
                trajectory = json.loads(content)
            episode_id = (
                f"lighthouse-{seed}-seat-{slot}-{hashlib.sha256(content).hexdigest()}"
            )
            if episode_id in episode_ids:
                raise ValueError(f"duplicate training capture {artifact}")
            episode_ids.add(episode_id)
            if (
                trajectory["schema_version"] not in (1, 2)
                or trajectory["game"] != "lighthouse"
                or trajectory["slot"] != slot
                or trajectory["source_revision"] != revision
                or trajectory["complete"] is not True
                or trajectory["reason"] != results["reason"]
                or trajectory["scores"] != results["scores"]
            ):
                raise ValueError(f"invalid training artifact {artifact}")
            for row in trajectory["decisions"]:
                if "prompt_template" in row:
                    metadata = row["prompt_template"]
                    selection = PromptSelection.model_validate(
                        {
                            key: metadata[key]
                            for key in ("bank", "variant", "selection", "seed")
                        }
                    )
                    if selection.variant.startswith("heldout-"):
                        raise ValueError("held-out wording cannot enter training")
                    system, user = (message["content"] for message in row["prompt"])
                    if selection.metadata(system, user) != metadata:
                        raise ValueError("captured prompt hashes differ")
                if row["source"] != source:
                    continue
                example = {
                    "episode_id": episode_id,
                    "seed": f"lighthouse-{seed}",
                    "decision_id": row["decision_id"],
                    "prompt": row["prompt"],
                    "completion": row["completion"],
                    "game": "lighthouse",
                    "action_schema_revision": "lighthouse-reply-v1",
                }
                if "prompt_template" in row:
                    example["prompt_template"] = row["prompt_template"]
                splits[split].append(json.dumps(example, ensure_ascii=False))
                count += 1
        if count == 0:
            raise ValueError(f"no {source} decisions in {run}")
        episodes.append({"seed": seed, "decisions": count, "scores": results["scores"]})
    if not all(splits.values()):
        raise ValueError("training and validation need separate complete game seeds")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for split, rows in splits.items():
        path = output / f"{split}.jsonl"
        with os.fdopen(
            os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w"
        ) as destination:
            destination.write("\n".join(rows) + "\n")
    manifest = {
        "schema_version": 1,
        "game": "lighthouse",
        "source_revision": revision,
        "action_schema_revision": "lighthouse-reply-v1",
        "teacher": source,
        "train_examples": len(splits["train"]),
        "validation_examples": len(splits["validation"]),
        "episodes": episodes,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--source", default="canned")
    parser.add_argument("--validation-modulus", type=int, default=5)
    args = parser.parse_args()
    directories = [
        episode
        for run in args.runs
        for episode in (
            sorted(run.glob("episode-*"))
            if not (run / "results.json").exists()
            else [run]
        )
    ]
    print(
        export(
            directories,
            args.output,
            args.source_revision,
            args.source,
            args.validation_modulus,
        )
    )
