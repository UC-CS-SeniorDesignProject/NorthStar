import logging
import os
from pathlib import Path

logger = logging.getLogger("rag")

LLM_ENABLED = os.getenv("LLM_ENABLED", "1") == "1"
LLM_MODEL_SMALL = os.getenv("LLM_MODEL_SMALL", "Qwen/Qwen2.5-0.5B-Instruct")
LLM_MODEL_MEDIUM = os.getenv("LLM_MODEL_MEDIUM", "Qwen/Qwen2.5-1.5B-Instruct")

_llm_pipelines = {}


def _get_llm(model_name: str):
    if model_name in _llm_pipelines:
        return _llm_pipelines[model_name]

    try:
        from transformers import pipeline as tf_pipeline
        import torch

        device = 0 if torch.cuda.is_available() else -1
        logger.info("Loading LLM model=%s device=%s", model_name, device)
        pipe = tf_pipeline(
            "text-generation",
            model=model_name,
            device=device,
            torch_dtype=torch.float16 if device >= 0 else torch.float32,
        )
        _llm_pipelines[model_name] = pipe
        logger.info("LLM %s loaded successfully", model_name)
        return pipe
    except Exception as e:
        logger.warning("Failed to load LLM %s: %s", model_name, e)
        _llm_pipelines[model_name] = None
        return None


def _choose_llm_model(responses: list[str], scene_caption: str) -> str:
    total_items = len(responses)
    has_scene = bool(scene_caption)
    has_urgent = any(r.startswith("URGENT") for r in responses)

    if total_items >= 3 or (has_scene and has_urgent) or (has_scene and total_items >= 2):
        return LLM_MODEL_MEDIUM

    return LLM_MODEL_SMALL


def _llm_combine(responses: list[str], user_profile: str, scene_caption: str = "") -> str | None:
    if not LLM_ENABLED:
        return None

    model_name = _choose_llm_model(responses, scene_caption)
    pipe = _get_llm(model_name)
    if pipe is None:
        return None

    bullet_list = "\n".join(f"- {r}" for r in responses)
    scene_context = f"\nScene description: {scene_caption}" if scene_caption else ""

    messages = [
        {"role": "system", "content": (
            "You are a voice assistant guiding a visually impaired person in real-time. "
            "Combine the alerts and scene context into ONE short, natural spoken sentence (under 35 words). "
            "Include specific distances and directions. Be direct and urgent where needed. "
            "Speak as if talking to the person. No bullet points. No filler."
        )},
        {"role": "user", "content": (
            f"User preferences: {user_profile}\n\n"
            f"Alerts:\n{bullet_list}{scene_context}"
        )},
    ]

    try:
        result = pipe(messages, max_new_tokens=80, do_sample=False)
        text = result[0]["generated_text"][-1]["content"].strip()
        if text:
            return text
    except Exception as e:
        logger.debug("LLM generation failed (%s), using template fallback: %s", model_name, e)

    return None


class RAGModule:
    def __init__(self, knowledge_path: Path, profile_dir: Path, top_k: int = 5):
        self.top_k = top_k
        self.profile_dir = profile_dir
        self.user_profile = ""

        self.object_responses = {}

        for line in knowledge_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or "—" not in line:
                continue

            obj, response = line.split("—", 1)
            self.object_responses[obj.strip().lower()] = response.strip()

        self.multi_word_objects = sorted(
            [key for key in self.object_responses.keys() if " " in key],
            key=len,
            reverse=True,
        )

        self.object_categories = {
            "stairs": "elevation_change",
            "stair": "elevation_change",
            "curb": "elevation_change",
            "ramp": "elevation_change",
            "step": "elevation_change",

            "person": "pedestrian",
            "people": "pedestrian",
            "crowd": "pedestrian",
            "child": "pedestrian",
            "pedestrian": "pedestrian",

            "dog": "animal",
            "cat": "animal",
            "bird": "animal",
            "animal": "animal",
            "horse": "animal",
            "cow": "animal",
            "sheep": "animal",
            "bear": "danger",

            "car": "vehicle",
            "vehicle": "vehicle",
            "bus": "vehicle",
            "truck": "vehicle",
            "motorcycle": "vehicle",
            "bicycle": "vehicle",
            "bike": "vehicle",
            "train": "vehicle",
            "subway": "vehicle",

            "chair": "furniture",
            "table": "furniture",
            "dining table": "furniture",
            "desk": "furniture",
            "sofa": "furniture",
            "couch": "furniture",
            "bed": "furniture",
            "cabinet": "furniture",
            "shelf": "furniture",
            "bench": "furniture",
            "counter": "furniture",
            "refrigerator": "furniture",

            "wet": "surface_hazard",
            "water": "surface_hazard",
            "spill": "surface_hazard",
            "ice": "surface_hazard",
            "snow": "surface_hazard",
            "glass": "surface_hazard",
            "knife": "sharp_hazard",
            "scissors": "sharp_hazard",
            "fork": "sharp_hazard",
            "fire": "danger",
            "smoke": "danger",
            "pothole": "danger",
            "skateboard": "danger",

            "door": "barrier",
            "doorway": "barrier",
            "glass door": "barrier",
            "wall": "barrier",
            "gate": "barrier",
            "fence": "barrier",
            "barrier": "barrier",
            "obstacle": "barrier",
            "pole": "barrier",
            "sign": "barrier",
            "box": "barrier",
            "package": "barrier",
            "bag": "barrier",
            "backpack": "barrier",
            "trash": "barrier",
            "branch": "barrier",
            "rock": "barrier",
            "ladder": "barrier",
            "tree": "barrier",
            "potted plant": "barrier",
            "fire hydrant": "barrier",
            "fire_hydrant": "barrier",
            "parking meter": "barrier",
            "parking_meter": "barrier",
            "bollard": "barrier",
            "cone": "barrier",
            "construction": "barrier",
            "spherical_roadblock": "barrier",
            "warning_column": "barrier",
            "waste_container": "barrier",
            "street_light": "barrier",
            "street light": "barrier",
            "crutch": "barrier",
            "suitcase": "barrier",
            "umbrella": "barrier",
            "handbag": "barrier",
            "surfboard": "barrier",

            "low light": "visibility",
            "bright light": "visibility",
            "darkness": "visibility",
            "dark": "visibility",

            "handrail": "support",
            "railing": "support",

            "platform": "transit_edge",
            "platform edge": "transit_edge",
            "crosswalk": "transit_control",
            "traffic light": "transit_control",
            "traffic_light": "transit_control",
            "stop sign": "transit_control",
            "stop_sign": "transit_control",
            "bus stop": "transit_control",
            "bus_stop": "transit_control",
            "train station": "transit_control",
            "subway platform": "transit_edge",
            "elevator": "transit_access",
            "escalator": "transit_access",

            "laptop": "neutral_object",
            "computer": "neutral_object",
            "keyboard": "neutral_object",
            "mouse": "neutral_object",
            "phone": "neutral_object",
            "tablet": "neutral_object",
            "remote": "neutral_object",
            "key": "neutral_object",
            "keys": "neutral_object",
            "wallet": "neutral_object",
            "book": "neutral_object",
            "notebook": "neutral_object",
            "pen": "neutral_object",
            "pencil": "neutral_object",
            "paper": "neutral_object",
            "cup": "neutral_object",
            "bottle": "neutral_object",
            "plate": "neutral_object",
            "fork": "neutral_object",
            "spoon": "neutral_object",
            "television": "neutral_object",
            "tv": "neutral_object",
            "monitor": "neutral_object",
            "screen": "neutral_object",
            "floor": "neutral_object",
            "ceiling": "neutral_object",
            "unknown": "neutral_object",
            "cell phone": "neutral_object",
            "cell_phone": "neutral_object",
            "clock": "neutral_object",
            "vase": "neutral_object",
            "teddy bear": "neutral_object",
            "teddy_bear": "neutral_object",
            "toothbrush": "neutral_object",
            "hair drier": "neutral_object",
            "hair_drier": "neutral_object",
            "tie": "neutral_object",
            "frisbee": "neutral_object",
            "kite": "neutral_object",
            "baseball bat": "neutral_object",
            "baseball_bat": "neutral_object",
            "tennis racket": "neutral_object",
            "tennis_racket": "neutral_object",
            "sports ball": "neutral_object",
            "sports_ball": "neutral_object",
            "skis": "neutral_object",
            "snowboard": "neutral_object",
            "apple": "neutral_object",
            "banana": "neutral_object",
            "sandwich": "neutral_object",
            "orange": "neutral_object",
            "broccoli": "neutral_object",
            "carrot": "neutral_object",
            "hot dog": "neutral_object",
            "hot_dog": "neutral_object",
            "pizza": "neutral_object",
            "donut": "neutral_object",
            "cake": "neutral_object",
            "bowl": "neutral_object",
            "oven": "neutral_object",
            "toaster": "neutral_object",
            "microwave": "neutral_object",
            "sink": "neutral_object",
            "toilet": "neutral_object",
            "airplane": "neutral_object",
            "boat": "neutral_object",
        }

        self.category_responses = {
            "elevation_change": "Elevation change ahead; step carefully.",
            "pedestrian": "People nearby; move slowly and stay aware of movement.",
            "animal": "Animals nearby; proceed calmly.",
            "vehicle": "Vehicles nearby; remain alert.",
            "furniture": "Large objects nearby; move carefully around them.",
            "surface_hazard": "Surface may be slippery or unsafe; step carefully.",
            "sharp_hazard": "Sharp object detected; handle carefully.",
            "danger": "Potential danger detected; proceed with extra caution.",
            "barrier": "Obstacle nearby; adjust your movement carefully.",
            "visibility": "Visibility is reduced; move slowly and carefully.",
            "support": "Support is nearby; use it if needed.",
            "transit_edge": "An edge or drop-off may be nearby; proceed carefully.",
            "transit_control": "A crossing or transit control is nearby; remain alert.",
            "transit_access": "Transit access point nearby; move carefully.",
            "neutral_object": "No immediate hazard detected; safe to move.",
        }

        self.priority_categories = {
            "elevation_change",
            "pedestrian",
            "animal",
            "vehicle",
            "surface_hazard",
            "sharp_hazard",
            "danger",
            "barrier",
            "visibility",
            "furniture",
            "support",
            "transit_edge",
            "transit_control",
            "transit_access",
        }

    def load_user_profile(self, profile_name: str):
        profile_path = self.profile_dir / f"{profile_name}.txt"
        if not profile_path.exists():
            raise FileNotFoundError(f"Profile '{profile_name}' not found")
        self.user_profile = profile_path.read_text(encoding="utf-8").strip()

    def normalize_text(self, text: str) -> str:
        cleaned = text.lower()
        for ch in [",", ".", ";", ":", "/", "\\", "|", "(", ")", "[", "]", "{", "}", "!", "?", "-", "_"]:
            cleaned = cleaned.replace(ch, " ")
        return " ".join(cleaned.split())

    def detect_multi_word_objects(self, text: str) -> tuple[list[str], str]:
        detected = []
        working_text = f" {text} "

        for phrase in self.multi_word_objects:
            padded_phrase = f" {phrase} "
            if padded_phrase in working_text:
                detected.append(phrase)
                working_text = working_text.replace(padded_phrase, " ")

        cleaned_remaining = " ".join(working_text.split())
        return detected, cleaned_remaining

    def tokenize_input(self, query: str) -> list[str]:
        normalized = self.normalize_text(query)

        multi_word_matches, remaining_text = self.detect_multi_word_objects(normalized)

        single_tokens = [tok.strip() for tok in remaining_text.split() if tok.strip()]

        return multi_word_matches + single_tokens

    def get_category(self, token: str) -> str:
        return self.object_categories.get(token, "neutral_object")

    def get_response_for_token(self, token: str) -> str:
        if token in self.object_responses:
            return self.object_responses[token]

        best_match = ""
        best_response = ""
        for key, response in self.object_responses.items():
            if token.startswith(key) and len(key) > len(best_match):
                best_match = key
                best_response = response
        if best_response:
            return best_response

        for key, response in self.object_responses.items():
            if len(key) >= 3 and key in token:
                return response

        category = self.get_category(token)
        return self.category_responses.get(category, "No immediate hazard detected; safe to move.")

    def dedupe_by_category(self, tokens: list[str]) -> list[str]:
        chosen = []
        seen_categories = set()

        for token in tokens:
            category = self.get_category(token)
            if category not in seen_categories:
                seen_categories.add(category)
                chosen.append(token)

        return chosen

    def filter_neutral_objects(self, tokens: list[str]) -> list[str]:
        if not tokens:
            return []

        categories = [self.get_category(token) for token in tokens]
        has_priority = any(category in self.priority_categories for category in categories)

        if has_priority:
            return [token for token in tokens if self.get_category(token) != "neutral_object"]

        return tokens

    def retrieve(self, query: str) -> list[str]:
        tokens = self.tokenize_input(query)

        if not tokens:
            return ["No immediate hazard detected; safe to move."]

        deduped_tokens = self.dedupe_by_category(tokens)
        filtered_tokens = self.filter_neutral_objects(deduped_tokens)

        if not filtered_tokens:
            return ["No immediate hazard detected; safe to move."]

        responses = []
        seen_responses = set()

        for token in filtered_tokens:
            response = self.get_response_for_token(token)
            if response not in seen_responses:
                seen_responses.add(response)
                responses.append(response)

        if not responses:
            return ["No immediate hazard detected; safe to move."]

        return responses[:3]

    def _template_combine(self, responses: list[str]) -> str:
        if len(responses) == 2:
            second = responses[1][0].lower() + responses[1][1:] if len(responses[1]) > 1 else responses[1].lower()
            return f"{responses[0]} Also, {second}"

        second = responses[1][0].lower() + responses[1][1:] if len(responses[1]) > 1 else responses[1].lower()
        third = responses[2][0].lower() + responses[2][1:] if len(responses[2]) > 1 else responses[2].lower()
        return f"{responses[0]} Also, {second} {third}"

    def combine_responses(self, responses: list[str], scene_caption: str = "") -> str:
        if not responses:
            return "No immediate hazard detected; safe to move."

        if len(responses) == 1 and not scene_caption:
            return responses[0]

        llm_result = _llm_combine(responses, self.user_profile, scene_caption)
        if llm_result:
            return llm_result

        if len(responses) == 1:
            return responses[0]
        return self._template_combine(responses)

    def generate_response(self, vision_text: str):
        scene_caption = ""
        if ". Scene: " in vision_text:
            parts = vision_text.split(". Scene: ", 1)
            vision_text = parts[0]
            scene_caption = parts[1]

        responses = self.retrieve(vision_text)
        combined_response = self.combine_responses(responses, scene_caption)
        return combined_response, responses