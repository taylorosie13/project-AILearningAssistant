from pydantic import BaseModel


class KnowledgeCardCreate(BaseModel):
    title: str
    content: str
    category: str | None = None
    tags: list[str] | None = None
    source_session_id: str | None = None


class KnowledgeCardUpdate(BaseModel):
    title: str
    content: str
    category: str | None = None
    tags: list[str] | None = None
