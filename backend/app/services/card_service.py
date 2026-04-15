import json

from fastapi import HTTPException

from app.repositories.card_repository import create_card, delete_card, fetch_cards, update_card
from app.schemas.cards import KnowledgeCardCreate, KnowledgeCardUpdate


def normalize_tags(tags: list[str] | None) -> list[str]:
    if not tags:
        return []

    normalized_tags: list[str] = []
    seen: set[str] = set()
    for tag in tags:
        cleaned_tag = tag.strip()
        if not cleaned_tag:
            continue
        lowered = cleaned_tag.casefold()
        if lowered in seen:
            continue
        seen.add(lowered)
        normalized_tags.append(cleaned_tag)
    return normalized_tags


def serialize_tags(tags: list[str] | None) -> str | None:
    normalized_tags = normalize_tags(tags)
    return json.dumps(normalized_tags) if normalized_tags else None


def deserialize_tags(tags_raw: str | None) -> list[str]:
    if not tags_raw:
        return []
    try:
        parsed_tags = json.loads(tags_raw)
    except json.JSONDecodeError:
        return []
    return parsed_tags if isinstance(parsed_tags, list) else []


def get_knowledge_cards() -> list[dict[str, object]]:
    cards = fetch_cards()
    for card in cards:
        card["tags"] = deserialize_tags(card.get("tags"))
    return cards


def create_knowledge_card(card: KnowledgeCardCreate) -> dict[str, object]:
    card_id = create_card(
        title=card.title.strip(),
        content=card.content.strip(),
        category=card.category.strip() if card.category else None,
        tags=serialize_tags(card.tags),
        source_session_id=card.source_session_id,
    )
    return {"message": "知识卡片创建成功", "card_id": card_id}


def update_knowledge_card(card_id: int, card: KnowledgeCardUpdate) -> dict[str, object]:
    updated = update_card(
        card_id=card_id,
        title=card.title.strip(),
        content=card.content.strip(),
        category=card.category.strip() if card.category else None,
        tags=serialize_tags(card.tags),
    )
    if not updated:
        raise HTTPException(status_code=404, detail="未找到要更新的知识卡片")
    return {"message": "卡片更新成功", "card_id": card_id}


def delete_knowledge_card(card_id: int) -> dict[str, str]:
    delete_card(card_id)
    return {"message": "卡片删除成功"}
