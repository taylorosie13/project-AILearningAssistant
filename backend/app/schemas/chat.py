from typing import Literal

from pydantic import BaseModel


class ChatRequest(BaseModel):
    prompt: str
    session_id: str | None = None
    file_paths: list[str] | None = None
    learning_mode: Literal["normal", "feynman"] = "normal"
