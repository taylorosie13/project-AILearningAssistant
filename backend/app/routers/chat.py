from fastapi import APIRouter, File, UploadFile
from fastapi.responses import StreamingResponse

from app.schemas.chat import ChatRequest
from app.services.chat_service import chat_with_gemini, stream_chat_with_gemini
from app.services.file_service import save_upload_file

router = APIRouter()


@router.post("/chat")
async def chat_endpoint(request: ChatRequest):
    return await chat_with_gemini(request)


@router.post("/chat/stream")
async def chat_stream_endpoint(request: ChatRequest):
    return StreamingResponse(
        await stream_chat_with_gemini(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.post("/upload/file")
async def upload_file_endpoint(file: UploadFile = File(...)):
    return await save_upload_file(file)
