import sqlite3
import os

DB_FILE = "assistant.db"


def init_db():
    """初始化数据库并创建所有必要的表结构"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()

    # 创建会话表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS sessions (
            session_id TEXT PRIMARY KEY,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ''')

    # 创建消息表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            role TEXT,
            content TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (session_id) REFERENCES sessions (session_id)
        )
    ''')

    # 为支持多模态，向已有的 messages 表中添加 file_paths 列
    try:
        cursor.execute("ALTER TABLE messages ADD COLUMN file_paths TEXT")
    except sqlite3.OperationalError:
        # 如果列已存在，会抛出 OperationalError，忽略即可
        pass

    # 创建知识卡片表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS knowledge_cards (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT,
            content TEXT,
            source_session_id TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ''')

    conn.commit()
    conn.close()
    print("✅本地SQLite数据库初始化成功！包含会话、消息和知识卡片表。")


def get_db_connection():
    """获取数据库连接对象的辅助函数"""
    conn = sqlite3.connect(DB_FILE)
    # 设置row_factory使得我们可以像字典一样通过列名访问数据
    conn.row_factory = sqlite3.Row
    return conn