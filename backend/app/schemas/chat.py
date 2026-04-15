from pydantic import BaseModel


class ChatRequest(BaseModel):
    prompt: str
    session_id: str | None = None
    file_paths: list[str] | None = None
