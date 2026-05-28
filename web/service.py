from __future__ import annotations

import json
import os
import subprocess
from typing import Any, Callable, Protocol

import nats

from web.board import (
    DEFAULT_GOALS,
    DEFAULT_KERNELS,
    GOAL_FIELD_TO_IRI,
    GOAL_TYPE_IRI,
    TASK_FIELD_TO_IRI,
    TASK_TYPE_IRI,
    KernelColumn,
    board_snapshot_payload,
    build_goal_body,
    goal_record_from_mapping,
    iso_now,
    task_record_from_mapping,
    task_upsert_payload,
)


DEFAULT_BOARD_PROJECT = "goal_task_board"
DEFAULT_BOARD_KERNEL_TTL_PATH = "/examples/goal-task-board.kernel.ttl"
DEFAULT_BOARD_KERNEL_GRAPH_ID = "20"
DEFAULT_BOARD_IDENTITY_KEY_SUFFIX = "-identity-key"
DEFAULT_BOARD_NATS_URL = "nats://127.0.0.1:4223"
DEFAULT_NATS_SUBJECT = "broadcast.demo.display"


class BoardGateway(Protocol):
    def bootstrap(self) -> None: ...

    def ensure_goals(self, goals: list[dict[str, Any]]) -> None: ...

    def list_tasks(self) -> list[dict[str, Any]]: ...

    def list_goals(self) -> list[dict[str, Any]]: ...

    def create_task(self, payload: dict[str, Any]) -> dict[str, Any]: ...


class EventPublisher(Protocol):
    async def publish(self, payload: dict[str, Any]) -> None: ...


class BoardValidationError(ValueError):
    pass


class BoardService:
    def __init__(
        self,
        gateway: BoardGateway,
        publisher: EventPublisher,
        kernels: list[dict[str, Any]] | None = None,
        goals: list[dict[str, Any]] | None = None,
    ) -> None:
        self._gateway = gateway
        self._publisher = publisher
        self._kernels = [KernelColumn(**kernel) for kernel in (kernels or DEFAULT_KERNELS)]
        self._seed_goals = [goal_record_from_mapping(goal) for goal in (goals or DEFAULT_GOALS)]
        self._started = False

    async def startup(self) -> None:
        if self._started:
            return

        self._gateway.bootstrap()
        self._gateway.ensure_goals([goal.to_dict() for goal in self._seed_goals])
        self._started = True

    def board_snapshot(self) -> dict[str, Any]:
        tasks = [task_record_from_mapping(task) for task in self._gateway.list_tasks()]
        return board_snapshot_payload(self._kernels, tasks)

    def list_goals(self) -> list[dict[str, Any]]:
        goals = self._gateway.list_goals()
        if goals:
            return goals
        return [goal.to_dict() for goal in self._seed_goals]

    def list_kernels(self) -> list[dict[str, Any]]:
        return [kernel.to_dict() for kernel in self._kernels]

    async def create_task(self, payload: dict[str, Any]) -> dict[str, Any]:
        known_goal_ids = {goal["goal_id"] for goal in self.list_goals()}
        if payload["goal_id"] not in known_goal_ids:
            raise BoardValidationError(f"unknown goal_id: {payload['goal_id']}")

        known_kernel_ids = {kernel.kernel_id for kernel in self._kernels}
        if payload["target_kernel"] not in known_kernel_ids:
            raise BoardValidationError(f"unknown target_kernel: {payload['target_kernel']}")

        task = task_record_from_mapping(self._gateway.create_task(payload))
        warnings: list[str] = []

        try:
            await self._publisher.publish(task_upsert_payload(task))
        except Exception as exc:  # pragma: no cover - covered by tests via warning string
            warnings.append(f"task was sealed but live publish failed: {exc}")

        return {"task": task.to_dict(), "warnings": warnings}


def _compact_json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, separators=(",", ":"))


def _sql_quote(value: Any) -> str:
    return "'" + str(value).replace("'", "''") + "'"


class PsqlPgckGateway:
    def __init__(
        self,
        project: str | None = None,
        kernel_ttl_path: str | None = None,
        kernel_graph_id: str | None = None,
        sql_runner: Callable[[str], str] | None = None,
    ) -> None:
        self._project = project or os.getenv("PGCK_BOARD_PROJECT", DEFAULT_BOARD_PROJECT)
        self._kernel_ttl_path = kernel_ttl_path or os.getenv(
            "PGCK_BOARD_KERNEL_TTL_PATH",
            DEFAULT_BOARD_KERNEL_TTL_PATH,
        )
        self._kernel_graph_id = kernel_graph_id or os.getenv(
            "PGCK_BOARD_KERNEL_GRAPH_ID",
            DEFAULT_BOARD_KERNEL_GRAPH_ID,
        )
        self._identity_key = (
            os.getenv("PGCK_BOARD_IDENTITY_KEY")
            or os.getenv("PGCK_IDENTITY_KEY")
            or f"{self._project}{DEFAULT_BOARD_IDENTITY_KEY_SUFFIX}"
        )
        self._sql_runner = sql_runner or self._run_psql

    def bootstrap(self) -> None:
        self._sql_runner(
            "CREATE EXTENSION IF NOT EXISTS pgrdf CASCADE; "
            "CREATE EXTENSION IF NOT EXISTS pgck CASCADE; "
            "CALL ckp.bootstrap_kernel(); "
            "CALL ckp.boot(); "
            f"INSERT INTO ckp.config(k,v) VALUES ('kernel_graph_id',{_sql_quote(self._kernel_graph_id)}) "
            "ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v; "
            f"INSERT INTO ckp.config(k,v) VALUES ('identity_key',{_sql_quote(self._identity_key)}) "
            "ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v; "
            f"CALL ckp.load_kernel({_sql_quote(self._kernel_ttl_path)}, {_sql_quote(self._project)});"
        )

    def ensure_goals(self, goals: list[dict[str, Any]]) -> None:
        existing_ids = set(
            self._run_json(
                " ".join(
                    [
                        f"SELECT COALESCE(json_agg(body->>{_sql_quote(GOAL_FIELD_TO_IRI['goal_id'])}), '[]'::json)",
                        "FROM ckp.instances",
                        f"WHERE body->>'type' = {_sql_quote(GOAL_TYPE_IRI)};",
                    ]
                )
            )
            or []
        )

        for goal in goals:
            if goal["goal_id"] in existing_ids:
                continue

            body = build_goal_body(**goal)
            self._sql_runner(
                self._session_prefix()
                + f"SELECT ckp.seal({_sql_quote(goal['goal_id'])}, {_sql_quote(_compact_json(body))}::jsonb);"
            )

    def list_goals(self) -> list[dict[str, Any]]:
        return self._run_json(
            " ".join(
                [
                    "SELECT COALESCE(json_agg(row_to_json(goal_rows) ORDER BY goal_rows.goal_id), '[]'::json)",
                    "FROM (",
                    f"  SELECT body->>{_sql_quote(GOAL_FIELD_TO_IRI['goal_id'])} AS goal_id,",
                    f"         body->>{_sql_quote(GOAL_FIELD_TO_IRI['title'])} AS title,",
                    f"         COALESCE(body->>{_sql_quote(GOAL_FIELD_TO_IRI['created_at'])}, '') AS created_at,",
                    f"         COALESCE(body->>{_sql_quote(GOAL_FIELD_TO_IRI['detail'])}, '') AS detail,",
                    f"         COALESCE(body->>{_sql_quote(GOAL_FIELD_TO_IRI['created_by'])}, '') AS created_by",
                    "  FROM ckp.instances",
                    f"  WHERE body->>'type' = {_sql_quote(GOAL_TYPE_IRI)}",
                    ") AS goal_rows;",
                ]
            )
        ) or []

    def list_tasks(self) -> list[dict[str, Any]]:
        return self._run_json(
            self._session_prefix()
            + " ".join(
                [
                    "SELECT COALESCE(json_agg(row_to_json(task_rows) ORDER BY task_rows.queue_seq), '[]'::json)",
                    "FROM (",
                    f"  SELECT i.body->>{_sql_quote(TASK_FIELD_TO_IRI['task_id'])} AS task_id,",
                    f"         i.body->>{_sql_quote(TASK_FIELD_TO_IRI['title'])} AS title,",
                    f"         i.body->>{_sql_quote(TASK_FIELD_TO_IRI['part_of_goal'])} AS part_of_goal,",
                    f"         i.body->>{_sql_quote(TASK_FIELD_TO_IRI['target_kernel'])} AS target_kernel,",
                    f"         COALESCE(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['lifecycle_state'])}, 'pending') AS lifecycle_state,",
                    f"         COALESCE(NULLIF(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['priority'])}, '')::int, 0) AS priority,",
                    f"         COALESCE(NULLIF(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['queue_seq'])}, '')::int, 0) AS queue_seq,",
                    f"         COALESCE(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['created_at'])}, '') AS created_at,",
                    "         true AS shape_valid,",
                    "         true AS sealed,",
                    "         ckp.verify(i.id) AS verified,",
                    "         COALESCE((SELECT p.digest FROM ckp.proof AS p WHERE p.about = i.id ORDER BY p.id DESC LIMIT 1), '') AS proof_digest,",
                    f"         COALESCE(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['detail'])}, '') AS detail,",
                    f"         COALESCE(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['created_by'])}, '') AS created_by",
                    "  FROM ckp.instances AS i",
                    f"  WHERE i.body->>'type' = {_sql_quote(TASK_TYPE_IRI)}",
                    ") AS task_rows;",
                ]
            )
        ) or []

    def create_task(self, payload: dict[str, Any]) -> dict[str, Any]:
        created_at = payload.get("created_at") or iso_now()
        created_by = payload.get("created_by", "owner")
        title = str(payload["title"])
        goal_id = str(payload["goal_id"])
        target_kernel = str(payload["target_kernel"])
        detail = str(payload.get("detail", ""))
        priority = int(payload["priority"])
        created_by_body = (
            "'{}'::jsonb"
            if created_by in (None, "")
            else f"jsonb_build_object({_sql_quote(TASK_FIELD_TO_IRI['created_by'])}, {_sql_quote(created_by)})"
        )
        detail_body = (
            "'{}'::jsonb"
            if detail == ""
            else f"jsonb_build_object({_sql_quote(TASK_FIELD_TO_IRI['detail'])}, {_sql_quote(detail)})"
        )

        return self._run_json(
            self._session_prefix()
            + " ".join(
                [
                    "WITH lock AS (",
                    "  SELECT pg_advisory_xact_lock(",
                    "    hashtext('pgck:create_task'),",
                    "    hashtext(current_setting('ckp.project', true))",
                    "  )",
                    "), allocated AS (",
                    "  SELECT",
                    "    'FC-T-' || lpad((",
                    f"      COALESCE(MAX(COALESCE(NULLIF(regexp_replace(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['task_id'])}, '[^0-9]', '', 'g'), ''), '0')::int), 0) + 1",
                    "    )::text, 4, '0') AS task_id,",
                    f"    COALESCE(MAX(COALESCE(NULLIF(i.body->>{_sql_quote(TASK_FIELD_TO_IRI['queue_seq'])}, ''), '0')::int), 0) + 1 AS queue_seq",
                    "  FROM lock",
                    f"  LEFT JOIN ckp.instances AS i ON i.body->>'type' = {_sql_quote(TASK_TYPE_IRI)}",
                    "), body AS (",
                    "  SELECT",
                    "    allocated.task_id,",
                    "    allocated.queue_seq,",
                    "    jsonb_build_object(",
                    f"      'type', {_sql_quote(TASK_TYPE_IRI)},",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['task_id'])}, allocated.task_id,",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['title'])}, {_sql_quote(title)},",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['part_of_goal'])}, {_sql_quote(goal_id)},",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['target_kernel'])}, {_sql_quote(target_kernel)},",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['lifecycle_state'])}, 'pending',",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['priority'])}, {priority},",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['queue_seq'])}, allocated.queue_seq,",
                    f"      {_sql_quote(TASK_FIELD_TO_IRI['created_at'])}, {_sql_quote(created_at)}",
                    f"    ) || {created_by_body} || {detail_body} AS payload",
                    "  FROM allocated",
                    "), sealed AS (",
                    "  SELECT ckp.seal(body.task_id, body.payload) AS proof_digest,",
                    "         body.task_id,",
                    "         body.queue_seq",
                    "  FROM body",
                    "), verified AS (",
                    "  SELECT ckp.verify(sealed.task_id) AS verified FROM sealed",
                    ")",
                    "SELECT json_build_object(",
                    "  'task_id', sealed.task_id,",
                    f"  'title', {_sql_quote(title)},",
                    f"  'part_of_goal', {_sql_quote(goal_id)},",
                    f"  'target_kernel', {_sql_quote(target_kernel)},",
                    "  'lifecycle_state', 'pending',",
                    f"  'priority', {priority},",
                    "  'queue_seq', sealed.queue_seq,",
                    f"  'created_at', {_sql_quote(created_at)},",
                    "  'shape_valid', true,",
                    "  'sealed', true,",
                    "  'verified', (SELECT verified FROM verified),",
                    "  'proof_digest', sealed.proof_digest,",
                    f"  'detail', {_sql_quote(detail)},",
                    f"  'created_by', {_sql_quote(created_by)}",
                    ")",
                    "FROM sealed;",
                ]
            )
        )

    def _run_json(self, sql: str) -> Any:
        raw = self._sql_runner(sql).strip()
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            lines = [line for line in raw.splitlines() if line.strip()]
            return json.loads(lines[-1])

    def _session_prefix(self) -> str:
        return (
            f"SELECT set_config('ckp.project', {_sql_quote(self._project)}, false); "
            f"SELECT set_config('ckp.identity_key', {_sql_quote(self._identity_key)}, false); "
        )

    def _run_psql(self, sql: str) -> str:
        command = [
            os.getenv("PGCK_BOARD_PSQL_BIN", "psql"),
            "-X",
            "-qAt",
            "-v",
            "ON_ERROR_STOP=1",
            "-h",
            os.getenv("PGHOST", "127.0.0.1"),
            "-p",
            os.getenv("PGPORT") or os.getenv("POSTGRES_PORT", "5432"),
            "-U",
            os.getenv("PGUSER", "pgck"),
            "-d",
            os.getenv("PGDATABASE", "pgck"),
            "-c",
            sql,
        ]
        env = os.environ.copy()
        env.setdefault("PGPASSWORD", os.getenv("PGPASSWORD", "pgck"))
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "psql command failed")
        return result.stdout.strip()


class NatsEventPublisher:
    def __init__(
        self,
        url: str | None = None,
        subject: str | None = None,
        user: str | None = None,
        password: str | None = None,
    ) -> None:
        self._url = url or os.getenv("PGCK_BOARD_NATS_URL", DEFAULT_BOARD_NATS_URL)
        self._subject = subject or os.getenv("PGCK_BROWSER_NATS_SUBJECT", DEFAULT_NATS_SUBJECT)
        self._user = user or os.getenv("NATS_USER", "dev")
        self._password = password or os.getenv("NATS_PASSWORD", "devpass-change-me")

    async def publish(self, payload: dict[str, Any]) -> None:
        client = await nats.connect(
            servers=[self._url],
            user=self._user,
            password=self._password,
            connect_timeout=1,
        )
        try:
            await client.publish(self._subject, _compact_json(payload).encode("utf-8"))
            await client.flush(timeout=1)
        finally:
            await client.close()


def build_live_board_service() -> BoardService:
    return BoardService(gateway=PsqlPgckGateway(), publisher=NatsEventPublisher())
