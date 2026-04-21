from fastapi import APIRouter

from app.schemas.cards import (
    KnowledgeCardCreate,
    KnowledgeCardDeleteResponse,
    KnowledgeCardMutationResponse,
    KnowledgeCardResponse,
    KnowledgeCardUpdate,
)
from app.services.card_service import (
    create_knowledge_card,
    delete_knowledge_card,
    get_knowledge_card,
    get_knowledge_cards,
    update_knowledge_card,
)

router = APIRouter()


@router.get("/cards", response_model=list[KnowledgeCardResponse])
async def get_cards_endpoint():
    return get_knowledge_cards()


@router.get("/cards/{card_id}", response_model=KnowledgeCardResponse)
async def get_card_endpoint(card_id: str):
    return get_knowledge_card(card_id)


@router.post("/cards", response_model=KnowledgeCardMutationResponse, status_code=201)
async def create_card_endpoint(card: KnowledgeCardCreate):
    return create_knowledge_card(card)


@router.put("/cards/{card_id}", response_model=KnowledgeCardMutationResponse)
async def update_card_endpoint(card_id: str, card: KnowledgeCardUpdate):
    return update_knowledge_card(card_id, card)


@router.delete("/cards/{card_id}", response_model=KnowledgeCardDeleteResponse)
async def delete_card_endpoint(card_id: str):
    return delete_knowledge_card(card_id)
