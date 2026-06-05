import asyncio
import json
from collections.abc import AsyncIterator

from fastapi import HTTPException

from app.core.config import CHAT_HISTORY_LIMIT, SYSTEM_PROMPT
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
from app.services.gemini_service import (
    ensure_client,
    generate_content_stream_with_retry,
    translate_gemini_error,
)


def _build_system_instruction(learning_mode: str) -> str | None:
    if learning_mode != "feynman":
        return None

    return f"""{SYSTEM_PROMPT}

当前处于费曼学习模式。你是一位会用费曼学习法带着用户真正学会知识的学习教练。
请始终遵守下面这些规则：
1. 不要直接进入标准答案模式，优先让用户先用自己的话解释概念、过程或结论。
2. 先判断用户解释里哪里真的懂了，哪里只是背下来、说得含糊、逻辑跳步，明确点出来。
3. 发现理解漏洞后，用简单直接的话追问，一次只推进 1 到 2 个关键点。
4. 如果用户卡住，再给提示、类比、反例或拆解步骤，但仍然优先让用户继续复述。
5. 当用户已经基本说清楚时，帮他把内容重写成“像教给小白一样”的版本，语言尽量朴素。
6. 如果用户上传题目、图片、音频或文档，也要按费曼学习法来带学：先让用户说思路，再纠偏，再总结。
7. 语气要像耐心的老师，不要空泛鼓励，不要说教。
8. 公式、步骤、重点仍然要清楚；涉及数学公式时继续使用 LaTeX。

回答时优先采用这个节奏：
- 先简短判断用户当前理解到了哪一步
- 再提出追问或指出漏洞
- 必要时给少量提示
- 最后给一句“你可以试着这样重新讲一遍”"""


async def _prepare_current_parts(normalized_file_paths: list[str]) -> list[dict[str, object]]:
    async def prepare_single_file(file_path: str) -> tuple[str, dict[str, object] | None, HTTPException | None]:
        resolved_path = resolve_upload_path(file_path)
        display_name = parse_display_name_from_path(file_path)
        if not resolved_path or not resolved_path.exists():
            return display_name, None, HTTPException(
                status_code=400,
                detail=f"未找到附件 {display_name}，请重新上传后再试。",
            )

        file_kind = get_file_kind(display_name)
        try:
            prepared_file = await prepare_file_for_model(
                resolved_path,
                display_name=display_name,
                file_kind=file_kind,
            )
            return display_name, prepared_file, None
        except HTTPException as error:
            return display_name, None, error

    parts: list[dict[str, object]] = []
    results = await asyncio.gather(*(prepare_single_file(file_path) for file_path in normalized_file_paths))
    for file_path, (display_name, prepared_file, error) in zip(normalized_file_paths, results):
        if error:
            raise error

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


def _format_sse(event: str, data: dict[str, object]) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


async def stream_chat_with_gemini(request: ChatRequest) -> AsyncIterator[str]:
    ensure_client()
    normalized_file_paths = normalize_file_paths(request.file_paths)
    validate_files_for_model(normalized_file_paths)
    display_prompt = (request.display_prompt or "").strip() or request.prompt

    current_session_id = request.session_id
    if current_session_id and not session_exists(current_session_id):
        create_session(current_session_id)
    elif not current_session_id:
        current_session_id = create_session()

    save_message(
        current_session_id,
        "user",
        request.prompt,
        normalized_file_paths,
        display_content=display_prompt,
    )

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

    async def event_stream() -> AsyncIterator[str]:
        accumulated_text = ""
        try:
            yield _format_sse("session", {"session_id": current_session_id})
            print(f"正在调用 Gemini 模型 ({len(gemini_contents)} 轮对话上下文)...")
            stream = await generate_content_stream_with_retry(
                gemini_contents,
                system_instruction=_build_system_instruction(request.learning_mode),
            )
            async for chunk in stream:
                chunk_text = str(getattr(chunk, "text", "") or "")
                if not chunk_text:
                    continue
                accumulated_text += chunk_text
                yield _format_sse("delta", {"text": chunk_text})

            save_message(current_session_id, "model", accumulated_text)
            yield _format_sse("done", {"response": accumulated_text})
        except HTTPException as error:
            yield _format_sse("error", {"detail": error.detail})
        except Exception as error:
            translated_error = translate_gemini_error(error)
            yield _format_sse("error", {"detail": translated_error.detail})

    return event_stream()


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
                "content": row.get("display_content") or row["content"],
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
