import asyncio
import json
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import BinaryIO, cast

from fastapi import HTTPException, UploadFile

from app.core.config import (
    BASE_DIR,
    DEFAULT_MAX_UPLOAD_SIZE,
    GEMINI_METADATA_SUFFIX,
    OFFICE_DOCUMENT_EXTENSIONS,
    ORPHAN_UPLOAD_TTL_SECONDS,
    SUPPORTED_EXTENSIONS,
    TEMP_DIR_PREFIX,
    TEMP_DIR_TTL_SECONDS,
    TEXT_FILE_EXTENSIONS,
    UPLOADS_DIR,
    VIDEO_MAX_UPLOAD_SIZE,
)
from app.repositories.session_repository import collect_referenced_upload_path_strings
from app.services.gemini_service import (
    get_gemini_file_name,
    is_network_transport_error,
    upload_file_with_retry,
)

GENERIC_ALLOWED_MIME_TYPES = {
    "application/octet-stream",
    "binary/octet-stream",
}


def normalize_file_paths(file_paths: list[str] | None) -> list[str]:
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
    return SUPPORTED_EXTENSIONS.get(get_file_extension(file_name))


def get_file_kind(file_name: str | None) -> str | None:
    file_type_info = get_file_type_info(file_name)
    if not file_type_info:
        return None
    return cast(str, file_type_info["kind"])


def get_max_upload_size(file_kind: str | None) -> int:
    return VIDEO_MAX_UPLOAD_SIZE if file_kind == "video" else DEFAULT_MAX_UPLOAD_SIZE


def format_upload_limit(file_kind: str | None) -> str:
    return "2GB" if file_kind == "video" else "20MB"


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


def get_gemini_metadata_path(file_path: Path) -> Path:
    return file_path.with_name(f"{file_path.name}{GEMINI_METADATA_SUFFIX}")


def load_gemini_metadata(file_path: Path) -> dict[str, object] | None:
    metadata_path = get_gemini_metadata_path(file_path)
    if not metadata_path.exists():
        return None

    try:
        loaded = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return loaded if isinstance(loaded, dict) else None


def save_gemini_metadata(file_path: Path, metadata: dict[str, object]) -> None:
    get_gemini_metadata_path(file_path).write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def remove_gemini_metadata(file_path: Path) -> None:
    get_gemini_metadata_path(file_path).unlink(missing_ok=True)


def build_file_upload_error(file_name: str) -> str:
    extension = get_file_extension(file_name)
    if extension in OFFICE_DOCUMENT_EXTENSIONS:
        return (
            f"文件 {file_name} 转换或上传失败。"
            "请确认本机已安装 LibreOffice，并稍后重试。"
        )
    return f"文件 {file_name} 发送给模型时失败，请稍后重试。"


def build_model_file_upload_error(file_name: str, error: Exception) -> HTTPException:
    if "文件处理超时" in str(error):
        return HTTPException(
            status_code=504,
            detail=f"文件《{file_name}》已经上传成功，但云端解析花的时间太久了。请稍后再试，或者换一个更短、更小的视频后重试。",
        )
    if "文件处理失败" in str(error):
        return HTTPException(
            status_code=502,
            detail=f"文件《{file_name}》上传成功了，但云端解析失败，请稍后重试。",
        )
    if is_network_transport_error(error):
        return HTTPException(
            status_code=502,
            detail=f"文件《{file_name}》已经在本地处理成功，但上传到 Gemini 时网络连接被中断。请稍后重试；如果持续出现，请检查当前网络、代理或 VPN 设置。",
        )
    if get_file_extension(file_name) in OFFICE_DOCUMENT_EXTENSIONS:
        return HTTPException(
            status_code=500,
            detail=f"文件《{file_name}》已成功转成 PDF，但上传到 Gemini 失败。请稍后重试，并查看后端日志中的具体错误信息。",
        )
    return HTTPException(status_code=500, detail=build_file_upload_error(file_name))


def get_office_converter_command() -> str | None:
    command = shutil.which("soffice") or shutil.which("libreoffice")
    if command:
        return command

    macos_binary = Path("/Applications/LibreOffice.app/Contents/MacOS/soffice")
    if macos_binary.exists():
        return str(macos_binary)
    return None


def validate_files_for_model(file_paths: list[str]) -> None:
    office_names = [
        parse_display_name_from_path(file_path)
        for file_path in file_paths
        if get_file_extension(file_path) in OFFICE_DOCUMENT_EXTENSIONS
    ]
    if office_names and not get_office_converter_command():
        raise HTTPException(
            status_code=400,
            detail=(
                f"这些 Office 文件需要先转换为 PDF 才能交给 Gemini：{'、'.join(office_names)}。"
                "当前后端未检测到 LibreOffice，请先安装 LibreOffice 后再重试。"
            ),
        )


def extract_text_file_content(file_path: Path) -> str:
    return file_path.read_text(encoding="utf-8", errors="ignore")


def convert_office_file_to_pdf_sync(file_path: Path) -> Path:
    converter = get_office_converter_command()
    if not converter:
        raise HTTPException(status_code=400, detail="当前后端未检测到 LibreOffice，无法将 Office 文件转换为 PDF。")

    temp_dir = Path(tempfile.mkdtemp(prefix=TEMP_DIR_PREFIX))
    output_pdf = temp_dir / f"{file_path.stem}.pdf"
    completed = subprocess.run(
        [converter, "--headless", "--convert-to", "pdf", "--outdir", str(temp_dir), str(file_path)],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0 or not output_pdf.exists():
        details = completed.stderr.strip() or completed.stdout.strip() or "未知错误"
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise HTTPException(status_code=500, detail=f"Office 文件转 PDF 失败：{details}")
    return output_pdf


async def convert_office_file_to_pdf(file_path: Path) -> Path:
    return await asyncio.to_thread(convert_office_file_to_pdf_sync, file_path)


async def extract_text_from_file(file_path: Path) -> str:
    return await asyncio.to_thread(extract_text_file_content, file_path)


async def prepare_file_for_model(
    file_path: Path,
    *,
    display_name: str | None = None,
    file_kind: str | None = None,
) -> dict[str, object]:
    resolved_display_name = display_name or file_path.name
    resolved_file_kind = file_kind or get_file_kind(resolved_display_name) or "document"
    cached_metadata = await asyncio.to_thread(load_gemini_metadata, file_path)
    if cached_metadata:
        return cached_metadata

    extension = get_file_extension(resolved_display_name)
    upload_source_path = file_path
    temp_cleanup_dir: Path | None = None

    try:
        if extension in OFFICE_DOCUMENT_EXTENSIONS:
            upload_source_path = await convert_office_file_to_pdf(file_path)
            temp_cleanup_dir = upload_source_path.parent
            print(f"✅ 已将 Office 文件转换为 PDF: {resolved_display_name} -> {upload_source_path.name}")

        if extension in TEXT_FILE_EXTENSIONS:
            text_content = (await extract_text_from_file(file_path)).strip()
            if not text_content:
                raise HTTPException(
                    status_code=400,
                    detail=f"文件 {resolved_display_name} 中未提取到可用文本，请检查文件内容后重试。",
                )
            metadata = {
                "mode": "text_inline",
                "display_name": resolved_display_name,
                "file_kind": resolved_file_kind,
                "text_content": text_content,
            }
            await asyncio.to_thread(save_gemini_metadata, file_path, metadata)
            return metadata

        uploaded_file = await upload_file_with_retry(str(upload_source_path))
        metadata = {
            "mode": "cloud_file",
            "display_name": resolved_display_name,
            "file_kind": resolved_file_kind,
            "mime_type": cast(str, getattr(uploaded_file, "mime_type", "application/octet-stream")),
            "file_uri": cast(str, getattr(uploaded_file, "uri", "")),
            "gemini_name": get_gemini_file_name(uploaded_file),
        }
        await asyncio.to_thread(save_gemini_metadata, file_path, metadata)
        return metadata
    except HTTPException:
        raise
    except Exception as error:
        print(f"❌ 文件预处理失败: {resolved_display_name} -> {error}")
        raise build_model_file_upload_error(resolved_display_name, error)
    finally:
        if temp_cleanup_dir:
            await asyncio.to_thread(shutil.rmtree, temp_cleanup_dir, True)


def build_multimodal_file_prompt(display_name: str, file_kind: str | None) -> str | None:
    if file_kind == "video":
        return (
            f"下面这个附件是视频《{display_name}》。"
            "请结合画面、字幕、语音和时间顺序一起分析。"
            "如果用户没有指定任务，就先概括视频内容，再提炼重点信息。"
        )
    if file_kind == "audio":
        return f"下面这个附件是音频《{display_name}》，请结合语音内容回答用户问题。"
    return None


def validate_upload_metadata(file_name: str | None, content_type: str | None) -> tuple[str, dict[str, object]]:
    safe_name = sanitize_filename(file_name or "")
    if not safe_name:
        raise HTTPException(status_code=400, detail="文件名无效，请重新选择文件。")

    file_type_info = get_file_type_info(safe_name)
    if not file_type_info:
        raise HTTPException(status_code=400, detail="暂不支持该文件类型上传。")

    normalized_content_type = (content_type or "").split(";")[0].strip().lower()
    allowed_mime_types = cast(set[str], file_type_info["mime_types"])
    if (
        normalized_content_type
        and normalized_content_type not in allowed_mime_types
        and normalized_content_type not in GENERIC_ALLOWED_MIME_TYPES
    ):
        raise HTTPException(status_code=400, detail="文件类型与内容类型不匹配，请重新导出后再试。")
    return safe_name, file_type_info


async def save_upload_file(file: UploadFile) -> dict[str, object]:
    safe_name, file_type_info = validate_upload_metadata(file.filename, file.content_type)
    file_kind = cast(str, file_type_info["kind"])
    max_upload_size = get_max_upload_size(file_kind)
    unique_filename = f"{uuid.uuid4().hex}__{safe_name}"
    file_path = UPLOADS_DIR / unique_filename
    file_size = 0

    try:
        with open(file_path, "wb") as buffer:
            writable_buffer = cast(BinaryIO, buffer)
            while chunk := await file.read(1024 * 1024):
                file_size += len(chunk)
                if file_size > max_upload_size:
                    raise HTTPException(
                        status_code=400,
                        detail=f"文件过大，请上传 {format_upload_limit(file_kind)} 以内的文件。",
                    )
                await asyncio.to_thread(writable_buffer.write, chunk)

        if file_size == 0:
            raise HTTPException(status_code=400, detail="上传失败：文件内容为空。")

        prepared_for_model = True
        model_warning: str | None = None
        try:
            await prepare_file_for_model(file_path, display_name=safe_name, file_kind=file_kind)
        except HTTPException as error:
            prepared_for_model = False
            model_warning = str(error.detail)
            print(f"⚠️ 文件已上传到本地，但预处理失败: {safe_name} -> {model_warning}")
        except Exception as error:
            prepared_for_model = False
            model_warning = build_file_upload_error(safe_name)
            print(f"⚠️ 文件已上传到本地，但预处理出现异常: {safe_name} -> {error}")

        return {
            "message": "文件上传成功" if not prepared_for_model else "文件上传并准备完成",
            "file_path": str(file_path.relative_to(BASE_DIR)),
            "original_filename": safe_name,
            "mime_type": (file.content_type or "application/octet-stream").split(";")[0].strip().lower()
            or "application/octet-stream",
            "file_kind": file_kind,
            "file_size": file_size,
            "prepared_for_model": prepared_for_model,
            "model_warning": model_warning,
        }
    except Exception:
        if file_path.exists():
            file_path.unlink(missing_ok=True)
            remove_gemini_metadata(file_path)
        raise


def is_path_expired(path: Path, ttl_seconds: int, now: float) -> bool:
    try:
        return (now - path.stat().st_mtime) > ttl_seconds
    except FileNotFoundError:
        return False


def cleanup_stale_office_temp_dirs() -> int:
    removed_count = 0
    now = time.time()
    for temp_dir in Path(tempfile.gettempdir()).glob(f"{TEMP_DIR_PREFIX}*"):
        if temp_dir.is_dir() and is_path_expired(temp_dir, TEMP_DIR_TTL_SECONDS, now):
            shutil.rmtree(temp_dir, ignore_errors=True)
            removed_count += 1
    return removed_count


def cleanup_orphaned_upload_files() -> int:
    referenced_paths: set[Path] = set()
    for file_path in collect_referenced_upload_path_strings():
        resolved_path = resolve_upload_path(file_path)
        if resolved_path:
            referenced_paths.add(resolved_path)

    removed_count = 0
    now = time.time()
    for upload_file in UPLOADS_DIR.iterdir():
        if not upload_file.is_file():
            continue

        if upload_file.name.endswith(GEMINI_METADATA_SUFFIX):
            source_name = upload_file.name.removesuffix(GEMINI_METADATA_SUFFIX)
            source_path = upload_file.with_name(source_name)
            if source_path in referenced_paths or source_path.exists():
                continue
            if is_path_expired(upload_file, ORPHAN_UPLOAD_TTL_SECONDS, now):
                upload_file.unlink(missing_ok=True)
                removed_count += 1
            continue

        if upload_file in referenced_paths:
            continue
        if is_path_expired(upload_file, ORPHAN_UPLOAD_TTL_SECONDS, now):
            upload_file.unlink(missing_ok=True)
            remove_gemini_metadata(upload_file)
            removed_count += 1

    return removed_count


def run_temp_file_cleanup() -> dict[str, int]:
    return {
        "removed_temp_dirs": cleanup_stale_office_temp_dirs(),
        "removed_orphan_uploads": cleanup_orphaned_upload_files(),
    }
