import re
from dataclasses import dataclass

from fastapi import HTTPException

from app.repositories.card_repository import create_card, fetch_card_by_id
from app.repositories.note_repository import (
    create_note,
    delete_note,
    fetch_note_by_id,
    fetch_notes,
    update_note,
)
from app.repositories.session_repository import fetch_all_session_messages
from app.schemas.notes import NoteCreate, NoteGenerateRequest, NoteUpdate
from app.services.card_service import deserialize_tags, normalize_tags, serialize_tags
from app.services.file_service import (
    build_multimodal_file_prompt,
    get_file_kind,
    normalize_file_paths,
    parse_display_name_from_path,
    prepare_file_for_model,
    resolve_upload_path,
    validate_files_for_model,
)
from app.services.gemini_service import generate_content_with_retry

NOTE_GENERATION_PROMPT = """你是学习助手里的笔记整理专家。请把给定材料整理成一份适合长期保存的 Markdown 笔记。

输出时严格遵循下面结构：

# 标题
一句简洁明确的标题

## 摘要
用 2 到 4 句话概括核心内容

## 正文
使用 Markdown 标题、列表、引用和代码块组织内容。遇到公式时继续使用标准 LaTeX。

## 关键知识点
- 列出 3 到 6 条关键点

## 待复习问题
- 列出 2 到 5 个复习问题

要求：
1. 不要输出 JSON。
2. 不要省略任何一级或二级标题。
3. 标题不要带序号。
4. 正文尽量清晰、有层次，适合之后继续编辑。
"""


@dataclass
class ParsedNote:
    title: str
    summary: str
    content_markdown: str


def _clean_text(value: str | None) -> str:
    return (value or "").strip()


def _normalize_category(value: str | None) -> str | None:
    cleaned = _clean_text(value)
    return cleaned or None


def _serialize_note_row(note: dict[str, object]) -> dict[str, object]:
    serialized = dict(note)
    serialized["tags"] = deserialize_tags(note.get("tags"))
    return serialized


def _parse_markdown_note(markdown: str, fallback_title: str | None = None) -> ParsedNote:
    cleaned_markdown = markdown.strip()
    if not cleaned_markdown:
        raise HTTPException(status_code=500, detail="生成出来的笔记是空的，请稍后再试。")

    title_match = re.search(r"^#\s+(.+)$", cleaned_markdown, re.MULTILINE)
    title = _clean_text(title_match.group(1) if title_match else fallback_title) or "未命名笔记"

    summary_match = re.search(
        r"^##\s+摘要\s*$([\s\S]*?)(?=^##\s+|\Z)",
        cleaned_markdown,
        re.MULTILINE,
    )
    summary = _clean_text(summary_match.group(1) if summary_match else "")

    return ParsedNote(title=title, summary=summary, content_markdown=cleaned_markdown)


def _build_session_source_text(session_id: str) -> str:
    rows = fetch_all_session_messages(session_id)
    if not rows:
        raise HTTPException(status_code=404, detail="没有找到可整理的会话内容。")

    lines: list[str] = []
    for row in rows:
        role = "用户" if row["role"] == "user" else "AI"
        content = _clean_text(str(row.get("content") or ""))
        if not content:
            continue
        lines.append(f"{role}：{content}")

    if not lines:
        raise HTTPException(status_code=400, detail="当前会话没有可整理的文字内容。")
    return "\n\n".join(lines)


async def _generate_note_markdown(prompt_text: str, file_paths: list[str] | None = None) -> str:
    parts: list[dict[str, object]] = [{"text": prompt_text}]

    for file_path in file_paths or []:
        resolved_path = resolve_upload_path(file_path)
        display_name = parse_display_name_from_path(file_path)
        if not resolved_path or not resolved_path.exists():
            raise HTTPException(status_code=400, detail=f"未找到附件《{display_name}》，请重新上传后再试。")

        file_kind = get_file_kind(display_name)
        prepared_file = await prepare_file_for_model(
            resolved_path,
            display_name=display_name,
            file_kind=file_kind,
        )
        file_prompt = build_multimodal_file_prompt(display_name, file_kind)
        if file_prompt:
            parts.append({"text": file_prompt})

        if prepared_file.get("mode") == "text_inline":
            text_content = str(prepared_file.get("text_content", "")).strip()
            if text_content:
                parts.append({"text": f"附件《{display_name}》的内容如下：\n\n{text_content}"})
            continue

        mime_type = str(prepared_file.get("mime_type", "")).strip()
        file_uri = str(prepared_file.get("file_uri", "")).strip()
        if mime_type and file_uri:
            parts.append({"file_data": {"mime_type": mime_type, "file_uri": file_uri}})

    contents = [{"role": "user", "parts": parts}]
    return await generate_content_with_retry(contents, system_instruction=NOTE_GENERATION_PROMPT)


def get_notes() -> list[dict[str, object]]:
    return [_serialize_note_row(note) for note in fetch_notes()]


def get_note(note_id: str) -> dict[str, object]:
    note = fetch_note_by_id(note_id)
    if not note:
        raise HTTPException(status_code=404, detail="未找到这条笔记。")
    return _serialize_note_row(note)


def create_manual_note(note: NoteCreate) -> dict[str, object]:
    title = _clean_text(note.title)
    content_markdown = _clean_text(note.content_markdown)
    summary = _clean_text(note.summary) or None
    if not title or not content_markdown:
        raise HTTPException(status_code=400, detail="笔记标题和正文都不能为空。")

    note_id = create_note(
        title=title,
        content_markdown=content_markdown,
        summary=summary,
        category=_normalize_category(note.category),
        tags=serialize_tags(note.tags),
        source_type=_clean_text(note.source_type) or "manual",
        source_ref_id=_clean_text(note.source_ref_id) or None,
        source_title=_clean_text(note.source_title) or None,
    )
    return {"message": "笔记创建成功", "note_id": note_id}


def update_existing_note(note_id: str, note: NoteUpdate) -> dict[str, object]:
    updated = update_note(
        note_id=note_id,
        title=_clean_text(note.title),
        content_markdown=_clean_text(note.content_markdown),
        summary=_clean_text(note.summary) or None,
        category=_normalize_category(note.category),
        tags=serialize_tags(note.tags),
    )
    if not updated:
        raise HTTPException(status_code=404, detail="未找到要更新的笔记。")
    return {"message": "笔记更新成功", "note_id": note_id}


def remove_note(note_id: str) -> dict[str, str]:
    delete_note(note_id)
    return {"message": "笔记删除成功"}


async def generate_note_from_source(request: NoteGenerateRequest) -> dict[str, object]:
    source_type = _clean_text(request.source_type).lower()
    if not source_type:
        raise HTTPException(status_code=400, detail="缺少笔记来源类型。")

    normalized_file_paths = normalize_file_paths(request.file_paths)
    if normalized_file_paths:
        validate_files_for_model(normalized_file_paths)

    if source_type == "session":
        if not request.session_id:
            raise HTTPException(status_code=400, detail="会话来源缺少 session_id。")
        source_text = _build_session_source_text(request.session_id)
        source_ref_id = request.session_id
    else:
        source_text = _clean_text(request.source_text)
        source_ref_id = _clean_text(request.source_ref_id) or None

    if not source_text and not normalized_file_paths:
        raise HTTPException(status_code=400, detail="没有拿到可整理的内容。")

    source_title = _clean_text(request.source_title) or None
    title_hint = _clean_text(request.title_hint)
    prompt_parts = []
    if source_title:
        prompt_parts.append(f"来源标题：{source_title}")
    if title_hint:
        prompt_parts.append(f"标题建议：{title_hint}")
    if source_text:
        prompt_parts.append("请根据下面材料整理笔记：\n\n" + source_text)
    if normalized_file_paths:
        prompt_parts.append("另外还附带了相关附件，请结合附件一起整理。")

    markdown = await _generate_note_markdown("\n\n".join(prompt_parts), normalized_file_paths)
    parsed = _parse_markdown_note(markdown, fallback_title=title_hint or source_title)

    note_id = create_note(
        title=parsed.title,
        content_markdown=parsed.content_markdown,
        summary=parsed.summary or None,
        category=_normalize_category(request.category),
        tags=serialize_tags(request.tags),
        source_type=source_type,
        source_ref_id=source_ref_id,
        source_title=source_title,
    )
    return {
        "message": "笔记生成成功",
        "note_id": note_id,
        "note": get_note(note_id),
    }


def extract_card_from_note(note_id: str) -> dict[str, object]:
    note = get_note(note_id)
    card_id = create_card(
        title=str(note["title"]),
        content=str(note["summary"] or note["content_markdown"]),
        category=note.get("category") if isinstance(note.get("category"), str) else None,
        tags=serialize_tags(note.get("tags") if isinstance(note.get("tags"), list) else []),
        source_session_id=None,
    )
    return {"message": "已从笔记提炼出知识卡片", "card_id": card_id}


def expand_card_to_note(card_id: str) -> dict[str, object]:
    card = fetch_card_by_id(card_id)
    if not card:
        raise HTTPException(status_code=404, detail="没有找到要扩展的知识卡片。")

    parsed_tags = deserialize_tags(card.get("tags"))
    note_id = create_note(
        title=_clean_text(str(card.get("title") or "")) or "未命名笔记",
        content_markdown=_clean_text(str(card.get("content") or "")),
        summary=_clean_text(str(card.get("content") or "")) or None,
        category=_normalize_category(card.get("category") if isinstance(card.get("category"), str) else None),
        tags=serialize_tags(parsed_tags),
        source_type="card",
        source_ref_id=card_id,
        source_title=_clean_text(str(card.get("title") or "")) or None,
    )
    return {"message": "卡片已扩展成笔记", "note_id": note_id, "note": get_note(note_id)}
