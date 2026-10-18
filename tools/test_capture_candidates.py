"""Verify complete ordinary-game exports and rejection of corrupted evidence."""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("verifier", type=Path)
parser.add_argument("revision")
parser.add_argument("runs", nargs="+", type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="lighthouse-candidate-proof-") as directory:
    root = Path(directory)
    for case in ("complete", "hash", "completion", "missing", "heldout"):
        run = root / case
        shutil.copytree(args.runs[0], run)
        if case in ("hash", "completion"):
            path = run / "policy_artifact_0.zip"
            with zipfile.ZipFile(path) as archive:
                trajectory = json.loads(archive.read("trajectory.json"))
            if case == "hash":
                trajectory["decisions"][0]["prompt_template"]["system_sha256"] = (
                    "0" * 64
                )
            else:
                trajectory["decisions"][0]["completion"][0]["content"] = "{}"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("trajectory.json", json.dumps(trajectory))
        elif case == "missing":
            path = run / "private/host.jsonl"
            events = [json.loads(line) for line in path.read_text().splitlines()]
            index = next(
                i
                for i, event in enumerate(events)
                if event["event_type"] == "decision_resolved"
            )
            del events[index]
            path.write_text("\n".join(json.dumps(event) for event in events) + "\n")
        elif case == "heldout":
            path = run / "private/host.jsonl"
            events = [json.loads(line) for line in path.read_text().splitlines()]
            events[0]["prompt_selection"].update(
                variant="heldout-briefing", selection="heldout-briefing"
            )
            path.write_text("\n".join(json.dumps(event) for event in events) + "\n")
        output = root / (case + "-export")
        result = subprocess.run(
            [
                sys.executable,
                ROOT / "players/ordinary/export.py",
                output,
                run,
                *args.runs[1:],
                "--source-revision",
                args.revision,
                "--replay-verifier",
                args.verifier,
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if case == "complete":
            assert result.returncode == 0, result.stderr
            manifest = json.loads((output / "manifest.json").read_text())
            assert manifest["review_required"] and manifest["seed_families"] >= 10
            assert not (output / "train.jsonl").exists()
            assert all(
                path.stat().st_mode & 0o777 == 0o600 for path in output.iterdir()
            )
            records = [
                json.loads(line)
                for line in (output / "trajectories.jsonl").read_text().splitlines()
            ]
            episodes = [row for row in records if row["event_type"] == "episode"]
            assert len(episodes) == len(args.runs)
            assert len({row["seed_family"] for row in episodes}) >= 10
        else:
            expected = {
                "hash": "prompt wording, private view or hashes differ",
                "completion": "canned action differs from the private-view teacher",
                "missing": "incomplete player/host decision coverage",
                "heldout": "held-out wording is evaluation only",
            }[case]
            assert result.returncode and expected in result.stderr, result.stderr
        print(case, "PASS", flush=True)
