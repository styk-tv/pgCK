from fastapi import APIRouter
from pydantic import BaseModel
from typing import List

router = APIRouter()

class Task(BaseModel):
    id: str
    title: str
    completed: bool = False

tasks_store = []

@router.get("/api/tasks")
async def list_tasks():
    return tasks_store

@router.post("/api/tasks")
async def create_task(task: Task):
    tasks_store.append(task)
    return {"status": "ok", "task": task}

@router.put("/api/tasks/{task_id}")
async def update_task(task_id: str, task: Task):
    for i, t in enumerate(tasks_store):
        if t["id"] == task_id:
            tasks_store[i] = task.dict()
            return {"status": "ok", "task": task}
    return {"status": "error", "message": "Task not found"}
