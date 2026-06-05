import json
import uuid
from typing import Any

from app.core.database import get_db_connection


def create_session(session_id: str | None = None) -> str:
    resolved_session_id = session_id or str(uuid.uuid4())
    with get_db_connection() as conn:
        conn.execute("INSERT INTO sessions (session_id) VALUES (?)", (resolved_session_id,))
        conn.commit()
    return resolved_session_id


def session_exists(session_id: str) -> bool:
    with get_db_connection() as conn:
        row = conn.execute(
            "SELECT 1 FROM sessions WHERE session_id = ? LIMIT 1",
            (session_id,),
        ).fetchone()
    return row is not None


def save_message(
    session_id: str,
    role: str,
    content: str,
    file_paths: list[str] | None = None,
    display_content: str | None = None,
) -> None:
    serialized_paths = json.dumps(file_paths) if file_paths else None
    with get_db_connection() as conn:
        conn.execute(
            "INSERT INTO messages (session_id, role, content, file_paths, display_content) VALUES (?, ?, ?, ?, ?)",
            (session_id, role, content, serialized_paths, display_content),
        )
        conn.commit()


def fetch_recent_messages(session_id: str, limit: int) -> list[dict[str, Any]]:
    query = """
        SELECT role, content, created_at, file_paths
        FROM (
            SELECT role, content, created_at, file_paths, id
            FROM messages
            WHERE session_id = ?
            ORDER BY id DESC
            LIMIT ?
        )
        ORDER BY id ASC
    """
    with get_db_connection() as conn:
        rows = conn.execute(query, (session_id, limit)).fetchall()
    return [dict(row) for row in rows]


def fetch_all_session_messages(session_id: str) -> list[dict[str, Any]]:
    with get_db_connection() as conn:
        rows = conn.execute(
            """
            SELECT role, content, COALESCE(display_content, content) AS display_content, created_at, file_paths
            FROM messages
            WHERE session_id = ?
            ORDER BY id ASC
            """,
            (session_id,),
        ).fetchall()
    return [dict(row) for row in rows]


def fetch_sessions() -> list[dict[str, Any]]:
    query = """
        SELECT s.session_id, s.created_at,
        (
            SELECT COALESCE(display_content, content)
            FROM messages m
            WHERE m.session_id = s.session_id
            ORDER BY id ASC
            LIMIT 1
        ) AS preview
        FROM sessions s
        ORDER BY s.created_at DESC
    """
    with get_db_connection() as conn:
        rows = conn.execute(query).fetchall()
    return [dict(row) for row in rows]


def fetch_session_file_references(session_id: str) -> list[list[str]]:
    with get_db_connection() as conn:
        rows = conn.execute(
            "SELECT file_paths FROM messages WHERE session_id = ? AND file_paths IS NOT NULL",
            (session_id,),
        ).fetchall()

    references: list[list[str]] = []
    for row in rows:
        try:
            file_paths = json.loads(row["file_paths"])
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(file_paths, list):
            references.append(file_paths)
    return references


def delete_session(session_id: str) -> None:
    with get_db_connection() as conn:
        conn.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
        conn.execute("DELETE FROM sessions WHERE session_id = ?", (session_id,))
        conn.commit()


def collect_referenced_upload_path_strings() -> list[str]:
    with get_db_connection() as conn:
        rows = conn.execute(
            "SELECT file_paths FROM messages WHERE file_paths IS NOT NULL"
        ).fetchall()

    file_paths: list[str] = []
    for row in rows:
        try:
            parsed = json.loads(row["file_paths"])
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(parsed, list):
            file_paths.extend(path for path in parsed if isinstance(path, str))
    return file_paths
