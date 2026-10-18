"""Export review-required candidates joined to complete native Lighthouse games."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import zipfile
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict

from policy import prompts
from prompt_selection import PromptSelection


class Message(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class Decision(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    decision_id: int
    tick: int
    source: Literal["canned", "trained"]
    guidance: str
    prompt_template: dict
    prompt: list[Message]
    completion: list[Message]


class Trajectory(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    schema_version: Literal[2]
    game: Literal["lighthouse"]
    slot: int
    backend: Literal["canned", "trained"]
    source_revision: str
    complete: Literal[True]
    reason: Literal["complete", "timeup"]
    scores: list[float]
    decisions: list[Decision]


def write_private(path: Path, content: str) -> None:
    with os.fdopen(
        os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w"
    ) as stream:
        stream.write(content)


def export(runs: list[Path], output: Path, revision: str, verifier: Path) -> None:
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise ValueError("source revision must be a full commit")
    seeds = {json.loads((run / "config.json").read_text())["seed"] for run in runs}
    if len(seeds) < 10:
        raise ValueError("at least ten complete seed families are required")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    write_private(output / "trajectories.jsonl", "")
    episodes: set[str] = set()
    for run in runs:
        config = json.loads((run / "config.json").read_text())
        result = json.loads((run / "results.json").read_text())
        replay = json.loads((run / "replay.json").read_text())
        events = [
            json.loads(line)
            for line in (run / "private/host.jsonl").read_text().splitlines()
        ]
        started, completed = events[0], events[-1]
        if (
            started["event_type"] != "host_started"
            or started["source_revision"] != revision
            or started["source_dirty"]
            or started["config"] != config
            or completed["event_type"] != "host_completed"
            or completed["result"] != result
            or result["reason"] not in ("complete", "timeup")
            or replay["results"] != result
            or replay["seed"] != config["seed"]
        ):
            raise ValueError("incomplete or unqualified host capture")
        selection = PromptSelection.model_validate(started["prompt_selection"])
        if selection.variant.startswith("heldout-"):
            raise ValueError("held-out wording is evaluation only")
        if [e["event"] for e in events if e["event_type"] == "action_applied"] != [
            e for e in replay["events"] if e["kind"] != "start"
        ]:
            raise ValueError("host application log differs from replay")
        subprocess.run([verifier, run / "replay.json"], check=True)
        views, resolved, frames = {}, {}, {}
        for event in events:
            if event["event_type"] in ("observation", "decision_resolved"):
                key = (event["tick"], event["seat"])
                target = views if event["event_type"] == "observation" else resolved
                if key in target:
                    raise ValueError("duplicate host decision")
                target[key] = event
            elif event["event_type"] == "player_frame":
                frame = json.loads(event["frame"])
                if frame["type"] == "decision":
                    key = (frame["tick"], event["seat"])
                    if key in frames or frame["tick"] != event["pending_tick"]:
                        raise ValueError("duplicate or stale player decision")
                    frames[key] = frame
        if (
            not views
            or views.keys() != resolved.keys()
            or views.keys() != frames.keys()
        ):
            raise ValueError("incomplete player/host decision coverage")
        family = f"lighthouse-{config['seed']}"
        episode = f"{family}-tide-{config['tideDelay']}-{config['tidePeriod']}-{selection.variant}-{selection.seed}"
        if episode in episodes:
            raise ValueError("duplicate episode")
        episodes.add(episode)
        records, captured = [], set()
        for seat in range(4):
            with zipfile.ZipFile(run / f"policy_artifact_{seat}.zip") as archive:
                trajectory = Trajectory.model_validate_json(
                    archive.read("trajectory.json")
                )
            if (
                trajectory.slot != seat
                or trajectory.source_revision != revision
                or trajectory.scores != result["scores"]
                or trajectory.reason != result["reason"]
            ):
                raise ValueError("player artifact identity or outcome mismatch")
            for index, row in enumerate(trajectory.decisions):
                key = (row.tick, seat)
                if row.decision_id != index or key in captured:
                    raise ValueError("duplicate or noncontiguous player decisions")
                captured.add(key)
                view = views[key]["view"]
                system, user = prompts(selection, view, row.guidance)
                messages = [m.model_dump() for m in row.prompt]
                if (
                    messages
                    != [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ]
                    or row.prompt_template != selection.metadata(system, user)
                    or len(row.completion) != 1
                    or row.completion[0].role != "assistant"
                ):
                    raise ValueError("prompt wording, private view or hashes differ")
                response = row.completion[0].content
                action = json.loads(response)
                if (
                    frames[key]["action"] != action
                    or frames[key]["source"] != row.source
                ):
                    raise ValueError("player capture differs from received frame")
                if seat == 0 and not action["transmit"]:
                    action["message"] = ""
                if (
                    not resolved[key]["received"]
                    or resolved[key]["scripted"]
                    or action != resolved[key]["action"]
                ):
                    raise ValueError("player capture differs from resolved action")
                identity = str(len(records))
                attempt_id = identity + "-player"
                records.append(
                    {
                        "schema_version": "1",
                        "event_type": "decision",
                        "episode_id": episode,
                        "decision_id": identity,
                        "decision_index": len(records),
                        "game": "lighthouse",
                        "game_version": "source-" + revision,
                        "source_revision": revision,
                        "seat": str(seat),
                        "visibility": "private",
                        "observation": {
                            "view": view,
                            "tick": row.tick,
                            "prompt_template": row.prompt_template,
                        },
                        "prompt": messages,
                        "attempts": [
                            {
                                "attempt_id": attempt_id,
                                "policy": trajectory.backend,
                                "origin": "teacher"
                                if row.source == "canned"
                                else "unknown",
                                "inference_mode": "text_action",
                                "prompt": messages,
                                "response": response,
                                "parsed_action": action,
                                "accepted": True,
                                "rejection_reason": None,
                                "request": None,
                                "platform_call_id": None,
                                "behavior_logprobs": None,
                            }
                        ],
                        "selected_attempt_id": attempt_id,
                        "executed_action": action,
                        "action_status": "accepted",
                        "fallback_origin": None,
                        "terminal": False,
                    }
                )
        if captured != set(views):
            raise ValueError("player artifacts do not cover every host decision")
        records.sort(key=lambda row: (row["observation"]["tick"], int(row["seat"])))
        for index, record in enumerate(records):
            record["decision_index"] = index
        records[-1]["terminal"] = True
        records.append(
            {
                "schema_version": "1",
                "event_type": "episode",
                "episode_id": episode,
                "seed_family": family,
                "game": "lighthouse",
                "game_version": "source-" + revision,
                "source_revision": revision,
                "status": "completed",
                "outcome": result,
                "participant_outcomes": {
                    str(seat): {"score": result["scores"][seat]} for seat in range(4)
                },
            }
        )
        with (output / "trajectories.jsonl").open("a") as stream:
            for record in records:
                stream.write(json.dumps(record) + "\n")
        write_private(output / (episode + ".replay.json"), json.dumps(replay))
    write_private(
        output / "manifest.json",
        json.dumps(
            {
                "schema_version": "1",
                "format": "coworld-private-candidates-v1",
                "review_required": True,
                "game": "lighthouse",
                "source_revision": revision,
                "episodes": sorted(episodes),
                "seed_families": len(seeds),
            },
            indent=2,
        )
        + "\n",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--replay-verifier", required=True, type=Path)
    args = parser.parse_args()
    export(args.runs, args.output, args.source_revision, args.replay_verifier)
