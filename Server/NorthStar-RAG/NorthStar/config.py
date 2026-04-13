from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent

KNOWLEDGE_BASE_PATH = BASE_DIR / "knowledge_base.txt"
USER_PROFILE_DIR = BASE_DIR / "user_profiles"

DEFAULT_PROFILE = "default"
DEFAULT_TOP_K = 5

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
EMBEDDING_MODEL_NAME = "all-MiniLM-L6-v2"