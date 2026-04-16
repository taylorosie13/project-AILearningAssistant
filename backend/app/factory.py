from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.core.config import UPLOADS_DIR
from app.core.database import init_db
from app.routers.cards import router as cards_router
from app.routers.chat import router as chat_router
from app.routers.maintenance import router as maintenance_router
from app.routers.notes import router as notes_router
from app.routers.sessions import router as sessions_router
from app.services.file_service import run_temp_file_cleanup


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    cleanup_result = run_temp_file_cleanup()
    print(
        "🧹 启动清理完成: "
        f"{cleanup_result['removed_temp_dirs']} 个临时目录, "
        f"{cleanup_result['removed_orphan_uploads']} 个孤儿上传文件"
    )
    yield


def create_app() -> FastAPI:
    app = FastAPI(title="Multimodal Learning Assistant API", lifespan=lifespan)
    app.mount("/uploads", StaticFiles(directory=str(UPLOADS_DIR)), name="uploads")

    @app.get("/")
    async def root():
        return {"message": "服务已成功启动。"}

    app.include_router(chat_router)
    app.include_router(sessions_router)
    app.include_router(cards_router)
    app.include_router(notes_router)
    app.include_router(maintenance_router)
    return app
