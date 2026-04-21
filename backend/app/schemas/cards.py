from pydantic import BaseModel, Field


class KnowledgeCardBase(BaseModel):
    title: str = Field(..., min_length=1, description="卡片标题")
    content: str = Field(..., min_length=1, description="卡片内容")
    category: str | None = Field(default=None, description="卡片分类")
    tags: list[str] | None = Field(default=None, description="标签列表")


class KnowledgeCardCreate(KnowledgeCardBase):
    source_session_id: str | None = Field(default=None, description="来源会话 ID")


class KnowledgeCardUpdate(KnowledgeCardBase):
    pass


class KnowledgeCardResponse(BaseModel):
    card_id: str
    title: str
    content: str
    category: str | None = None
    tags: list[str] = Field(default_factory=list)
    source_session_id: str | None = None
    created_at: str


class KnowledgeCardMutationResponse(BaseModel):
    message: str
    card: KnowledgeCardResponse


class KnowledgeCardDeleteResponse(BaseModel):
    message: str
    card_id: str
