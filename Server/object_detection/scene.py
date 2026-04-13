import logging
import os

import torch
from PIL import Image
from transformers import AutoProcessor, AutoModelForCausalLM

logger = logging.getLogger("object_detection.scene")


class SceneDescriber:
    def __init__(self) -> None:
        model_name = os.getenv("SCENE_MODEL", "microsoft/Florence-2-base")
        device = "cuda" if torch.cuda.is_available() else "cpu"

        logger.info("Loading scene model=%s device=%s", model_name, device)
        self.processor = AutoProcessor.from_pretrained(model_name, trust_remote_code=True)
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name,
            trust_remote_code=True,
            torch_dtype=torch.float16 if device == "cuda" else torch.float32,
        ).to(device)
        self.device = device

        if os.getenv("SCENE_WARMUP", "1") == "1":
            try:
                blank = Image.new("RGB", (64, 64))
                self.describe(blank)
                logger.info("Scene describer warmup complete")
            except Exception as e:
                logger.warning("Scene warmup failed (continuing): %s", e)

    def describe(self, image: Image.Image) -> str:
        prompt = "<MORE_DETAILED_CAPTION>"
        inputs = self.processor(text=prompt, images=image, return_tensors="pt")
        inputs = {k: v.to(self.device) for k, v in inputs.items()}

        with torch.no_grad():
            generated = self.model.generate(
                **inputs,
                max_new_tokens=80,
                do_sample=False,
                num_beams=1,
            )

        result = self.processor.batch_decode(generated, skip_special_tokens=False)[0]
        parsed = self.processor.post_process_generation(result, task=prompt, image_size=image.size)
        caption = parsed.get(prompt, "").strip()
        return caption