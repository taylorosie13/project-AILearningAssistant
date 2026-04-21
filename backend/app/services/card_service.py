import json

from fastapi import HTTPException

from app.repositories.card_repository import (
    create_card,
    delete_card,
    fetch_card_by_id,
    fetch_cards,
    update_card,
)
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


def _clean_required_text(value: str | None, field_name: str) -> str:
    cleaned = (value or "").strip()
    if not cleaned:
        raise HTTPException(status_code=400, detail=f"{field_name}不能为空。")
    return cleaned


def _clean_optional_text(value: str | None) -> str | None:
    cleaned = (value or "").strip()
    return cleaned or None


def _serialize_card(card: dict[str, object]) -> dict[str, object]:
    serialized = dict(card)
    serialized["tags"] = deserialize_tags(card.get("tags"))
    return serialized


def get_knowledge_cards() -> list[dict[str, object]]:
    return [_serialize_card(card) for card in fetch_cards()]


def get_knowledge_card(card_id: str) -> dict[str, object]:
    card = fetch_card_by_id(card_id)
    if not card:
        raise HTTPException(status_code=404, detail="未找到这张知识卡片。")
    return _serialize_card(card)


def create_knowledge_card(card: KnowledgeCardCreate) -> dict[str, object]:
    card_id = create_card(
        title=_clean_required_text(card.title, "卡片标题"),
        content=_clean_required_text(card.content, "卡片内容"),
        category=_clean_optional_text(card.category),
        tags=serialize_tags(card.tags),
        source_session_id=_clean_optional_text(card.source_session_id),
    )
    return {
        "message": "知识卡片创建成功",
        "card": get_knowledge_card(card_id),
    }


def update_knowledge_card(card_id: str, card: KnowledgeCardUpdate) -> dict[str, object]:
    updated = update_card(
        card_id=card_id,
        title=_clean_required_text(card.title, "卡片标题"),
        content=_clean_required_text(card.content, "卡片内容"),
        category=_clean_optional_text(card.category),
        tags=serialize_tags(card.tags),
    )
    if not updated:
        raise HTTPException(status_code=404, detail="未找到要更新的知识卡片。")
    return {
        "message": "卡片更新成功",
        "card": get_knowledge_card(card_id),
    }


def delete_knowledge_card(card_id: str) -> dict[str, object]:
    deleted = delete_card(card_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="未找到要删除的知识卡片。")
    return {"message": "卡片删除成功", "card_id": card_id}
