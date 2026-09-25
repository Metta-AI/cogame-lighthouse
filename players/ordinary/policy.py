"""Player-side Lighthouse prompts and candidate actions from a private view."""

import json
import re
from collections import deque

DIRECTIONS = ("N", "E", "S", "W")
DELTAS = {"N": (0, -1), "E": (1, 0), "S": (0, 1), "W": (-1, 0)}


def prompts(view: dict, guidance: str) -> tuple[str, str]:
    system = (
        f"You are {view['alias']}, the {view['role']} in Lighthouse. "
        "The keeper sees the maze; runners see only their own 3x3 window. "
        "Collect all keys and reach the exit before the rising tide. "
        "A keeper transmission arrives next tick and doubles the tide clock "
        "advance for this tick. Runners cannot talk. Never infer hidden state "
        "beyond your private observation. Reply with one JSON action only."
    )
    shape = (
        '{"transmit": true, "message": "Alias N; Alias E", "notes": ""}'
        if view["role"] == "keeper"
        else '{"move": "N", "notes": ""}; move is N, S, E, W, or WAIT'
    )
    user = (
        "Private observation:\n"
        + json.dumps(view, ensure_ascii=False, sort_keys=True)
        + "\nOperator guidance:\n"
        + guidance
        + "\nReply with only "
        + shape
    )
    return system, user


def _order(text: str, alias: str) -> str | None:
    match = re.search(
        r"(?<![A-Za-z])" + re.escape(alias) + r"(?![A-Za-z])[\s:,.=\->]*([A-Za-z]+)",
        text,
        re.IGNORECASE,
    )
    if match is None:
        return None
    token = match.group(1).upper()
    return {
        "NORTH": "N",
        "UP": "N",
        "SOUTH": "S",
        "DOWN": "S",
        "EAST": "E",
        "RIGHT": "E",
        "WEST": "W",
        "LEFT": "W",
        "H": "WAIT",
        "HOLD": "WAIT",
        "STAY": "WAIT",
    }.get(token, token if token in (*DIRECTIONS, "WAIT") else None)


def _runner_baseline(view: dict) -> dict:
    window = view["window"]

    def open_direction(direction: str) -> bool:
        dx, dy = DELTAS[direction]
        return window[dy + 1][dx + 1] not in "#~"

    order = _order(view["inbox"], view["alias"])
    if order is None and 0 <= view["standingAge"] <= 3:
        order = _order(view["standing"], view["alias"])
    if order is not None:
        if order == "WAIT":
            return {"move": "WAIT", "notes": ""}
        index = DIRECTIONS.index(order)
        choices = (
            order,
            DIRECTIONS[(index + 1) % 4],
            DIRECTIONS[(index - 1) % 4],
            DIRECTIONS[(index + 2) % 4],
        )
    else:
        heading = "N"
        for entry in reversed(view["moveHistory"]):
            token = entry.split(" ", 1)[0]
            if token != "WAIT":
                heading = token
                break
        index = DIRECTIONS.index(heading)
        choices = (
            DIRECTIONS[(index - 1) % 4],
            heading,
            DIRECTIONS[(index + 1) % 4],
            DIRECTIONS[(index + 2) % 4],
        )
    return {
        "move": next((d for d in choices if open_direction(d)), "WAIT"),
        "notes": "",
    }


def _keeper_baseline(view: dict) -> dict:
    maze = view["maze"]
    width, height = len(maze[0]), len(maze)
    water_line = view["waterLine"]

    def open_tile(x: int, y: int) -> bool:
        return (
            0 <= x < width and 0 <= y < height and maze[y][x] != "#" and y < water_line
        )

    def field(target: list[int]) -> dict[tuple[int, int], int]:
        start = tuple(target)
        if not open_tile(*start):
            return {}
        distances = {start: 0}
        queue = deque([start])
        while queue:
            x, y = queue.popleft()
            for dx, dy in DELTAS.values():
                neighbor = (x + dx, y + dy)
                if open_tile(*neighbor) and neighbor not in distances:
                    distances[neighbor] = distances[(x, y)] + 1
                    queue.append(neighbor)
        return distances

    exit_field = field(view["exit"])
    key_fields = [field(key) for key in view["keysOnFloor"]]
    targets = [-1] * len(view["runners"])
    if view["keysCollected"] < view["keyCount"]:
        pairs = sorted(
            (distances[tuple(runner["position"])], index, key_index)
            for index, runner in enumerate(view["runners"])
            if runner["status"] == "active"
            for key_index, distances in enumerate(key_fields)
            if tuple(runner["position"]) in distances
        )
        used_runners, used_keys = set(), set()
        for _, runner, key in pairs:
            if runner not in used_runners and key not in used_keys:
                targets[runner] = key
                used_runners.add(runner)
                used_keys.add(key)

    def first_step(distances: dict[tuple[int, int], int], tile: tuple[int, int]) -> str:
        current = distances.get(tile, -1)
        if current <= 0:
            return "WAIT"
        for direction, (dx, dy) in DELTAS.items():
            neighbor = (tile[0] + dx, tile[1] + dy)
            if distances.get(neighbor) == current - 1:
                return direction
        return "WAIT"

    steps = []
    for index, runner in enumerate(view["runners"]):
        if runner["status"] != "active":
            steps.append("WAIT")
            continue
        distances = exit_field if targets[index] < 0 else key_fields[targets[index]]
        position = tuple(runner["position"])
        now = first_step(distances, position)
        if now == "WAIT":
            steps.append("WAIT")
            continue
        dx, dy = DELTAS[now]
        steps.append(first_step(distances, (position[0] + dx, position[1] + dy)))

    message = "; ".join(
        f"{runner['alias']} {step if step != 'WAIT' else 'hold'}"
        for runner, step in zip(view["runners"], steps)
        if runner["status"] == "active"
    )[:160]
    messages = view["messages"]
    just_spoke = bool(messages and messages[-1]["tick"] == view["tick"] - 1)
    repeat = bool(messages and messages[-1]["text"] == message)
    transmit = view["tick"] % 2 == 0
    if not transmit and messages:
        last = messages[-1]["text"]
        rose = view["lastMessageClock"] < 0 or (
            max(0, (view["clock"] - view["tideDelay"]) // view["tidePeriod"])
            != max(
                0, (view["lastMessageClock"] - view["tideDelay"]) // view["tidePeriod"]
            )
        )
        for runner, step in zip(view["runners"], steps):
            if runner["status"] != "active":
                continue
            told = _order(last, runner["alias"])
            if (
                told is None
                or (runner["blocked"] and told != step)
                or (rose and runner["position"][1] + 2 >= water_line)
            ):
                transmit = True
                break
    if view["keyJustCollected"]:
        transmit = True
    transmit = bool(
        message
        and not just_spoke
        and (view["tick"] % 2 == 0 or (not repeat and transmit))
    )
    return {"transmit": transmit, "message": message, "notes": ""}


def baseline(view: dict) -> dict:
    return (
        _keeper_baseline(view) if view["role"] == "keeper" else _runner_baseline(view)
    )


def candidates(view: dict) -> list[dict]:
    first = baseline(view)
    if view["role"] == "keeper":
        actions = [first]
        speak = {"transmit": True, "message": first["message"], "notes": ""}
        quiet = {"transmit": False, "message": "", "notes": ""}
        for action in (speak, quiet):
            if action not in actions and (not action["transmit"] or action["message"]):
                actions.append(action)
        return actions
    actions = [first]
    for direction, (dx, dy) in DELTAS.items():
        if view["window"][dy + 1][dx + 1] not in "#~":
            action = {"move": direction, "notes": ""}
            if action not in actions:
                actions.append(action)
    if {"move": "WAIT", "notes": ""} not in actions:
        actions.append({"move": "WAIT", "notes": ""})
    return actions
