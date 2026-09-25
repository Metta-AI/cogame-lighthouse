"""Load a Metta trained Lighthouse adapter from a packaged local base."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path


class TransformersGenerator:
    def __init__(self, adapter: Path) -> None:
        import torch
        from peft import PeftModel
        from transformers import AutoModelForCausalLM, AutoTokenizer

        manifest = json.loads((adapter / "training_manifest.json").read_text())
        base = Path(os.environ.get("LIGHTHOUSE_BASE_MODEL_DIR", manifest["model"]))
        if not base.is_dir():
            raise ValueError("player requires a packaged local base model")
        digest = hashlib.sha256()
        for path in sorted(path for path in base.rglob("*") if path.is_file()):
            digest.update(str(path.relative_to(base)).encode())
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        if manifest["revision"] != f"local-sha256:{digest.hexdigest()}":
            raise ValueError("base model differs from the training manifest")
        self.tokenizer = AutoTokenizer.from_pretrained(base)
        network = AutoModelForCausalLM.from_pretrained(base, device_map="cpu")
        self.network = PeftModel.from_pretrained(network, adapter)
        self.network.eval()
        self.torch = torch
        self.max_length = manifest["max_length"]

    def __call__(self, messages: list[dict[str, str]]) -> str:
        from transformers import MaxTimeCriteria, StoppingCriteriaList

        inputs = self.tokenizer.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            enable_thinking=False,
            return_tensors="pt",
            return_dict=True,
        ).to(self.network.device)
        length = inputs["input_ids"].shape[-1]
        if length > self.max_length:
            raise ValueError(
                f"player prompt has {length} tokens, above {self.max_length}"
            )
        with self.torch.inference_mode():
            generated = self.network.generate(
                **inputs,
                do_sample=False,
                max_new_tokens=256,
                pad_token_id=self.tokenizer.eos_token_id,
                stopping_criteria=StoppingCriteriaList([MaxTimeCriteria(max_time=30)]),
            )
        return self.tokenizer.decode(generated[0, length:], skip_special_tokens=True)
