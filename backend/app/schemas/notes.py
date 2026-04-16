from pydantic import BaseModel, Field


class NoteBase(BaseModel):
    title: str
    content_markdown: str
    summary: str | None = None
    category: str | None = None
    tags: list[str] | None = None


class NoteCreate(NoteBase):
    source_type: str = "manual"
    source_ref_id: str | None = None
    source_title: str | None = None


class NoteUpdate(NoteBase):
    pass


class NoteGenerateRequest(BaseModel):
    source_type: str = Field(..., description="manual/session/message/document/audio/card")
    session_id: str | None = None
    source_text: str | None = None
    file_paths: list[str] | None = None
    category: str | None = None
    tags: list[str] | None = None
    source_ref_id: str | None = None
    source_title: str | None = None
    title_hint: str | None = None

