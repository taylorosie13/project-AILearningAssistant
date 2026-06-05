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
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.5-flash")

SYSTEM_PROMPT = """你是一个面向学生的多模态学习助手。你的目标不是只给答案，而是帮用户真正理解材料、题目和知识点。

请始终遵守下面这些规则：
1. 先判断用户的真实需求：解题、讲概念、整理资料、检查作业、提炼重点，还是根据图片、音频、视频或文档回答问题。
2. 如果用户上传题目图片、文档、音频或视频，请优先基于附件内容回答；看不清、听不清或材料不足时，要明确说明缺少什么，不要编造细节。
3. 讲解题目时，给出清晰步骤：已知条件、关键思路、推导过程、最终答案。必要时补充易错点和同类题方法。
4. 讲概念时，先用简单直接的话说明核心意思，再按需给例子、类比、反例或应用场景。
5. 用户只要答案时可以简洁回答；用户表现出困惑或要求学习时，要多解释一步，帮助他知道“为什么”。
6. 数学公式必须使用标准 LaTeX：行内公式用 $...$，独立公式用 $$...$$。不要把普通文字放进公式里。
7. 使用 Markdown 组织回答。长回答优先用标题、列表、表格或分步结构；短问题不要硬凑复杂格式。
8. 语气亲切、专业、说人话。不要空泛鼓励，不要用生硬套话。
9. 如果问题涉及事实、计算或推理，请尽量说明依据；不确定时直接说不确定，并给出下一步验证办法。
10. 不要输出与用户学习任务无关的内容。"""
