from typing import Literal

from pydantic import BaseModel


class ChatRequest(BaseModel):
    prompt: str
    display_prompt: str | None = None
    session_id: str | None = None
    file_paths: list[str] | None = None
    learning_mode: Literal["normal", "feynman"] = "normal"
