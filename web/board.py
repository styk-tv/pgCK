from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Any, Mapping, Sequence


CORE_NS = "https://conceptkernel.org/ontology/v3.7/"
GOAL_TYPE_IRI = f"{CORE_NS}Goal"
TASK_TYPE_IRI = f"{CORE_NS}Task"

GOAL_FIELD_TO_IRI = {
    "goal_id": f"{CORE_NS}goal_id",
    "title": f"{CORE_NS}title",
    "created_at": f"{CORE_NS}created_at",
    "created_by": f"{CORE_NS}created_by",
    "detail": f"{CORE_NS}detail",
}

TASK_FIELD_TO_IRI = {
    "task_id": f"{CORE_NS}task_id",
    "title": f"{CORE_NS}title",
    "part_of_goal": f"{CORE_NS}part_of_goal",
    "target_kernel": f"{CORE_NS}target_kernel",
    "lifecycle_state": f"{CORE_NS}lifecycle_state",
    "priority": f"{CORE_NS}priority",
    "queue_seq": f"{CORE_NS}queue_seq",
    "created_at": f"{CORE_NS}created_at",
    "created_by": f"{CORE_NS}created_by",
    "detail": f"{CORE_NS}detail",
}

IRI_TO_SHORT_FIELD = {
    **{iri: field_name for field_name, iri in GOAL_FIELD_TO_IRI.items()},
    **{iri: field_name for field_name, iri in TASK_FIELD_TO_IRI.items()},
}

DEFAULT_KERNELS = [
    {
        "kernel_id": "CK.Task",
        "title": "Task Kernel",
        "icon": "assignment",
        "color": "#22c55e",
        "launch_url": "https://task.localhost",
        "visible": True,
    },
    {
        "kernel_id": "CK.Goal",
        "title": "Goal Kernel",
        "icon": "flag",
        "color": "#38bdf8",
        "launch_url": "https://goal.localhost",
        "visible": True,
    },
    {
        "kernel_id": "CK.ComplianceCheck",
        "title": "Compliance",
        "icon": "verified",
        "color": "#f59e0b",
        "launch_url": "https://compliance.localhost",
        "visible": True,
    },
    {
        "kernel_id": "LOCAL.ClaudeCode",
        "title": "Claude Code",
        "icon": "terminal",
        "color": "#f97316",
        "launch_url": "https://claudecode.localhost",
        "visible": True,
    },
]

DEFAULT_GOALS = [
    {
        "goal_id": "FC-G-0001",
        "title": "Fortify the fleet",
        "detail": "Stabilise the kernel board slice and prove the governed path.",
        "created_at": "2026-05-20T20:00:00Z",
        "created_by": "seed",
    },
    {
        "goal_id": "FC-G-0002",
        "title": "Tighten operator feedback",
        "detail": "Keep the owner console obvious and failure states inspectable.",
        "created_at": "2026-05-20T20:05:00Z",
        "created_by": "seed",
    },
]


@dataclass(slots=True)
class KernelColumn:
    kernel_id: str
    title: str
    icon: str
    color: str
    launch_url: str
    visible: bool = True

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class GoalRecord:
    goal_id: str
    title: str
    created_at: str
    detail: str = ""
    created_by: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class TaskRecord:
    task_id: str
    title: str
    part_of_goal: str
    target_kernel: str
    lifecycle_state: str
    priority: int
    queue_seq: int
    created_at: str
    shape_valid: bool
    sealed: bool
    verified: bool
    proof_digest: str
    detail: str = ""
    created_by: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _filter_empty_fields(payload: Mapping[str, Any], field_map: Mapping[str, str]) -> dict[str, Any]:
    body: dict[str, Any] = {}
    for field_name, iri in field_map.items():
        value = payload.get(field_name)
        if value in (None, ""):
            continue
        body[iri] = value
    return body


def build_goal_body(**goal: Any) -> dict[str, Any]:
    body = {"type": GOAL_TYPE_IRI}
    body.update(_filter_empty_fields(goal, GOAL_FIELD_TO_IRI))
    return body


def build_task_body(**task: Any) -> dict[str, Any]:
    body = {"type": TASK_TYPE_IRI}
    body.update(_filter_empty_fields(task, TASK_FIELD_TO_IRI))
    return body


def sort_tasks(tasks: Sequence[TaskRecord]) -> list[TaskRecord]:
    return sorted(tasks, key=lambda task: (-task.priority, task.queue_seq, task.task_id))


def _kernel_to_dict(kernel: KernelColumn | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(kernel, KernelColumn):
        return kernel.to_dict()
    return dict(kernel)


def _task_to_dict(task: TaskRecord | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(task, TaskRecord):
        return task.to_dict()
    return dict(task)


def board_snapshot_payload(
    kernels: Sequence[KernelColumn | Mapping[str, Any]],
    tasks: Sequence[TaskRecord | Mapping[str, Any]],
) -> dict[str, Any]:
    task_records = [task if isinstance(task, TaskRecord) else task_record_from_mapping(task) for task in tasks]
    return {
        "kind": "board_snapshot",
        "board": {
            "kernels": [_kernel_to_dict(kernel) for kernel in kernels],
            "tasks": [task.to_dict() for task in sort_tasks(task_records)],
        },
    }


def task_upsert_payload(task: TaskRecord | Mapping[str, Any]) -> dict[str, Any]:
    return {"kind": "task_upsert", "task": _task_to_dict(task)}


def goal_record_from_mapping(payload: Mapping[str, Any]) -> GoalRecord:
    return GoalRecord(
        goal_id=str(payload["goal_id"]),
        title=str(payload["title"]),
        created_at=str(payload["created_at"]),
        detail=str(payload.get("detail", "")),
        created_by=str(payload.get("created_by", "")),
    )


def task_record_from_mapping(payload: Mapping[str, Any]) -> TaskRecord:
    return TaskRecord(
        task_id=str(payload["task_id"]),
        title=str(payload["title"]),
        part_of_goal=str(payload["part_of_goal"]),
        target_kernel=str(payload["target_kernel"]),
        lifecycle_state=str(payload["lifecycle_state"]),
        priority=int(payload.get("priority", 0)),
        queue_seq=int(payload.get("queue_seq", 0)),
        created_at=str(payload["created_at"]),
        shape_valid=bool(payload.get("shape_valid", True)),
        sealed=bool(payload.get("sealed", True)),
        verified=bool(payload.get("verified", False)),
        proof_digest=str(payload.get("proof_digest", "")),
        detail=str(payload.get("detail", "")),
        created_by=str(payload.get("created_by", "")),
    )
