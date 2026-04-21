import sqlite3
from contextlib import contextmanager
from typing import Iterator
from uuid import uuid4

from .config import DB_FILE


def init_db() -> None:
    with get_db_connection() as conn:
        cursor = conn.cursor()

        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                role TEXT,
                content TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                file_paths TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions (session_id)
            )
            """
        )

        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS knowledge_cards (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                card_id TEXT UNIQUE,
                title TEXT,
                content TEXT,
                category TEXT,
                tags TEXT,
                source_session_id TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                note_id TEXT UNIQUE,
                title TEXT NOT NULL,
                content_markdown TEXT NOT NULL,
                summary TEXT,
                category TEXT,
                tags TEXT,
                source_type TEXT NOT NULL DEFAULT 'manual',
                source_ref_id TEXT,
                source_title TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        note_columns = {
            row["name"]
            for row in cursor.execute("PRAGMA table_info(notes)").fetchall()
        }
        if "note_id" not in note_columns:
            cursor.execute("ALTER TABLE notes ADD COLUMN note_id TEXT")

        existing_rows = cursor.execute(
            "SELECT id FROM notes WHERE note_id IS NULL OR TRIM(note_id) = ''"
        ).fetchall()
        for row in existing_rows:
            cursor.execute(
                "UPDATE notes SET note_id = ? WHERE id = ?",
                (_generate_note_public_id(), row["id"]),
            )

        card_columns = {
            row["name"]
            for row in cursor.execute("PRAGMA table_info(knowledge_cards)").fetchall()
        }
        if "card_id" not in card_columns:
            cursor.execute("ALTER TABLE knowledge_cards ADD COLUMN card_id TEXT")

        existing_card_rows = cursor.execute(
            "SELECT id FROM knowledge_cards WHERE card_id IS NULL OR TRIM(card_id) = ''"
        ).fetchall()
        for row in existing_card_rows:
            cursor.execute(
                "UPDATE knowledge_cards SET card_id = ? WHERE id = ?",
                (_generate_card_public_id(), row["id"]),
            )

        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_session_id_id ON messages(session_id, id)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON sessions(created_at DESC)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_knowledge_cards_created_at ON knowledge_cards(created_at DESC)"
        )
        cursor.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_cards_card_id ON knowledge_cards(card_id)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_notes_category ON notes(category)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_notes_source_type_ref ON notes(source_type, source_ref_id)"
        )
        cursor.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_notes_note_id ON notes(note_id)"
        )
        conn.commit()

    print("✅数据库初始化成功")


def _apply_pragmas(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA temp_store = MEMORY")
    conn.execute("PRAGMA busy_timeout = 5000")


def _generate_note_public_id() -> str:
    return f"note_{uuid4().hex}"


def _generate_card_public_id() -> str:
    return f"card_{uuid4().hex}"


@contextmanager
def get_db_connection() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    _apply_pragmas(conn)
    try:
        yield conn
    finally:
        conn.close()
