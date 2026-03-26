from pydantic import BaseModel
from typing import Optional

#定义聊天请求的数据模型
class ChatRequest(BaseModel):
    prompt: str
    session_id: Optional[str] = None
    file_paths: Optional[list[str]] = None

#定义创建知识卡片请求的数据模型
class KnowledgeCardCreate(BaseModel):
    title: str
    content: str
    category: Optional[str] = None
    tags: Optional[list[str]] = None
    source_session_id: Optional[str] = None


class KnowledgeCardUpdate(BaseModel):
    title: str
    content: str
    category: Optional[str] = None
    tags: Optional[list[str]] = None
