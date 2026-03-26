import os
import uuid
import shutil
import json
from pathlib import Path
from typing import cast, BinaryIO
from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.staticfiles import StaticFiles
from google import genai
from dotenv import load_dotenv

# 导入我们自己拆分的独立模块
from database import init_db, get_db_connection
from models import ChatRequest, KnowledgeCardCreate, KnowledgeCardUpdate

# 加载当前目录下的.env文件
load_dotenv()

BASE_DIR = Path(__file__).resolve().parent
UPLOADS_DIR = BASE_DIR / "uploads"
UPLOADS_DIR.mkdir(exist_ok=True)

# 在程序启动时执行数据库初始化
init_db()

# 初始化FastAPI应用
app = FastAPI(title="Multimodal Learning Assistant API")

# 挂载静态文件目录，允许前端通过 /uploads/... 访问已上传的文件
app.mount("/uploads", StaticFiles(directory=str(UPLOADS_DIR)), name="uploads")

# 显式读取环境变量以进行调试和赋值
api_key = os.getenv("GEMINI_API_KEY")

if not api_key:
    print("❌警告:未能在环境变量中找到GEMINI_API_KEY。请检查.env文件是否存在且命名正确。")
    client = None
else:
    try:
        # 显式将获取到的key传给Client
        client = genai.Client(api_key=api_key)
        # 增加系统预设指令
        system_prompt = """你是一个多模态学习助手。
        1. 当用户上传数学、物理或化学题目图片时，请给出详细的解题步骤。
        2. 请务必使用标准的 LaTeX 语法来包裹所有的数学公式。行内公式使用 $...$，独立块公式使用 $$...$$。
        3. 使用 Markdown 标题和列表来组织内容，使其清晰易读。
        4. 如果是文字交流，请保持亲切、专业的语气。"""
        print("✅Gemini API Client 初始化成功！已配置系统指令。")
    except Exception as e:
        print(f"❌初始化客户端失败:{e}")
        client = None


def normalize_file_paths(file_paths: list[str] | None) -> list[str]:
    """只接受 uploads 目录内的文件，并统一保存为相对路径。"""
    if not file_paths:
        return []

    normalized_paths: list[str] = []
    for raw_path in file_paths:
        resolved_path = resolve_upload_path(raw_path)
        if not resolved_path:
            print(f"⚠️ 忽略非法文件路径: {raw_path}")
            continue

        normalized_paths.append(str(resolved_path.relative_to(BASE_DIR)))

    return normalized_paths


def resolve_upload_path(file_path: str) -> Path | None:
    """将客户端传入的路径解析为 uploads 目录内的安全绝对路径。"""
    if not file_path:
        return None

    candidate = Path(file_path)
    if not candidate.is_absolute():
        candidate = BASE_DIR / candidate

    try:
        resolved_path = candidate.resolve(strict=False)
        resolved_path.relative_to(UPLOADS_DIR)
    except ValueError:
        return None

    return resolved_path


def normalize_tags(tags: list[str] | None) -> list[str]:
    if not tags:
        return []

    normalized_tags: list[str] = []
    seen: set[str] = set()
    for tag in tags:
        cleaned_tag = tag.strip()
        if not cleaned_tag:
            continue

        lowercase_tag = cleaned_tag.casefold()
        if lowercase_tag in seen:
            continue

        seen.add(lowercase_tag)
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
        return parsed_tags if isinstance(parsed_tags, list) else []
    except json.JSONDecodeError:
        return []


@app.get("/")
async def root():
    return {"message": "多模态学习助手本地后端已成功启动，模块化重构完成！"}


@app.post("/chat")
async def chat_with_gemini(request: ChatRequest):
    if not client:
        raise HTTPException(status_code=500, detail="客户端未初始化，请检查.env文件。")

    normalized_file_paths = normalize_file_paths(request.file_paths)

    # 处理会话ID
    current_session_id = request.session_id
    if not current_session_id:
        current_session_id = str(uuid.uuid4())
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("INSERT INTO sessions (session_id) VALUES (?)", (current_session_id,))
            conn.commit()

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()

            # 1.保存用户消息
            file_paths_str = json.dumps(normalized_file_paths) if normalized_file_paths else None
            cursor.execute(
                "INSERT INTO messages (session_id, role, content, file_paths) VALUES (?, ?, ?, ?)",
                (current_session_id, "user", request.prompt, file_paths_str)
            )
            conn.commit()

            # 2.获取历史记录，构建带上下文的对话
            cursor.execute(
                "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id ASC",
                (current_session_id,)
            )
            history_rows = cursor.fetchall()
        
        gemini_contents = []
        # 将历史记录加入上下文（排除刚刚插入的最后一条，因为我们要为其附加文件）
        for row in history_rows[:-1]:
            # 为了适配新版SDK，历史文本需要直接按指定格式组装
            # 对于字符串我们可以直接传递简单的格式
            content_part = {"text": row["content"]}
            gemini_contents.append({
                "role": row["role"],
                "parts": [content_part]
            })

        # 3.构建当前的多模态消息
        current_parts = [{"text": request.prompt}]
        for file_path in normalized_file_paths:
            resolved_path = resolve_upload_path(file_path)
            if not resolved_path or not resolved_path.exists():
                print(f"⚠️ 警告：未找到本地文件 {file_path}")
                continue

            try:
                print(f"正在上传文件到 Gemini: {resolved_path}")
                uploaded_file = await client.aio.files.upload(path=str(resolved_path))
                current_parts.append({
                    "file_data": {
                        "mime_type": uploaded_file.mime_type,
                        "file_uri": uploaded_file.uri
                    }
                })
                print(f"文件已关联至 Prompt: {uploaded_file.uri}")
            except Exception as upload_error:
                print(f"❌ 上传文件 {resolved_path} 到 Gemini 失败: {upload_error}")

        gemini_contents.append({
            "role": "user",
            "parts": current_parts
        })

        # 4.调用模型
        print(f"正在调用 Gemini 模型 ({len(gemini_contents)} 轮对话上下文)...")
        try:
            # 增加系统指令参数，确保公式输出规范
            response = await client.aio.models.generate_content(
                model='gemini-3-flash-preview',
                contents=gemini_contents,
                config={'system_instruction': system_prompt}
            )
            ai_response_text = response.text
            print("✅ Gemini 响应生成成功。")
        except Exception as gen_error:
            import traceback
            print("❌ Gemini 生成失败！错误详情：")
            traceback.print_exc() # 打印完整堆栈到终端
            raise gen_error

        # 5.保存AI消息
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)",
                (current_session_id, "model", ai_response_text)
            )
            conn.commit()

        return {
            "session_id": current_session_id,
            "response": ai_response_text
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/upload/file")
async def upload_file(file: UploadFile = File(...)):
    """上传文件（图片/音频/文档）至本地"""
    try:
        # 生成唯一文件名
        ext = os.path.splitext(file.filename or "")[1]
        unique_filename = f"{uuid.uuid4()}{ext}"
        file_path = UPLOADS_DIR / unique_filename
        
        with open(file_path, "wb") as buffer:
            writable_buffer = cast(BinaryIO, buffer)
            shutil.copyfileobj(file.file, writable_buffer)

        relative_path = str(file_path.relative_to(BASE_DIR))
        return {
            "message": "文件上传成功",
            "file_path": relative_path,
            "original_filename": file.filename
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"文件上传失败: {e}")

@app.get("/sessions")
async def get_sessions():
    """获取所有会话列表，包含第一条消息预览"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            # 使用子查询获取每个会话的第一条消息内容作为预览标题
            query = """
                SELECT s.session_id, s.created_at, 
                (SELECT content FROM messages m WHERE m.session_id = s.session_id ORDER BY id ASC LIMIT 1) as preview
                FROM sessions s 
                ORDER BY s.created_at DESC
            """
            cursor.execute(query)
            rows = cursor.fetchall()
        return [
            {
                "session_id": row["session_id"], 
                "created_at": row["created_at"],
                "preview": row["preview"] or "新会话"
            } for row in rows
        ]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/sessions/{session_id}/messages")
async def get_session_messages(session_id: str):
    """获取指定会话的聊天记录"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT role, content, created_at, file_paths FROM messages WHERE session_id = ? ORDER BY id ASC",
                (session_id,)
            )
            rows = cursor.fetchall()
        
        messages = []
        for row in rows:
            file_paths = None
            if "file_paths" in row.keys() and row["file_paths"]:
                try:
                    file_paths = json.loads(row["file_paths"])
                except json.JSONDecodeError:
                    pass
                    
            messages.append({
                "role": row["role"], 
                "content": row["content"], 
                "created_at": row["created_at"],
                "file_paths": file_paths
            })
        return messages
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/cards")
async def get_knowledge_cards():
    """获取所有知识卡片"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT id, title, content, category, tags, source_session_id, created_at "
                "FROM knowledge_cards ORDER BY created_at DESC"
            )
            rows = cursor.fetchall()
        cards = []
        for row in rows:
            card = dict(row)
            card["tags"] = deserialize_tags(row["tags"])
            cards.append(card)
        return cards
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/cards")
async def create_knowledge_card(card: KnowledgeCardCreate):
    """供iOS端调用的保存知识卡片接口"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "INSERT INTO knowledge_cards (title, content, category, tags, source_session_id) VALUES (?, ?, ?, ?, ?)",
                (
                    card.title.strip(),
                    card.content.strip(),
                    card.category.strip() if card.category else None,
                    serialize_tags(card.tags),
                    card.source_session_id
                )
            )
            conn.commit()
            card_id = cursor.lastrowid
        return {"message": "知识卡片创建成功", "card_id": card_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/cards/{card_id}")
async def delete_knowledge_card(card_id: int):
    """删除指定的知识卡片"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM knowledge_cards WHERE id = ?", (card_id,))
            conn.commit()
        return {"message": "卡片删除成功"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.put("/cards/{card_id}")
async def update_knowledge_card(card_id: int, card: KnowledgeCardUpdate):
    """更新指定知识卡片的标题、内容、分类和标签"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "UPDATE knowledge_cards SET title = ?, content = ?, category = ?, tags = ? WHERE id = ?",
                (
                    card.title.strip(),
                    card.content.strip(),
                    card.category.strip() if card.category else None,
                    serialize_tags(card.tags),
                    card_id
                )
            )
            conn.commit()

            if cursor.rowcount == 0:
                raise HTTPException(status_code=404, detail="未找到要更新的知识卡片")

        return {"message": "卡片更新成功", "card_id": card_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/sessions/{session_id}")
async def delete_session(session_id: str):
    """删除指定会话及其所有消息记录，并清理物理文件"""
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            
            # 1. 查询该会话下所有带有文件路径的消息
            cursor.execute(
                "SELECT file_paths FROM messages WHERE session_id = ? AND file_paths IS NOT NULL",
                (session_id,)
            )
            rows = cursor.fetchall()
        
            # 2. 遍历结果，清理物理文件
            for row in rows:
                try:
                    file_paths = json.loads(row["file_paths"])
                    if isinstance(file_paths, list):
                        for path in file_paths:
                            resolved_path = resolve_upload_path(path)
                            if resolved_path and resolved_path.exists():
                                resolved_path.unlink()
                                print(f"🗑️ 已清理物理文件: {resolved_path}")
                except (json.JSONDecodeError, TypeError) as parse_error:
                    print(f"⚠️ 解析文件路径失败: {parse_error}")

            # 3. 删除消息记录
            cursor.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
            # 4. 删除会话
            cursor.execute("DELETE FROM sessions WHERE session_id = ?", (session_id,))
            
            conn.commit()
        return {"message": "会话及其关联文件已成功删除"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn

    # 在本地启动服务，使用 host="0.0.0.0" 允许局域网内其他设备访问
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
