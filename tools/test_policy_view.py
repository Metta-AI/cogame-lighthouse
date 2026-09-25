"""Check Python ordinary-player baselines against the native rule oracle."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "players" / "ordinary"))
from policy import baseline

with TemporaryDirectory(prefix="lighthouse-policy-view-") as work:
    output = Path(work) / "oracle.json"
    subprocess.run(
        [
            "nim",
            "c",
            "-r",
            "--hints:off",
            "--warnings:off",
            "--path:src",
            f"--out:{Path(work) / 'policy-oracle'}",
            "tools/policy_oracle.nim",
            str(output),
        ],
        cwd=ROOT,
        check=True,
    )
    records = json.loads(output.read_text())
    assert len(records) >= 1000
    for index, row in enumerate(records):
        actual = baseline(row["view"])
        assert actual == row["action"], (index, actual, row["action"])
    print(f"{len(records)} private-view baseline actions matched the native oracle")
