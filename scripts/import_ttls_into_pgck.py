#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path
from urllib.parse import quote


def gather_ttls(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*.ttl")
        if "__pycache__" not in path.parts
    )


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def dollar_quote(value: str) -> str:
    for index in range(1000):
        tag = f"$ck{index}$"
        if tag not in value:
            return f"{tag}{value}{tag}"
    raise RuntimeError("could not find a safe dollar-quote tag")


def graph_iri(root: Path, ttl_path: Path, namespace: str) -> str:
    rel = ttl_path.relative_to(root).as_posix()
    encoded = quote(rel, safe="/._-")
    return f"urn:pgck:{namespace}:{encoded}"


def build_sql(source_roots: list[Path], start_graph_id: int) -> str:
    lines = [
        "SET client_min_messages = warning;",
        "CREATE EXTENSION IF NOT EXISTS pgrdf CASCADE;",
        "CREATE EXTENSION IF NOT EXISTS pgck CASCADE;",
    ]

    graph_id = start_graph_id
    for root in source_roots:
        namespace = root.name
        for ttl_path in gather_ttls(root):
            ttl = ttl_path.read_text(encoding="utf-8")
            iri = graph_iri(root, ttl_path, namespace)
            base_iri = f"{iri}#"
            lines.extend(
                [
                    f"SELECT pgrdf.add_graph({graph_id}, {sql_literal(iri)});",
                    f"SELECT pgrdf.clear_graph({graph_id});",
                    f"SELECT pgrdf.parse_turtle({dollar_quote(ttl)}, {graph_id}, {sql_literal(base_iri)});",
                    f"SELECT pgrdf.materialize({graph_id});",
                ]
            )
            graph_id += 1

    return "\n".join(lines) + "\n"


def run_psql(sql: str, compose_project: str, user: str, database: str) -> None:
    env = os.environ.copy()
    command = [
        "docker",
        "compose",
        "-f",
        "compose/compose.yml",
        "-p",
        compose_project,
        "exec",
        "-T",
        "postgres",
        "psql",
        "-U",
        user,
        "-d",
        database,
        "-v",
        "ON_ERROR_STOP=1",
    ]
    subprocess.run(
        command,
        input=sql,
        text=True,
        check=True,
        env=env,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Load Turtle files into pgRDF graphs inside the local pgCK compose stack."
    )
    parser.add_argument("paths", nargs="+", help="One or more directories containing .ttl files")
    parser.add_argument("--start-graph-id", type=int, default=1000)
    parser.add_argument("--compose-project", default="pgck")
    parser.add_argument("--db-user", default="pgck")
    parser.add_argument("--db-name", default="pgck")
    parser.add_argument(
        "--print-sql",
        action="store_true",
        help="Print the generated SQL instead of executing it",
    )
    args = parser.parse_args()

    source_roots = [Path(path).expanduser().resolve() for path in args.paths]
    for root in source_roots:
        if not root.exists():
            parser.error(f"path does not exist: {root}")

    sql = build_sql(source_roots, args.start_graph_id)
    if args.print_sql:
        print(sql, end="")
        return 0

    run_psql(sql, args.compose_project, args.db_user, args.db_name)
    print(f"imported ttl files from {len(source_roots)} source roots")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
