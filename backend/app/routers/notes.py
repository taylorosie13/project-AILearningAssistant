from fastapi import APIRouter

from app.schemas.notes import NoteCreate, NoteGenerateRequest, NoteUpdate
from app.services.note_service import (
    create_manual_note,
    expand_card_to_note,
    extract_card_from_note,
    generate_note_from_source,
    get_note,
    get_notes,
    remove_note,
    update_existing_note,
)

router = APIRouter()


@router.get("/notes")
async def get_notes_endpoint():
    return get_notes()


@router.get("/notes/{note_id}")
async def get_note_endpoint(note_id: str):
    return get_note(note_id)


@router.post("/notes")
async def create_note_endpoint(note: NoteCreate):
    return create_manual_note(note)


@router.put("/notes/{note_id}")
async def update_note_endpoint(note_id: str, note: NoteUpdate):
    return update_existing_note(note_id, note)


@router.delete("/notes/{note_id}")
async def delete_note_endpoint(note_id: str):
    return remove_note(note_id)


@router.post("/notes/generate")
async def generate_note_endpoint(request: NoteGenerateRequest):
    return await generate_note_from_source(request)


@router.post("/notes/{note_id}/extract-card")
async def extract_card_from_note_endpoint(note_id: str):
    return extract_card_from_note(note_id)


@router.post("/cards/{card_id}/expand-note")
async def expand_card_to_note_endpoint(card_id: str):
    return expand_card_to_note(card_id)
