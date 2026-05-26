from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
import os
from pathlib import Path

from .display import router as display_router
from .tasks import router as tasks_router

app = FastAPI(title="pgck-web", version="0.1.0")

# Include API routers
app.include_router(display_router, prefix="")
app.include_router(tasks_router, prefix="")

# Serve static files
static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

# Root route: serve display.html
@app.get("/")
async def root():
    display_html = static_dir / "display.html"
    if display_html.exists():
        return FileResponse(str(display_html), media_type="text/html")
    return {"message": "Display demo - display.html not found"}

# Tasks route: serve tasks.html
@app.get("/tasks.html")
async def tasks_page():
    tasks_html = static_dir / "tasks.html"
    if tasks_html.exists():
        return FileResponse(str(tasks_html), media_type="text/html")
    return {"message": "Tasks board - tasks.html not found"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
