from typing import Any

from app.core.database import get_db_connection


def fetch_notes() -> list[dict[str, Any]]:
    query = """
        SELECT
            id,
            title,
            content_markdown,
            summary,
            category,
            tags,
            source_type,
            source_ref_id,
            source_title,
            created_at,
            updated_at
        FROM notes
        ORDER BY updated_at DESC, id DESC
    """
    with get_db_connection() as conn:
        rows = conn.execute(query).fetchall()
    return [dict(row) for row in rows]


def fetch_note_by_id(note_id: int) -> dict[str, Any] | None:
    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT
                id,
                title,
                content_markdown,
                summary,
                category,
                tags,
                source_type,
                source_ref_id,
                source_title,
                created_at,
                updated_at
            FROM notes
            WHERE id = ?
            """,
            (note_id,),
        ).fetchone()
    return dict(row) if row else None


def create_note(
    title: str,
    content_markdown: str,
    summary: str | None,
    category: str | None,
    tags: str | None,
    source_type: str,
    source_ref_id: str | None,
    source_title: str | None,
) -> int:
    with get_db_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO notes (
                title,
                content_markdown,
                summary,
                category,
                tags,
                source_type,
                source_ref_id,
                source_title
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                title,
                content_markdown,
                summary,
                category,
                tags,
                source_type,
                source_ref_id,
                source_title,
            ),
        )
        conn.commit()
        return int(cursor.lastrowid)


def update_note(
    note_id: int,
    title: str,
    content_markdown: str,
    summary: str | None,
    category: str | None,
    tags: str | None,
) -> bool:
    with get_db_connection() as conn:
        cursor = conn.execute(
            """
            UPDATE notes
            SET
                title = ?,
                content_markdown = ?,
                summary = ?,
                category = ?,
                tags = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (title, content_markdown, summary, category, tags, note_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def delete_note(note_id: int) -> None:
    with get_db_connection() as conn:
        conn.execute("DELETE FROM notes WHERE id = ?", (note_id,))
        conn.commit()
