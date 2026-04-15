from fastapi import APIRouter

from app.schemas.cards import KnowledgeCardCreate, KnowledgeCardUpdate
from app.services.card_service import (
    create_knowledge_card,
    delete_knowledge_card,
    get_knowledge_cards,
    update_knowledge_card,
)

router = APIRouter()


@router.get("/cards")
async def get_cards_endpoint():
    return get_knowledge_cards()


@router.post("/cards")
async def create_card_endpoint(card: KnowledgeCardCreate):
    return create_knowledge_card(card)


@router.put("/cards/{card_id}")
async def update_card_endpoint(card_id: int, card: KnowledgeCardUpdate):
    return update_knowledge_card(card_id, card)


@router.delete("/cards/{card_id}")
async def delete_card_endpoint(card_id: int):
    return delete_knowledge_card(card_id)
