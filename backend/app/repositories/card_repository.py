from typing import Any
from uuid import uuid4

from app.core.database import get_db_connection


def fetch_cards() -> list[dict[str, Any]]:
    query = """
        SELECT card_id, title, content, category, tags, source_session_id, created_at
        FROM knowledge_cards
        ORDER BY created_at DESC
    """
    with get_db_connection() as conn:
        rows = conn.execute(query).fetchall()
    return [dict(row) for row in rows]


def fetch_card_by_id(card_id: str) -> dict[str, Any] | None:
    query = """
        SELECT card_id, title, content, category, tags, source_session_id, created_at
        FROM knowledge_cards
        WHERE card_id = ?
    """
    with get_db_connection() as conn:
        row = conn.execute(query, (card_id,)).fetchone()
    return dict(row) if row else None


def create_card(
    title: str,
    content: str,
    category: str | None,
    tags: str | None,
    source_session_id: str | None,
) -> str:
    public_card_id = f"card_{uuid4().hex}"
    with get_db_connection() as conn:
        conn.execute(
            """
            INSERT INTO knowledge_cards (card_id, title, content, category, tags, source_session_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (public_card_id, title, content, category, tags, source_session_id),
        )
        conn.commit()
        return public_card_id


def update_card(
    card_id: str,
    title: str,
    content: str,
    category: str | None,
    tags: str | None,
) -> bool:
    with get_db_connection() as conn:
        cursor = conn.execute(
            """
            UPDATE knowledge_cards
            SET title = ?, content = ?, category = ?, tags = ?
            WHERE card_id = ?
            """,
            (title, content, category, tags, card_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def delete_card(card_id: str) -> bool:
    with get_db_connection() as conn:
        cursor = conn.execute("DELETE FROM knowledge_cards WHERE card_id = ?", (card_id,))
        conn.commit()
        return cursor.rowcount > 0
