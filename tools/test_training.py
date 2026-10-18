"""Play both certified mazes through full exports and numeric training."""

import hashlib
import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TextIO, cast


ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
BRIDGE = Path(sys.argv[2]).resolve()
VERIFIER = Path(sys.argv[3]).resolve()
MANIFEST = ROOT / "coworld_manifest_template.json"

with tempfile.TemporaryDirectory() as directory:
    for variant in ("standard", "spring-tide"):
        reference = None
        for wording in ("canonical", "plain", "numbered", "questions", "reordered"):
            output = Path(directory) / variant / wording
            subprocess.run(
                [str(EXPORTER), str(output), "10", variant, wording, "0"],
                cwd=ROOT,
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            assert manifest["review_required"] and len(manifest["runs"]) == 10
            records = [
                json.loads(line)
                for line in (output / "trajectories.jsonl").read_text().splitlines()
            ]
            families = {
                row["seed_family"] for row in records if row["event_type"] == "episode"
            }
            assert families == {f"lighthouse-{seed}" for seed in range(1, 11)}
            comparable = []
            for run in manifest["runs"]:
                assert 0 < run["turns"] <= 45 and run["reason"] in (
                    "complete",
                    "timeup",
                )
                source = output / run["trajectory"]
                assert source.stat().st_mode & 0o777 == 0o600
                subprocess.run(
                    [str(VERIFIER), str(output / run["replay"])], cwd=ROOT, check=True
                )
            for row in records:
                if row["event_type"] == "episode":
                    comparable.append(row["outcome"])
                    continue
                (attempt,) = row["attempts"]
                system, user = (part["content"] for part in attempt["prompt"])
                assert "OUTPUT FORMAT" in system and "Tick " in user
                action = row["executed_action"]
                assert action == attempt["parsed_action"]
                assert set(action) in (
                    {"transmit", "message", "notes"},
                    {"move", "notes"},
                )
                metadata = row["observation"]["prompt_template"]
                assert (
                    metadata["variant"] == wording
                    and metadata["bank"] == "lighthouse-rules-v1"
                )
                for role, text in (("system", system), ("user", user)):
                    assert (
                        metadata[role + "_sha256"]
                        == hashlib.sha256(text.encode()).hexdigest()
                    )
                assert (
                    attempt["request"] is None and attempt["platform_call_id"] is None
                )
                comparable.append((row["observation"]["view"], user, action))
            if reference is None:
                reference = comparable
            else:
                assert comparable == reference
            print(variant, wording, "ten source/replay games PASS", flush=True)
        for wording in ("heldout-briefing", "heldout-reference"):
            output = Path(directory) / variant / wording
            rejected = subprocess.run(
                [str(EXPORTER), str(output), "10", variant, wording, "0"],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            assert (
                rejected.returncode
                and "held-out wording is evaluation only" in rejected.stderr
            )
            assert not output.exists()

        for teacher in (True, False):
            process = subprocess.Popen(
                [str(BRIDGE), str(MANIFEST), variant],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd="/tmp",
            )
            stdin = cast(TextIO, process.stdin)
            stdout = cast(TextIO, process.stdout)
            rng = random.Random(13)

            def request(payload: dict) -> dict:
                stdin.write(json.dumps(payload) + "\n")
                stdin.flush()
                return json.loads(stdout.readline())

            try:
                observation = request(
                    {
                        "kind": "reset",
                        "players": 4,
                        "seed": f"lighthouse-{variant}-{teacher}",
                    }
                )
                decisions = 0
                while observation["kind"] == "decision":
                    assert observation["decision_id"] == decisions
                    assert "OUTPUT FORMAT" in observation["semantic_view"]["system"]
                    encoded = request({"kind": "encode"})
                    assert len(encoded["values"]) == 219
                    assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                    action = (
                        json.loads(request({"kind": "teacher"})["response"])
                        if teacher
                        else rng.choice(encoded["actions"])
                    )
                    accepted = request(
                        {
                            "kind": "step",
                            "decision_id": decisions,
                            "response": json.dumps(action),
                        }
                    )
                    assert accepted["kind"] == "accepted"
                    observation = accepted["observation"]
                    decisions += 1
                    assert decisions <= 220
                assert set(observation["scores"]) == {"0", "1", "2", "3"}
                assert set(observation["utilities"]) == set(observation["scores"])
                assert all(
                    0 <= value <= 1 for value in observation["utilities"].values()
                )
                print(variant, "teacher" if teacher else "random", decisions)
            finally:
                stdin.close()
                stdout.close()
                assert process.wait(timeout=5) == 0
