import asyncio
import inspect
from typing import Any, cast

from fastapi import HTTPException
from google import genai

from app.core.config import GEMINI_API_KEY, GEMINI_MODEL, SYSTEM_PROMPT

client = genai.Client(api_key=GEMINI_API_KEY) if GEMINI_API_KEY else None


if not GEMINI_API_KEY:
    print("❌警告:未能在环境变量中找到GEMINI_API_KEY。请检查.env文件是否存在且命名正确。")
elif client:
    print("✅Gemini API Client 初始化成功！已配置系统指令。")
    print(f"✅ 当前 Gemini 模型: {GEMINI_MODEL}")


def ensure_client() -> genai.Client:
    if not client:
        raise HTTPException(status_code=500, detail="客户端未初始化，请检查.env文件。")
    return client


def is_network_transport_error(error: Exception) -> bool:
    lowered = str(error).lower()
    markers = [
        "ssl",
        "eof occurred in violation of protocol",
        "connectionpool",
        "read timed out",
        "temporarily unavailable",
        "connection reset",
        "broken pipe",
        "max retries exceeded",
    ]
    return any(marker in lowered for marker in markers)


def translate_gemini_error(error: Exception) -> HTTPException:
    message = str(error)
    lowered = message.lower()

    if is_network_transport_error(error):
        return HTTPException(
            status_code=502,
            detail="连接服务时网络不稳定，刚刚请求被中断了。请稍后重试；如果持续出现，请检查当前网络、代理或 VPN 设置。",
        )

    if "api key" in lowered or "permission denied" in lowered or "unauthorized" in lowered:
        return HTTPException(status_code=500, detail="API Key 无效或权限不足，请检查后端配置。")

    if "unexpected model name format" in lowered or "invalid_argument" in lowered:
        return HTTPException(status_code=500, detail=f"当前模型 {GEMINI_MODEL} 配置不正确，请检查后端 GEMINI_MODEL。")

    if "not found" in lowered and "model" in lowered:
        return HTTPException(status_code=500, detail=f"当前模型 {GEMINI_MODEL} 不可用，请检查 GEMINI_MODEL 配置。")

    return HTTPException(status_code=500, detail="Gemini 服务暂时调用失败，请稍后再试。")


def get_gemini_file_name(uploaded_file: object) -> str | None:
    return cast(str | None, getattr(uploaded_file, "name", None))


def get_gemini_file_state(uploaded_file: object) -> str | None:
    state = getattr(uploaded_file, "state", None)
    if state is None:
        return None

    state_name = getattr(state, "name", None)
    if state_name:
        return str(state_name).split(".")[-1].upper()
    return str(state).split(".")[-1].upper()


async def wait_for_gemini_file_ready(uploaded_file: object, timeout_seconds: int = 180) -> object:
    current_client = ensure_client()
    file_name = get_gemini_file_name(uploaded_file)
    if not file_name:
        return uploaded_file

    latest_file = uploaded_file
    deadline = asyncio.get_running_loop().time() + timeout_seconds

    while asyncio.get_running_loop().time() < deadline:
        current_state = get_gemini_file_state(latest_file)
        if current_state in {None, "", "ACTIVE"}:
            return latest_file
        if current_state == "FAILED":
            raise RuntimeError(f"Gemini 文件处理失败：{file_name}")

        await asyncio.sleep(2)
        latest_file = await current_client.aio.files.get(name=file_name)

    raise RuntimeError(f"Gemini 文件处理超时：{file_name}")


async def upload_file_with_retry(file_path: str) -> object:
    current_client = ensure_client()
    last_error: Exception | None = None

    for attempt in range(3):
        try:
            uploaded_file = await current_client.aio.files.upload(path=file_path)
            return await wait_for_gemini_file_ready(uploaded_file)
        except Exception as error:
            last_error = error
            print(f"❌文件上传失败（第 {attempt + 1} 次）: {error}")
            if attempt < 2 and is_network_transport_error(error):
                await asyncio.sleep(1.5 * (attempt + 1))
                continue
            raise

    assert last_error is not None
    raise last_error


async def generate_content_with_retry(
    contents: list[dict[str, Any]],
    system_instruction: str | None = None,
) -> str:
    current_client = ensure_client()
    last_error: Exception | None = None

    for attempt in range(2):
        try:
            response = await current_client.aio.models.generate_content(
                model=GEMINI_MODEL,
                contents=contents,
                config={"system_instruction": system_instruction or SYSTEM_PROMPT},
            )
            return response.text
        except Exception as error:
            last_error = error
            print(f"❌生成失败（第 {attempt + 1} 次）: {error}")
            if attempt == 0:
                await asyncio.sleep(1)

    assert last_error is not None
    raise translate_gemini_error(last_error)


async def generate_content_stream_with_retry(
    contents: list[dict[str, Any]],
    system_instruction: str | None = None,
):
    current_client = ensure_client()
    last_error: Exception | None = None

    for attempt in range(2):
        try:
            stream_or_awaitable = current_client.aio.models.generate_content_stream(
                model=GEMINI_MODEL,
                contents=contents,
                config={"system_instruction": system_instruction or SYSTEM_PROMPT},
            )
            stream = (
                await stream_or_awaitable
                if inspect.isawaitable(stream_or_awaitable)
                else stream_or_awaitable
            )
            return stream
        except Exception as error:
            last_error = error
            print(f"❌流式生成失败（第 {attempt + 1} 次）: {error}")
            if attempt == 0:
                await asyncio.sleep(1)

    assert last_error is not None
    raise translate_gemini_error(last_error)
