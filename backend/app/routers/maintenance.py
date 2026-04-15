from fastapi import APIRouter

from app.services.file_service import run_temp_file_cleanup

router = APIRouter()


@router.post("/maintenance/cleanup-temp-files")
async def cleanup_temp_files_endpoint():
    cleanup_result = run_temp_file_cleanup()
    return {"message": "临时文件清理完成", **cleanup_result}
