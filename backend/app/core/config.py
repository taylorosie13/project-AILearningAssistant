import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parents[2]
UPLOADS_DIR = BASE_DIR / "uploads"
UPLOADS_DIR.mkdir(exist_ok=True)

DB_FILE = BASE_DIR / "assistant.db"

DEFAULT_MAX_UPLOAD_SIZE = 20 * 1024 * 1024
VIDEO_MAX_UPLOAD_SIZE = 2 * 1024 * 1024 * 1024
TEMP_DIR_PREFIX = "office-to-pdf-"
TEMP_DIR_TTL_SECONDS = 60 * 30
ORPHAN_UPLOAD_TTL_SECONDS = 60 * 60 * 24
GEMINI_METADATA_SUFFIX = ".gemini.json"
CHAT_HISTORY_LIMIT = int(os.getenv("CHAT_HISTORY_LIMIT", "24"))

SUPPORTED_EXTENSIONS: dict[str, dict[str, object]] = {
    ".jpg": {"kind": "image", "mime_types": {"image/jpeg"}},
    ".jpeg": {"kind": "image", "mime_types": {"image/jpeg"}},
    ".png": {"kind": "image", "mime_types": {"image/png"}},
    ".heic": {"kind": "image", "mime_types": {"image/heic", "image/heif"}},
    ".gif": {"kind": "image", "mime_types": {"image/gif"}},
    ".webp": {"kind": "image", "mime_types": {"image/webp"}},
    ".pdf": {"kind": "document", "mime_types": {"application/pdf"}},
    ".doc": {"kind": "document", "mime_types": {"application/msword"}},
    ".docx": {
        "kind": "document",
        "mime_types": {"application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    },
    ".ppt": {"kind": "document", "mime_types": {"application/vnd.ms-powerpoint"}},
    ".pptx": {
        "kind": "document",
        "mime_types": {"application/vnd.openxmlformats-officedocument.presentationml.presentation"},
    },
    ".xls": {"kind": "document", "mime_types": {"application/vnd.ms-excel"}},
    ".xlsx": {
        "kind": "document",
        "mime_types": {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    },
    ".txt": {"kind": "document", "mime_types": {"text/plain"}},
    ".md": {"kind": "document", "mime_types": {"text/markdown", "text/plain"}},
    ".m4a": {"kind": "audio", "mime_types": {"audio/m4a", "audio/mp4", "audio/x-m4a"}},
    ".mp3": {"kind": "audio", "mime_types": {"audio/mpeg", "audio/mp3"}},
    ".wav": {"kind": "audio", "mime_types": {"audio/wav", "audio/x-wav", "audio/wave"}},
    ".aac": {"kind": "audio", "mime_types": {"audio/aac"}},
    ".mp4": {"kind": "video", "mime_types": {"video/mp4", "audio/mp4"}},
    ".mov": {"kind": "video", "mime_types": {"video/quicktime"}},
    ".m4v": {"kind": "video", "mime_types": {"video/x-m4v", "video/mp4"}},
}

OFFICE_DOCUMENT_EXTENSIONS = {".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx"}
TEXT_FILE_EXTENSIONS = {".txt", ".md"}

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3-flash-preview")

SYSTEM_PROMPT = """你是一个多模态学习助手。
1. 当用户上传数学、物理或化学题目图片时，请给出详细的解题步骤。
2. 请务必使用标准的 LaTeX 语法来包裹所有的数学公式。行内公式使用 $...$，独立块公式使用 $$...$$。
3. 使用 Markdown 标题和列表来组织内容，使其清晰易读。
4. 如果是文字交流，请保持亲切、专业的语气。"""
