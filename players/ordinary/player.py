"""Lighthouse decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import baseline, prompts
from prompt_selection import BANK, PromptSelection


def choose(turn: dict, generator, selection: PromptSelection) -> tuple[dict, str]:
    view = turn["view"]
    system, user = prompts(selection, view, os.environ.get("PLAYER_PROMPT", ""))
    if generator:
        completion = generator(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ]
        )
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Lighthouse decision must be a JSON object")
        return action, "trained"
    return baseline(view), "canned"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("LIGHTHOUSE_ADAPTER_DIR")
    generator = None
    if adapter:
        from pathlib import Path

        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "canned"
    artifact = (
        Capture(slot, backend)
        if os.environ.get("LIGHTHOUSE_CAPTURE_TRAINING") == "1"
        else None
    )
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    pending: dict[int, tuple[dict, dict, str]] = {}
    episode_selection: PromptSelection | None = None
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Lighthouse closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            selection = PromptSelection.model_validate(frame["prompt_configuration"])
            if selection.bank != BANK.version:
                raise ValueError("game and player prompt banks differ")
            if episode_selection is not None and selection != episode_selection:
                raise ValueError("prompt selection changed during episode")
            episode_selection = selection
            action, source = choose(frame, generator, selection)
            pending[frame["tick"]] = (frame, action, source)
            socket.send(
                json.dumps(
                    {
                        "type": "decision",
                        "tick": frame["tick"],
                        "source": source,
                        "action": action,
                    }
                )
            )
        elif kind == "decision_result":
            turn, action, source = pending.pop(frame["tick"])
            if not frame["accepted"]:
                raise RuntimeError(f"Lighthouse rejected tick {frame['tick']}")
            if artifact:
                system, user = prompts(
                    PromptSelection.model_validate(turn["prompt_configuration"]),
                    turn["view"],
                    os.environ.get("PLAYER_PROMPT", ""),
                )
                artifact.record(
                    system,
                    user,
                    action,
                    source,
                    frame["tick"],
                    PromptSelection.model_validate(turn["prompt_configuration"]),
                )
        elif kind == "final":
            if pending:
                raise RuntimeError("Lighthouse ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"], frame["reason"])
            break
    socket.close()
    print(
        f"Lighthouse ordinary player finished: slot={slot} backend={backend}",
        flush=True,
    )


if __name__ == "__main__":
    main()
