from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()

class DisplayConfig(BaseModel):
    theme: str = "light"
    message: str = "Welcome"
    audio_url: str | None = None

@router.get("/api/display/config")
async def get_display_config():
    return {"theme": "light", "message": "Welcome to pgCK", "audio_url": None}

@router.post("/api/display/config")
async def set_display_config(config: DisplayConfig):
    return {"status": "ok", "config": config}
