"""Complete published Lighthouse games with real players, HTTP, and private evidence."""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "players/ordinary"))
from policy import prompts  # noqa: E402
from prompt_selection import PromptSelection  # noqa: E402


class Fixture(ThreadingHTTPServer):
    requests: list


class Handler(BaseHTTPRequestHandler):
    server: Fixture

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        seat = int(self.headers["X-Coworld-Player-Slot"])
        action = (
            {"transmit": True, "message": "Hold position café", "notes": "private-0"}
            if seat == 0
            else {"move": "NORTH", "notes": f"private-{seat}"}
        )
        response = json.dumps(
            {"content": [{"type": "text", "text": json.dumps(action)}]}
        ).encode()
        self.server.requests.append((seat, body, response.decode()))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("verifier", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--variant", choices=("standard", "spring-tide"), default="standard"
    )
    parser.add_argument("--wording", default="canonical")
    parser.add_argument(
        "--roster", choices=("native", "ordinary", "mixed"), default="native"
    )
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    config = next(
        v["game_config"] for v in manifest["variants"] if v["id"] == args.variant
    )
    config.update(
        seed=7,
        promptVariant=args.wording,
        promptSeed=3,
        tokens=[f"t{i}" for i in range(4)],
    )
    (output / "config.json").write_text(json.dumps(config))
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    fixture = Fixture(("127.0.0.1", 0), Handler)
    fixture.requests = []
    thread = Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "LIGHTHOUSE_CAPTURE_DIR": str(output / "private"),
        "LIGHTHOUSE_CAPTURE_TRAINING": "1",
        "LIGHTHOUSE_SOURCE_REVISION": revision,
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
        "COWORLD_LLM_MODEL": "fixture/validation",
        "PLAYER_PROMPT": "Help the team escape.",
        "PLAYER_SCRIPTED": "",
    }
    processes, logs = [], []
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        processes.append(
            subprocess.Popen([args.game], cwd=ROOT, env=env, stdout=log, stderr=log)
        )
        for _ in range(400):
            assert processes[0].poll() is None, (output / "game.log").read_text()
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.025)
        else:
            raise AssertionError("game listener did not start")
        ordinary = (
            set(range(4))
            if args.roster == "ordinary"
            else ({0, 2} if args.roster == "mixed" else set())
        )
        for seat in range(4):
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            player_env = {
                **env,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                "COWORLD_PLAYER_ARTIFACT_UPLOAD_URL": (
                    output / f"policy_artifact_{seat}.zip"
                ).as_uri(),
            }
            command = (
                [sys.executable, str(ROOT / "players/ordinary/player.py")]
                if seat in ordinary
                else [str(args.player)]
            )
            processes.append(
                subprocess.Popen(
                    command, cwd=ROOT, env=player_env, stdout=log, stderr=log
                )
            )
        for process in processes:
            assert process.wait(timeout=500) == 0, output
        result = json.loads((output / "results.json").read_text())
        assert (
            result["reason"] in ("complete", "timeup")
            and 0 < result["ticks"] <= config["maxTicks"]
        )
        trace = output / "private/host.jsonl"
        host = [json.loads(line) for line in trace.read_text().splitlines()]
        assert trace.stat().st_mode & 0o777 == 0o600
        assert host[0]["source_revision"] == revision and not host[0]["source_dirty"]
        assert host[-1]["result"] == result
        selection = PromptSelection.model_validate(host[0]["prompt_selection"])
        assert selection.selection == args.wording
        views = {
            (e["tick"], e["seat"]): e["view"]
            for e in host
            if e["event_type"] == "observation"
        }
        resolved = {
            (e["tick"], e["seat"]): e
            for e in host
            if e["event_type"] == "decision_resolved"
        }
        assert resolved.keys() == views.keys() and all(
            e["received"] for e in resolved.values()
        )
        replay = json.loads((output / "replay.json").read_text())
        assert [e["event"] for e in host if e["event_type"] == "action_applied"] == [
            e for e in replay["events"] if e["kind"] != "start"
        ]
        wire = list(fixture.requests)
        for seat in range(4):
            expected_ticks = {tick for tick, slot in views if slot == seat}
            if seat in ordinary:
                with zipfile.ZipFile(output / f"policy_artifact_{seat}.zip") as archive:
                    trajectory = json.loads(archive.read("trajectory.json"))
                assert (
                    trajectory["complete"] and trajectory["scores"] == result["scores"]
                )
                assert {
                    row["tick"] for row in trajectory["decisions"]
                } == expected_ticks
                for row in trajectory["decisions"]:
                    system, user = prompts(
                        selection, views[row["tick"], seat], env["PLAYER_PROMPT"]
                    )
                    assert row["prompt_template"] == selection.metadata(system, user)
                    assert row["prompt"] == [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ]
                    action = json.loads(row["completion"][0]["content"])
                    if seat == 0 and not action["transmit"]:
                        action["message"] = ""
                    assert action == resolved[row["tick"], seat]["action"]
            else:
                path = output / f"private/player-{seat}.jsonl"
                events = [json.loads(line) for line in path.read_text().splitlines()]
                assert path.stat().st_mode & 0o777 == 0o600
                assert (
                    events[0]["source_revision"] == revision
                    and not events[0]["source_dirty"]
                )
                assert events[-1]["event_type"] == "player_completed"
                requests = {
                    e["tick"]: e for e in events if e["event_type"] == "request_sent"
                }
                responses = {
                    e["tick"]: e
                    for e in events
                    if e["event_type"] == "response_received"
                }
                parsed = {
                    e["tick"]: e for e in events if e["event_type"] == "response_parsed"
                }
                assert (
                    requests.keys()
                    == responses.keys()
                    == parsed.keys()
                    == expected_ticks
                )
                for tick, request in requests.items():
                    wire.remove(
                        (
                            seat,
                            request["request_body"],
                            responses[tick]["response_body"],
                        )
                    )
                    assert request["view"] == views[tick, seat]
                    body = json.loads(request["request_body"])
                    assert request["prompt_template"] == selection.metadata(
                        body["system"], body["messages"][0]["content"]
                    )
                    assert parsed[tick]["action"] == resolved[tick, seat]["action"]
                acknowledgements = {
                    e["tick"]
                    for e in events
                    if e["event_type"] == "decision_result" and e["accepted"]
                }
                assert acknowledgements == expected_ticks
        assert not wire
        subprocess.run([args.verifier, output / "replay.json"], cwd=ROOT, check=True)
        print(
            args.variant,
            args.wording,
            args.roster,
            len(resolved),
            "complete native capture PASS",
            flush=True,
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        for log in logs:
            log.close()
        fixture.shutdown()
        fixture.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
