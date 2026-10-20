"""Complete published games through production bridges, including private notes."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TextIO, cast

ROOT = Path(__file__).resolve().parents[1]
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
WORDINGS = TRAIN + ["heldout-briefing", "heldout-reference"]


def play(binary, variant, wording, seed, language, prompt_seed=0, original=False):
    error_log = tempfile.TemporaryFile(mode="w+")
    process = subprocess.Popen(
        [
            str(binary),
            str(ROOT / "coworld_manifest_template.json"),
            variant,
            *(["--language"] if language else []),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=error_log,
        text=True,
    )
    stdin = cast(TextIO, process.stdin)
    stdout = cast(TextIO, process.stdout)

    def request(payload):
        stdin.write(json.dumps(payload) + "\n")
        stdin.flush()
        line = stdout.readline()
        assert line, process.poll()
        return json.loads(line)

    rows, systems = [], {}
    try:
        observation = request(
            {
                "kind": "reset",
                "players": 4,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "evaluation",
            }
        )
        while observation["kind"] == "decision":
            system, user = (message["content"] for message in observation["messages"])
            if original:
                system = system.replace(
                    "every word costs a tick of tide.",
                    "every transmission costs an extra tick of tide.",
                )
            seat = observation["seat"]
            view = observation["semantic_view"]
            if not original:
                metadata = view.pop("prompt_template")
                assert metadata["bank"] == "lighthouse-rules-v2"
                assert metadata["variant"] == (
                    TRAIN[prompt_seed % 5] if wording == "mixed" else wording
                )
                assert (
                    metadata["system_sha256"]
                    == hashlib.sha256(system.encode()).hexdigest()
                )
                assert (
                    metadata["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
                )
            view.pop("system")
            assert "players" not in view and "seed" not in view
            if seat in systems:
                assert systems[seat] == system
            systems[seat] = system
            encoding = request({"kind": "encode"})
            assert len(encoding["values"]) == 219
            assert len(encoding["actions"]) == 2
            action = json.loads(request({"kind": "teacher"})["response"])
            if language:
                action["notes"] = f"Private mémoire for seat {seat}"
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(action),
                }
            )
            assert result["kind"] == "accepted" and result["action"] == action, (
                variant,
                wording,
                language,
                seat,
                action,
                result["action"],
            )
            rows.append((view, user, encoding, result["action"]))
            observation = result["observation"]
        assert observation["kind"] == "terminal" and rows and len(rows) <= 500
        assert set(observation["scores"]) == {str(seat) for seat in range(4)}
        return rows, observation, systems
    finally:
        stdin.close()
        stdout.close()
        code = process.wait(timeout=10)
        error_log.seek(0)
        diagnostics = error_log.read() if code != 0 else ""
        error_log.close()
        assert code == 0, diagnostics


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    for wording, split in (
        (wording, split)
        for wording in WORDINGS[-2:]
        for split in (None, "train", "typo")
    ):
        rejected = subprocess.run(
            [
                str(binary),
                str(ROOT / "coworld_manifest_template.json"),
                "standard",
                "--language",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "players": 4,
                    "seed": 7,
                    "promptVariant": wording,
                    **({"split": split} if split is not None else {}),
                }
            )
            + "\n",
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert rejected.returncode != 0 and "held-out" in rejected.stderr
    count = 0
    for variant in ("standard", "spring-tide"):
        for language in (False, True):
            for seed in ("wording-1",):
                reference = play(binary, variant, "canonical", seed, language)
                count += 1
                if len(sys.argv) == 3 and not language:
                    assert reference == play(
                        Path(sys.argv[2]).resolve(),
                        variant,
                        "canonical",
                        seed,
                        language,
                        original=True,
                    )
                for wording in WORDINGS[1:]:
                    actual = play(binary, variant, wording, seed, language)
                    assert actual[:2] == reference[:2]
                    assert actual[2] != reference[2]
                    assert (
                        next(iter(actual[2].values())).split("OUTPUT FORMAT:", 1)[1]
                        == next(iter(reference[2].values())).split("OUTPUT FORMAT:", 1)[
                            1
                        ]
                    )
                    count += 1
                for prompt_seed in (4,):
                    actual = play(binary, variant, "mixed", seed, language, prompt_seed)
                    assert actual[:2] == reference[:2]
                    count += 1
    print(count, "complete games preserve private views, notes, actions and outcomes")
