from typing import Any

from app.core.database import get_db_connection


def fetch_cards() -> list[dict[str, Any]]:
    query = """
        SELECT id, title, content, category, tags, source_session_id, created_at
        FROM knowledge_cards
        ORDER BY created_at DESC
    """
    with get_db_connection() as conn:
        rows = conn.execute(query).fetchall()
    return [dict(row) for row in rows]


def create_card(
    title: str,
    content: str,
    category: str | None,
    tags: str | None,
    source_session_id: str | None,
) -> int:
    with get_db_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO knowledge_cards (title, content, category, tags, source_session_id)
            VALUES (?, ?, ?, ?, ?)
            """,
            (title, content, category, tags, source_session_id),
        )
        conn.commit()
        return int(cursor.lastrowid)


def update_card(
    card_id: int,
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
            WHERE id = ?
            """,
            (title, content, category, tags, card_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def delete_card(card_id: int) -> None:
    with get_db_connection() as conn:
        conn.execute("DELETE FROM knowledge_cards WHERE id = ?", (card_id,))
        conn.commit()
