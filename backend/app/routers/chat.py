from fastapi import APIRouter, File, UploadFile

from app.schemas.chat import ChatRequest
from app.services.chat_service import chat_with_gemini
from app.services.file_service import save_upload_file

router = APIRouter()


@router.post("/chat")
async def chat_endpoint(request: ChatRequest):
    return await chat_with_gemini(request)


@router.post("/upload/file")
async def upload_file_endpoint(file: UploadFile = File(...)):
    return await save_upload_file(file)
