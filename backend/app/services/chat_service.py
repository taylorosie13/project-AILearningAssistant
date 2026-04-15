import asyncio
import json

from fastapi import HTTPException

from app.core.config import CHAT_HISTORY_LIMIT
from app.repositories.session_repository import (
    create_session,
    delete_session,
    fetch_all_session_messages,
    fetch_recent_messages,
    fetch_session_file_references,
    fetch_sessions,
    save_message,
    session_exists,
)
from app.schemas.chat import ChatRequest
from app.services.file_service import (
    build_multimodal_file_prompt,
    get_file_kind,
    normalize_file_paths,
    parse_display_name_from_path,
    prepare_file_for_model,
    remove_gemini_metadata,
    resolve_upload_path,
    validate_files_for_model,
)
from app.services.gemini_service import ensure_client, generate_content_with_retry


async def _prepare_current_parts(normalized_file_paths: list[str]) -> list[dict[str, object]]:
    async def prepare_single_file(file_path: str) -> tuple[str, dict[str, object] | None, str | None]:
        resolved_path = resolve_upload_path(file_path)
        display_name = parse_display_name_from_path(file_path)
        if not resolved_path or not resolved_path.exists():
            return display_name, None, f"未找到附件 {display_name}，请重新上传后再试。"

        file_kind = get_file_kind(display_name)
        try:
            prepared_file = await prepare_file_for_model(
                resolved_path,
                display_name=display_name,
                file_kind=file_kind,
            )
            return display_name, prepared_file, None
        except HTTPException as error:
            return display_name, None, str(error.detail)

    parts: list[dict[str, object]] = []
    results = await asyncio.gather(*(prepare_single_file(file_path) for file_path in normalized_file_paths))
    for file_path, (display_name, prepared_file, error) in zip(normalized_file_paths, results):
        if error:
            raise HTTPException(status_code=400, detail=error)

        assert prepared_file is not None
        file_kind = get_file_kind(display_name)
        file_prompt = build_multimodal_file_prompt(display_name, file_kind)
        if file_prompt:
            parts.append({"text": file_prompt})

        if prepared_file.get("mode") == "text_inline":
            text_content = str(prepared_file.get("text_content", "")).strip()
            if not text_content:
                raise HTTPException(
                    status_code=400,
                    detail=f"文件 {display_name} 中未提取到可用文本，请检查文件内容后重试。",
                )
            parts.append({"text": f"以下是文件《{display_name}》的内容，请结合用户问题进行分析：\n\n{text_content}"})
            continue

        mime_type = str(prepared_file.get("mime_type", "")).strip()
        file_uri = str(prepared_file.get("file_uri", "")).strip()
        if not mime_type or not file_uri:
            raise HTTPException(status_code=400, detail=f"文件 {display_name} 的云端引用无效，请重新上传后再试。")
        parts.append({"file_data": {"mime_type": mime_type, "file_uri": file_uri}})

    return parts


async def chat_with_gemini(request: ChatRequest) -> dict[str, object]:
    ensure_client()
    normalized_file_paths = normalize_file_paths(request.file_paths)
    validate_files_for_model(normalized_file_paths)

    current_session_id = request.session_id
    if current_session_id and not session_exists(current_session_id):
        create_session(current_session_id)
    elif not current_session_id:
        current_session_id = create_session()

    save_message(current_session_id, "user", request.prompt, normalized_file_paths)

    history_rows = fetch_recent_messages(current_session_id, CHAT_HISTORY_LIMIT)
    gemini_contents: list[dict[str, object]] = []
    for row in history_rows[:-1]:
        gemini_contents.append(
            {
                "role": row["role"],
                "parts": [{"text": row["content"]}],
            }
        )

    current_parts = [{"text": request.prompt}]
    current_parts.extend(await _prepare_current_parts(normalized_file_paths))
    gemini_contents.append({"role": "user", "parts": current_parts})

    print(f"正在调用 Gemini 模型 ({len(gemini_contents)} 轮对话上下文)...")
    ai_response_text = await generate_content_with_retry(gemini_contents)
    save_message(current_session_id, "model", ai_response_text)
    return {"session_id": current_session_id, "response": ai_response_text}


def get_sessions() -> list[dict[str, object]]:
    rows = fetch_sessions()
    return [
        {
            "session_id": row["session_id"],
            "created_at": row["created_at"],
            "preview": row["preview"] or "新会话",
        }
        for row in rows
    ]


def get_session_messages(session_id: str) -> list[dict[str, object]]:
    rows = fetch_all_session_messages(session_id)
    messages: list[dict[str, object]] = []
    for row in rows:
        file_paths = None
        if row.get("file_paths"):
            try:
                file_paths = json.loads(row["file_paths"])
            except json.JSONDecodeError:
                file_paths = None
        messages.append(
            {
                "role": row["role"],
                "content": row["content"],
                "created_at": row["created_at"],
                "file_paths": file_paths,
            }
        )
    return messages


async def delete_session_with_files(session_id: str) -> dict[str, str]:
    file_references = fetch_session_file_references(session_id)
    for file_paths in file_references:
        for path in file_paths:
            resolved_path = resolve_upload_path(path)
            if resolved_path and resolved_path.exists():
                await asyncio.to_thread(resolved_path.unlink, True)
                await asyncio.to_thread(remove_gemini_metadata, resolved_path)
    delete_session(session_id)
    return {"message": "会话及其关联文件已成功删除"}
