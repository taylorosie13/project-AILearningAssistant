import json
import os
import re
import asyncio
import shutil
import subprocess
import tempfile
import uuid
import time
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
MAX_UPLOAD_SIZE = 20 * 1024 * 1024
TEMP_DIR_PREFIX = "office-to-pdf-"
TEMP_DIR_TTL_SECONDS = 60 * 30
ORPHAN_UPLOAD_TTL_SECONDS = 60 * 60 * 24

GENERIC_ALLOWED_MIME_TYPES = {
    "application/octet-stream",
    "binary/octet-stream",
}

SUPPORTED_EXTENSIONS: dict[str, dict[str, object]] = {
    ".jpg": {"kind": "image", "mime_types": {"image/jpeg"}},
    ".jpeg": {"kind": "image", "mime_types": {"image/jpeg"}},
    ".png": {"kind": "image", "mime_types": {"image/png"}},
    ".heic": {"kind": "image", "mime_types": {"image/heic", "image/heif"}},
    ".gif": {"kind": "image", "mime_types": {"image/gif"}},
    ".webp": {"kind": "image", "mime_types": {"image/webp"}},
    ".pdf": {"kind": "document", "mime_types": {"application/pdf"}},
    ".doc": {"kind": "document", "mime_types": {"application/msword"}},
    ".docx": {
        "kind": "document",
        "mime_types": {"application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    },
    ".ppt": {"kind": "document", "mime_types": {"application/vnd.ms-powerpoint"}},
    ".pptx": {
        "kind": "document",
        "mime_types": {"application/vnd.openxmlformats-officedocument.presentationml.presentation"},
    },
    ".xls": {"kind": "document", "mime_types": {"application/vnd.ms-excel"}},
    ".xlsx": {
        "kind": "document",
        "mime_types": {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    },
    ".txt": {"kind": "document", "mime_types": {"text/plain"}},
    ".md": {"kind": "document", "mime_types": {"text/markdown", "text/plain"}},
    ".m4a": {"kind": "audio", "mime_types": {"audio/m4a", "audio/mp4", "audio/x-m4a"}},
    ".mp3": {"kind": "audio", "mime_types": {"audio/mpeg", "audio/mp3"}},
    ".wav": {"kind": "audio", "mime_types": {"audio/wav", "audio/x-wav", "audio/wave"}},
    ".aac": {"kind": "audio", "mime_types": {"audio/aac"}},
    ".mp4": {"kind": "audio", "mime_types": {"audio/mp4", "video/mp4"}},
}

OFFICE_DOCUMENT_EXTENSIONS = {".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx"}
TEXT_FILE_EXTENSIONS = {".txt", ".md"}

# 在程序启动时执行数据库初始化
init_db()

# 初始化FastAPI应用
app = FastAPI(title="Multimodal Learning Assistant API")

# 挂载静态文件目录，允许前端通过 /uploads/... 访问已上传的文件
app.mount("/uploads", StaticFiles(directory=str(UPLOADS_DIR)), name="uploads")


@app.on_event("startup")
async def startup_cleanup_temp_files():
    cleanup_result = run_temp_file_cleanup()
    print(
        "🧹 启动清理完成: "
        f"{cleanup_result['removed_temp_dirs']} 个临时目录, "
        f"{cleanup_result['removed_orphan_uploads']} 个孤儿上传文件"
    )

# 显式读取环境变量以进行调试和赋值
api_key = os.getenv("GEMINI_API_KEY")
model_name = os.getenv("GEMINI_MODEL", "gemini-3-flash-preview")

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
        print(f"✅ 当前 Gemini 模型: {model_name}")
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


def get_file_extension(file_name: str | None) -> str:
    return Path(file_name or "").suffix.lower()


def get_file_type_info(file_name: str | None) -> dict[str, object] | None:
    extension = get_file_extension(file_name)
    return SUPPORTED_EXTENSIONS.get(extension)


def get_file_kind(file_name: str | None) -> str | None:
    file_type_info = get_file_type_info(file_name)
    return cast(str | None, file_type_info["kind"] if file_type_info else None)


def sanitize_filename(file_name: str) -> str:
    cleaned = Path(file_name).name.strip()
    if not cleaned:
        return ""

    stem = Path(cleaned).stem
    extension = Path(cleaned).suffix.lower()
    safe_stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._-")
    safe_stem = safe_stem[:60] if safe_stem else "file"
    return f"{safe_stem}{extension}"


def parse_display_name_from_path(file_path: str) -> str:
    file_name = Path(file_path).name
    if "__" in file_name:
        return file_name.split("__", 1)[1]
    return file_name


def build_file_upload_error(file_name: str) -> str:
    extension = get_file_extension(file_name)
    if extension in OFFICE_DOCUMENT_EXTENSIONS:
        return (
            f"文件 {file_name} 转换或上传失败。"
            "请确认本机已安装 LibreOffice，并稍后重试。"
        )
    return f"文件 {file_name} 发送给模型时失败，请稍后重试。"


def is_network_transport_error(error: Exception) -> bool:
    lowered = str(error).lower()
    network_markers = [
        "ssl",
        "eof occurred in violation of protocol",
        "connectionpool",
        "read timed out",
        "temporarily unavailable",
        "connection reset",
        "broken pipe",
        "max retries exceeded",
    ]
    return any(marker in lowered for marker in network_markers)


def build_model_file_upload_error(file_name: str, error: Exception) -> HTTPException:
    if is_network_transport_error(error):
        return HTTPException(
            status_code=502,
            detail=(
                f"文件《{file_name}》已经在本地处理成功，但上传到 Gemini 时网络连接被中断。"
                "请稍后重试；如果持续出现，请检查当前网络、代理或 VPN 设置。"
            )
        )

    extension = get_file_extension(file_name)
    if extension in OFFICE_DOCUMENT_EXTENSIONS:
        return HTTPException(
            status_code=500,
            detail=(
                f"文件《{file_name}》已成功转成 PDF，但上传到 Gemini 失败。"
                "请稍后重试，并查看后端日志中的具体错误信息。"
            )
        )

    return HTTPException(status_code=500, detail=build_file_upload_error(file_name))


def get_office_converter_command() -> str | None:
    command = shutil.which("soffice") or shutil.which("libreoffice")
    if command:
        return command

    macos_app_binary = Path("/Applications/LibreOffice.app/Contents/MacOS/soffice")
    if macos_app_binary.exists():
        return str(macos_app_binary)

    return None


def validate_files_for_model(file_paths: list[str]) -> None:
    office_file_names = [
        parse_display_name_from_path(file_path)
        for file_path in file_paths
        if get_file_extension(file_path) in OFFICE_DOCUMENT_EXTENSIONS
    ]

    if office_file_names and not get_office_converter_command():
        joined_names = "、".join(office_file_names)
        raise HTTPException(
            status_code=400,
            detail=(
                f"这些 Office 文件需要先转换为 PDF 才能交给 Gemini：{joined_names}。"
                "当前后端未检测到 LibreOffice，请先安装 LibreOffice 后再重试。"
            )
            )


def is_path_expired(path: Path, ttl_seconds: int, now: float | None = None) -> bool:
    current_time = now or time.time()
    try:
        return (current_time - path.stat().st_mtime) > ttl_seconds
    except FileNotFoundError:
        return False


def extract_text_file_content(file_path: Path) -> str:
    return file_path.read_text(encoding="utf-8", errors="ignore")


def convert_office_file_to_pdf(file_path: Path) -> Path:
    converter = get_office_converter_command()
    if not converter:
        raise HTTPException(status_code=400, detail="当前后端未检测到 LibreOffice，无法将 Office 文件转换为 PDF。")

    temp_dir = Path(tempfile.mkdtemp(prefix="office-to-pdf-"))
    output_pdf = temp_dir / f"{file_path.stem}.pdf"
    command = [
        converter,
        "--headless",
        "--convert-to",
        "pdf",
        "--outdir",
        str(temp_dir),
        str(file_path),
    ]

    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0 or not output_pdf.exists():
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        details = stderr or stdout or "未知错误"
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise HTTPException(status_code=500, detail=f"Office 文件转 PDF 失败：{details}")

    return output_pdf


def collect_referenced_upload_paths() -> set[Path]:
    referenced_paths: set[Path] = set()
    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT file_paths FROM messages WHERE file_paths IS NOT NULL")
        rows = cursor.fetchall()

    for row in rows:
        try:
            file_paths = json.loads(row["file_paths"])
        except (json.JSONDecodeError, TypeError):
            continue

        if not isinstance(file_paths, list):
            continue

        for file_path in file_paths:
            resolved_path = resolve_upload_path(file_path)
            if resolved_path:
                referenced_paths.add(resolved_path)

    return referenced_paths


def cleanup_stale_office_temp_dirs() -> int:
    temp_root = Path(tempfile.gettempdir())
    removed_count = 0
    for temp_dir in temp_root.glob(f"{TEMP_DIR_PREFIX}*"):
        if not temp_dir.is_dir():
            continue
        if not is_path_expired(temp_dir, TEMP_DIR_TTL_SECONDS):
            continue
        shutil.rmtree(temp_dir, ignore_errors=True)
        removed_count += 1
        print(f"🧹 已清理过期临时目录: {temp_dir}")
    return removed_count


def cleanup_orphaned_upload_files() -> int:
    referenced_paths = collect_referenced_upload_paths()
    removed_count = 0
    for upload_file in UPLOADS_DIR.iterdir():
        if not upload_file.is_file():
            continue
        if upload_file in referenced_paths:
            continue
        if not is_path_expired(upload_file, ORPHAN_UPLOAD_TTL_SECONDS):
            continue
        upload_file.unlink(missing_ok=True)
        removed_count += 1
        print(f"🧹 已清理孤儿上传文件: {upload_file}")
    return removed_count


def run_temp_file_cleanup() -> dict[str, int]:
    temp_dir_count = cleanup_stale_office_temp_dirs()
    orphan_upload_count = cleanup_orphaned_upload_files()
    return {
        "removed_temp_dirs": temp_dir_count,
        "removed_orphan_uploads": orphan_upload_count,
    }


def translate_gemini_error(error: Exception) -> HTTPException:
    message = str(error)
    lowered = message.lower()

    network_markers = [
        "ssl",
        "eof occurred in violation of protocol",
        "connectionpool",
        "read timed out",
        "temporarily unavailable",
        "connection reset",
        "broken pipe",
    ]
    if any(marker in lowered for marker in network_markers):
        return HTTPException(
            status_code=502,
            detail="连接 Gemini 服务时网络不稳定，刚刚请求被中断了。请稍后重试；如果持续出现，请检查当前网络、代理或 VPN 设置。"
        )

    if "api key" in lowered or "permission denied" in lowered or "unauthorized" in lowered:
        return HTTPException(status_code=500, detail="Gemini API Key 无效或权限不足，请检查后端配置。")

    if "not found" in lowered and "model" in lowered:
        return HTTPException(status_code=500, detail=f"当前模型 {model_name} 不可用，请检查 GEMINI_MODEL 配置。")

    return HTTPException(status_code=500, detail=f"Gemini 调用失败：{message}")


async def upload_file_to_gemini_with_retry(file_path: Path) -> object:
    last_error: Exception | None = None

    for attempt in range(3):
        try:
            return await client.aio.files.upload(path=str(file_path))
        except Exception as error:
            last_error = error
            print(f"❌ Gemini 文件上传失败（第 {attempt + 1} 次）: {error}")
            if attempt < 2 and is_network_transport_error(error):
                print(f"🔁 将在 {1.5 * (attempt + 1):.1f} 秒后重试文件上传...")
                await asyncio.sleep(1.5 * (attempt + 1))
                continue
            raise

    assert last_error is not None
    raise last_error


async def generate_content_with_retry(contents: list[dict[str, object]]) -> str:
    last_error: Exception | None = None

    for attempt in range(2):
        try:
            response = await client.aio.models.generate_content(
                model=model_name,
                contents=contents,
                config={'system_instruction': system_prompt}
            )
            return response.text
        except Exception as error:
            last_error = error
            print(f"❌ Gemini 生成失败（第 {attempt + 1} 次）: {error}")
            if attempt == 0:
                await asyncio.sleep(1)

    assert last_error is not None
    raise translate_gemini_error(last_error)


def validate_upload_metadata(file_name: str | None, content_type: str | None) -> tuple[str, dict[str, object]]:
    safe_name = sanitize_filename(file_name or "")
    if not safe_name:
        raise HTTPException(status_code=400, detail="文件名无效，请重新选择文件。")

    file_type_info = get_file_type_info(safe_name)
    if not file_type_info:
        raise HTTPException(status_code=400, detail="暂不支持该文件类型上传。")

    normalized_content_type = (content_type or "").split(";")[0].strip().lower()
    allowed_mime_types = cast(set[str], file_type_info["mime_types"])
    if normalized_content_type and normalized_content_type not in allowed_mime_types and normalized_content_type not in GENERIC_ALLOWED_MIME_TYPES:
        raise HTTPException(status_code=400, detail="文件类型与内容类型不匹配，请重新导出后再试。")

    return safe_name, file_type_info


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
    validate_files_for_model(normalized_file_paths)

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
        file_upload_errors: list[str] = []
        for file_path in normalized_file_paths:
            resolved_path = resolve_upload_path(file_path)
            if not resolved_path or not resolved_path.exists():
                file_upload_errors.append(f"未找到附件 {parse_display_name_from_path(file_path)}，请重新上传后再试。")
                continue

            display_name = parse_display_name_from_path(file_path)
            extension = get_file_extension(display_name)
            upload_source_path = resolved_path
            temp_cleanup_dir: Path | None = None

            if extension in OFFICE_DOCUMENT_EXTENSIONS:
                try:
                    upload_source_path = convert_office_file_to_pdf(resolved_path)
                    temp_cleanup_dir = upload_source_path.parent
                    print(f"✅ 已将 Office 文件转换为 PDF: {display_name} -> {upload_source_path.name}")
                except HTTPException as conversion_error:
                    file_upload_errors.append(conversion_error.detail)
                    continue

            if extension in TEXT_FILE_EXTENSIONS:
                try:
                    text_content = extract_text_file_content(resolved_path).strip()
                    if not text_content:
                        file_upload_errors.append(f"文件 {display_name} 中未提取到可用文本，请检查文件内容后重试。")
                        continue
                    current_parts.append({"text": f"以下是文件《{display_name}》的内容，请结合用户问题进行分析：\n\n{text_content}"})
                    print(f"✅ 已将文本文件内容附加到 Prompt: {display_name}")
                except Exception as extraction_error:
                    print(f"❌ 读取文本文件 {resolved_path} 失败: {extraction_error}")
                    file_upload_errors.append(f"文件 {display_name} 读取失败，请确认文件编码或内容后重试。")
                continue

            try:
                print(f"正在上传文件到 Gemini: {upload_source_path}")
                uploaded_file = await upload_file_to_gemini_with_retry(upload_source_path)
                current_parts.append({
                    "file_data": {
                        "mime_type": uploaded_file.mime_type,
                        "file_uri": uploaded_file.uri
                    }
                })
                print(f"文件已关联至 Prompt: {uploaded_file.uri}")
            except Exception as upload_error:
                print(f"❌ 上传文件 {upload_source_path} 到 Gemini 失败: {upload_error}")
                raise build_model_file_upload_error(display_name, upload_error)
            finally:
                if temp_cleanup_dir:
                    shutil.rmtree(temp_cleanup_dir, ignore_errors=True)

        if file_upload_errors:
            raise HTTPException(status_code=400, detail=file_upload_errors[0])

        gemini_contents.append({
            "role": "user",
            "parts": current_parts
        })

        # 4.调用模型
        print(f"正在调用 Gemini 模型 ({len(gemini_contents)} 轮对话上下文)...")
        try:
            ai_response_text = await generate_content_with_retry(gemini_contents)
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
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/upload/file")
async def upload_file(file: UploadFile = File(...)):
    """上传文件（图片/音频/文档）至本地"""
    try:
        safe_name, file_type_info = validate_upload_metadata(file.filename, file.content_type)
        unique_filename = f"{uuid.uuid4().hex}__{safe_name}"
        file_path = UPLOADS_DIR / unique_filename

        file_size = 0
        with open(file_path, "wb") as buffer:
            writable_buffer = cast(BinaryIO, buffer)
            while chunk := file.file.read(1024 * 1024):
                file_size += len(chunk)
                if file_size > MAX_UPLOAD_SIZE:
                    raise HTTPException(status_code=400, detail="文件过大，请上传 20MB 以内的文件。")
                writable_buffer.write(chunk)

        if file_size == 0:
            raise HTTPException(status_code=400, detail="上传失败：文件内容为空。")

        relative_path = str(file_path.relative_to(BASE_DIR))
        return {
            "message": "文件上传成功",
            "file_path": relative_path,
            "original_filename": safe_name,
            "mime_type": (file.content_type or "application/octet-stream").split(";")[0].strip().lower() or "application/octet-stream",
            "file_kind": cast(str, file_type_info["kind"]),
            "file_size": file_size,
        }
    except HTTPException:
        if 'file_path' in locals() and file_path.exists():
            file_path.unlink(missing_ok=True)
        raise
    except Exception as e:
        if 'file_path' in locals() and file_path.exists():
            file_path.unlink(missing_ok=True)
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


@app.post("/maintenance/cleanup-temp-files")
async def cleanup_temp_files():
    try:
        cleanup_result = run_temp_file_cleanup()
        return {
            "message": "临时文件清理完成",
            **cleanup_result,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"临时文件清理失败: {e}")

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
