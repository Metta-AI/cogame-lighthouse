"""One native Lighthouse game with Jev, prompt, and scripted player processes."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar


class ModelStub(BaseHTTPRequestHandler):
    calls: ClassVar[list[tuple[str, str]]] = []

    def do_POST(self) -> None:
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        slot = self.headers["X-Coworld-Player-Slot"]
        self.calls.append((self.path, slot))
        if self.path == "/v1/systemone":
            choices = len(request["questions"]["action"]["criteria"])
            selected = 1 if choices > 1 else 0
            probabilities = {
                str(index): float(index == selected) for index in range(choices)
            }
            payload = {
                "answers": {
                    "action": {"type": "choice", "probabilities": probabilities}
                }
            }
        else:
            assert self.path.startswith("/model/") and self.path.endswith("/invoke")
            payload = {
                "content": [{"type": "text", "text": '{"move":"WAIT","notes":""}'}]
            }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args: object) -> None:
        pass


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main() -> None:
    game_bin, player_bin = map(Path, sys.argv[1:3])
    game_port = free_port()
    stub = ThreadingHTTPServer(("127.0.0.1", 0), ModelStub)
    stub_url = f"http://127.0.0.1:{stub.server_port}"
    thread = threading.Thread(target=stub.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="lighthouse-mixed-") as temp:
        work = Path(temp)
        config = {
            "seed": 7,
            "maxTicks": 6,
            "turnDelayMs": 0,
            "decisionTimeoutSeconds": 5,
            "player_connect_timeout_seconds": 15,
            "episodeTimeoutSeconds": 120,
            "players": [{"name": f"P{seat}"} for seat in range(4)],
            "tokens": [f"t{seat}" for seat in range(4)],
        }
        (work / "config.json").write_text(json.dumps(config))
        game_env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "AWS_BEARER_TOKEN_BEDROCK",
        ):
            game_env.pop(key, None)
        game_env.update(
            {
                "COGAME_HOST": "127.0.0.1",
                "COGAME_PORT": str(game_port),
                "COGAME_CONFIG_URI": (work / "config.json").as_uri(),
                "COGAME_RESULTS_URI": (work / "results.json").as_uri(),
                "COGAME_SAVE_REPLAY_URI": (work / "replay.json").as_uri(),
            }
        )
        processes = []
        logs = []
        try:
            game_log = (work / "game.log").open("w+")
            logs.append(game_log)
            game = subprocess.Popen(
                [str(game_bin)], env=game_env, stdout=game_log, stderr=subprocess.STDOUT
            )
            processes.append(game)
            for _ in range(100):
                if game.poll() is not None:
                    raise RuntimeError("game exited before healthz")
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    ready = probe.connect_ex(("127.0.0.1", game_port)) == 0
                if ready:
                    urllib.request.urlopen(
                        f"http://127.0.0.1:{game_port}/healthz", timeout=0.2
                    )
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("game healthz did not start")
            for seat in range(4):
                env = game_env.copy()
                env["COWORLD_PLAYER_WS_URL"] = (
                    f"ws://127.0.0.1:{game_port}/player?slot={seat}&token=t{seat}"
                )
                if seat < 2:
                    env["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"] = stub_url
                if seat == 0:
                    env["LIGHTHOUSE_JEV"] = "1"
                    argv = [
                        sys.executable,
                        str(Path(__file__).parents[2] / "players/ordinary/player.py"),
                    ]
                else:
                    if seat >= 2:
                        env["PLAYER_SCRIPTED"] = "1"
                    argv = [str(player_bin)]
                handle = (work / f"player-{seat}.log").open("w+")
                logs.append(handle)
                processes.append(
                    subprocess.Popen(
                        argv, env=env, stdout=handle, stderr=subprocess.STDOUT
                    )
                )
            assert game.wait(timeout=60) == 0
            for player in processes[1:]:
                assert player.wait(timeout=10) == 0
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            assert results["ticks"] == 6 and replay["events"]
            game_text = (work / "game.log").read_text()
            assert "using scripted fallback" not in game_text
            jev = [call for call in ModelStub.calls if call[0] == "/v1/systemone"]
            prompt = [call for call in ModelStub.calls if call[0].startswith("/model/")]
            assert len(jev) == 6 and all(slot == "0" for _, slot in jev)
            assert len(prompt) == 6 and all(slot == "1" for _, slot in prompt)
            print(
                "mixed episode: 6 Jev, 6 prompt, 12 scripted decisions; zero game fallback"
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for handle in logs:
                handle.close()
            stub.shutdown()


if __name__ == "__main__":
    main()
