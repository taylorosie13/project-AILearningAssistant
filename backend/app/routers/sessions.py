from fastapi import APIRouter

from app.services.chat_service import delete_session_with_files, get_session_messages, get_sessions

router = APIRouter()


@router.get("/sessions")
async def get_sessions_endpoint():
    return get_sessions()


@router.get("/sessions/{session_id}/messages")
async def get_session_messages_endpoint(session_id: str):
    return get_session_messages(session_id)


@router.delete("/sessions/{session_id}")
async def delete_session_endpoint(session_id: str):
    return await delete_session_with_files(session_id)
