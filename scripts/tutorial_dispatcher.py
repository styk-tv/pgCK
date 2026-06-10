#!/usr/bin/env python3
"""
tutorial_dispatcher.py — DEV-ONLY bridge: browser NATS actions -> ckp.seal/verify.

NOT a prod slice (no Python ships in the container). A hand prototype of the
future Rust CKA-4 dispatcher. Subscribes  input.kernel.pgCK.action.>  on the
bundled NATS and maps verbs to the proven governed SQL path. Replies land on
result.kernel.pgCK.action.<verb> keyed by the request's `req`.

Verbs: participant.join · kernel.create · task.create · task.update ·
       snapshot.board · provenance · instance.verify · affordances

Run:
  NATS_URL=nats://127.0.0.1:14222 PGPORT=15432 PGPASSWORD=pgcklocal \
    python scripts/tutorial_dispatcher.py
"""
import asyncio
import json
import os
import re
import subprocess
import time

from nats.aio.client import Client as NATS

NS = "https://conceptkernel.org/ontology/v3.7/"
RL = "http://www.w3.org/2000/01/rdf-schema#label"
TASK_TYPE, GOAL_TYPE = NS + "Task", NS + "Goal"
PROJECT = os.getenv("PGCK_BOARD_PROJECT", "demo")
IDENTITY = os.getenv("PGCK_IDENTITY_KEY", "pgck-localhost")
PSQL = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
        "-h", os.getenv("PGHOST", "127.0.0.1"), "-p", os.getenv("PGPORT", "15432"),
        "-U", os.getenv("PGUSER", "postgres"), "-d", os.getenv("PGDATABASE", "postgres")]


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", (s or "").strip().lower()).strip("-") or "anon"


def sql(q):
    p = subprocess.run(PSQL, input=q, text=True, capture_output=True, env=dict(os.environ))
    return (p.returncode == 0, p.stdout.strip(), p.stderr.strip())


def err1(stderr):
    for ln in stderr.splitlines():
        if "ERROR:" in ln:
            return ln.split("ERROR:", 1)[1].strip()
    return (stderr.splitlines() or ["unknown error"])[0]


def k(key, val):  # one "iri": "value" json pair, value json-escaped
    return json.dumps(key) + ":" + json.dumps(str(val))


def seal(iid, pairs, participant_sub=None):
    parts = list(pairs)
    if participant_sub:
        parts.append('"participant":' + json.dumps({"sub": participant_sub}))
    body = "{" + ",".join(parts) + "}"
    q = (f"DO $c$ BEGIN PERFORM set_config('ckp.project','{PROJECT}',false); "
         f"PERFORM set_config('ckp.identity_key','{IDENTITY}',false); END $c$;\n"
         f"SELECT ckp.seal('{iid}', $b${body}$b$::jsonb);")
    ok, out, e = sql(q)
    return (True, out) if ok else (False, err1(e))


def now_iso():
    # Date.now-free env: caller passes timestamps; here we read DB clock.
    ok, out, _ = sql("SELECT to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"');")
    return out if ok else "1970-01-01T00:00:00Z"


# ---- verb handlers --------------------------------------------------------

def h_participant_join(d):
    name = d.get("name") or "anon"
    return {"ok": True, "urn": "urn:ckp:participant:" + slug(name), "sub": name}


def h_kernel_create(d):
    name = (d.get("name") or "").strip()
    if not name:
        return {"ok": False, "error": "kernel name required"}
    iid = "backlog:" + name
    ok, res = seal(iid, [k("type", GOAL_TYPE), k(NS + "goal_id", iid),
                         k(RL, name), k(NS + "title", name), k(NS + "created_at", now_iso())])
    return {"ok": ok, "kernel": name, "id": iid, "proof_digest": res} if ok \
        else {"ok": False, "error": res}


def h_task_create(d):
    t = d.get("task") or {}
    kernel = (t.get("target_kernel") or "").strip()
    title = (t.get("title") or "").strip()
    if not kernel or not title:
        return {"ok": False, "error": "kernel and title required"}
    ok, mx, _ = sql(f"SELECT COALESCE(MAX((body->>'{NS}queue_seq')::int),0)+1 "
                    f"FROM ckp.instances WHERE body->>'{NS}target_kernel'='{kernel}' "
                    f"AND body->>'type'='{TASK_TYPE}';")
    qseq = mx if ok and mx else "1"
    tid = "task-" + str(time.time_ns())
    sub = d.get("sub")
    pairs = [k("type", TASK_TYPE), k(NS + "task_id", tid), k(NS + "title", title),
             k(NS + "part_of_goal", "backlog:" + kernel), k(NS + "target_kernel", kernel),
             k(NS + "lifecycle_state", t.get("lifecycle_state") or "planned"),
             k(NS + "priority", t.get("priority") or "5"), k(NS + "queue_seq", qseq),
             k(NS + "created_at", now_iso())]
    if sub:
        pairs.append(k(NS + "created_by", "urn:ckp:participant:" + slug(sub)))
    ok, res = seal(tid, pairs, participant_sub=sub)
    if not ok:
        return {"ok": False, "error": res}
    _, ver, _ = sql(f"SELECT ckp.verify('{tid}');")
    return {"ok": True, "id": tid, "proof_digest": res, "verified": ver.strip() == "t"}


def h_task_update(d):
    tid = str(d.get("id") or "")
    ok, body, _ = sql(f"SELECT body::text FROM ckp.instances WHERE id='{tid}';")
    if not ok or not body:
        return {"ok": False, "error": "instance not found"}
    cur = json.loads(body)
    for f in ("lifecycle_state", "priority"):
        if d.get(f) is not None:
            cur[NS + f] = str(d[f])
    cur.pop("participant", None)
    pairs = [k(key, val) for key, val in cur.items()]
    ok, res = seal(tid, pairs)
    if not ok:
        return {"ok": False, "error": res}
    _, ver, _ = sql(f"SELECT ckp.verify('{tid}');")
    return {"ok": True, "id": tid, "proof_digest": res, "verified": ver.strip() == "t"}


def h_snapshot(d):
    q = (
        "SELECT json_build_object("
        "'kernels',(SELECT COALESCE(json_agg(json_build_object("
        f"'name',COALESCE(body->>'{RL}',regexp_replace(id,'^backlog:','')),'id',id) ORDER BY id),'[]') "
        f"FROM ckp.instances WHERE body->>'type'='{GOAL_TYPE}' AND id LIKE 'backlog:%'),"
        "'tasks',(SELECT COALESCE(json_agg(json_build_object("
        "'id',i.id,"
        f"'title',i.body->>'{NS}title',"
        f"'target_kernel',i.body->>'{NS}target_kernel',"
        f"'part_of_goal',i.body->>'{NS}part_of_goal',"
        f"'lifecycle_state',i.body->>'{NS}lifecycle_state',"
        f"'priority',i.body->>'{NS}priority',"
        f"'queue_seq',i.body->>'{NS}queue_seq',"
        f"'created_by',COALESCE(i.body->>'{NS}created_by',i.body->>'https://conceptkernel.org/ontology/v3.8/core#participant'),"
        "'proof_digest',(SELECT digest FROM ckp.proof p WHERE p.about=i.id ORDER BY p.id DESC LIMIT 1),"
        "'verified',ckp.verify(i.id)"
        f") ORDER BY i.id),'[]') FROM ckp.instances i WHERE i.body->>'type'='{TASK_TYPE}'));"
    )
    ok, out, e = sql(q)
    if not ok:
        return {"ok": False, "error": err1(e)}
    try:
        return {"ok": True, **json.loads(out)}
    except Exception:
        return {"ok": True, "kernels": [], "tasks": []}


def h_provenance(d):
    tid = str(d.get("id") or "")
    ok, out, e = sql(
        "SELECT json_build_object("
        f"'id','{tid}',"
        f"'verified',ckp.verify('{tid}'),"
        f"'body',(SELECT body FROM ckp.instances WHERE id='{tid}'),"
        f"'proof',(SELECT json_build_object('digest',digest,'method',method,'verified_at',verified_at) "
        f"FROM ckp.proof WHERE about='{tid}' ORDER BY id DESC LIMIT 1),"
        f"'ledger',(SELECT COALESCE(json_agg(json_build_object('seq',seq,'prev_seq',prev_seq,"
        f"'body_sha256',body_sha256,'ts',ts) ORDER BY seq),'[]') FROM ckp.ledger WHERE instance_id='{tid}'));")
    if not ok:
        return {"ok": False, "error": err1(e)}
    try:
        return {"ok": True, **json.loads(out)}
    except Exception:
        return {"ok": False, "error": "parse"}


def h_kernel_detail(d):
    kernel = (d.get("kernel") or "").strip()
    if not kernel:
        return {"ok": False, "error": "kernel required"}
    esc = kernel.replace("'", "''")
    kslug = slug(kernel)
    q = (
        "WITH t AS (SELECT i.id, i.body, i.ts_created, "
        "(SELECT digest FROM ckp.proof p WHERE p.about=i.id ORDER BY p.id DESC LIMIT 1) AS digest, "
        "ckp.verify(i.id) AS verified FROM ckp.instances i "
        f"WHERE i.body->>'{NS}target_kernel'='{esc}' AND i.body->>'type'='{TASK_TYPE}') "
        "SELECT json_build_object("
        f"'kernel','{esc}','urn','ckp://Kernel#{kslug}',"
        "'tasks',(SELECT COALESCE(json_agg(json_build_object("
        "'id',t.id,'body',t.body,'proof_digest',t.digest,'verified',t.verified,'ts',t.ts_created,"
        "'ledger',(SELECT COALESCE(json_agg(json_build_object('seq',seq,'prev_seq',prev_seq,"
        "'body_sha256',body_sha256,'sig',sig) ORDER BY seq),'[]') FROM ckp.ledger WHERE instance_id=t.id)"
        ") ORDER BY t.id),'[]') FROM t),"
        "'triples',(SELECT COALESCE(json_agg(json_build_object('s',j.s,'p',j.p,'o',j.o)),'[]') "
        "FROM (SELECT DISTINCT k.j->>'s' s,k.j->>'p' p,k.j->>'o' o FROM pgrdf.sparql($q$ "
        "PREFIX core:<https://conceptkernel.org/ontology/v3.8/core#> "
        f"SELECT ?s ?p ?o WHERE {{ GRAPH ?g {{ ?s core:target_kernel <ckp://Kernel#{kslug}> . ?s ?p ?o }} }} "
        "$q$) AS k(j)) AS j));"
    )
    ok, out, e = sql(q)
    if not ok:
        return {"ok": False, "error": err1(e)}
    try:
        return {"ok": True, **json.loads(out)}
    except Exception:
        return {"ok": False, "error": "parse"}


def build_shape_ttl(tc, props):
    head = ("@prefix sh: <http://www.w3.org/ns/shacl#> .\n"
            "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n"
            f"<urn:forge:shape> a sh:NodeShape ; sh:targetClass <{tc}>")
    pl = []
    for p in props:
        c = [f'sh:path <{p["path"]}>']
        if p.get("minCount"):
            c.append(f'sh:minCount {int(p["minCount"])}')
        if p.get("maxCount"):
            c.append(f'sh:maxCount {int(p["maxCount"])}')
        if p.get("datatype"):
            c.append(f'sh:datatype xsd:{p["datatype"]}')
        if p.get("nodeKind") == "IRI":
            c.append("sh:nodeKind sh:IRI")
        pl.append("  sh:property [ " + " ; ".join(c) + " ]")
    return head + (" ;\n" + " ;\n".join(pl) if pl else "") + " .\n"


def build_data_ttl(tc, props, sample):
    pmap = {p["path"]: p for p in props}
    head = "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n<urn:forge:sample> a <" + tc + ">"
    pl = []
    for path, val in (sample or {}).items():
        p = pmap.get(path, {})
        if p.get("nodeKind") == "IRI":
            lit = f"<{val}>"
        elif p.get("datatype") == "integer":
            lit = f'"{val}"^^xsd:integer'
        else:
            lit = json.dumps(str(val))
        pl.append(f"  <{path}> {lit}")
    return head + (" ;\n" + " ;\n".join(pl) if pl else "") + " .\n"


def h_shape_validate(d):
    tc = d.get("targetClass") or "urn:forge:Thing"
    props = d.get("properties") or []
    sample = d.get("sample") or {}
    shape_ttl = build_shape_ttl(tc, props)
    data_ttl = build_data_ttl(tc, props, sample)
    sfx = str(time.time_ns())
    sg, dg = f"urn:forge:s{sfx}", f"urn:forge:d{sfx}"
    q = (f"SELECT pgrdf.add_graph('{sg}');"
         f"SELECT pgrdf.parse_turtle($shp${shape_ttl}$shp$, pgrdf.graph_id('{sg}'));"
         f"SELECT pgrdf.add_graph('{dg}');"
         f"SELECT pgrdf.parse_turtle($dat${data_ttl}$dat$, pgrdf.graph_id('{dg}'));"
         f"SELECT pgrdf.validate(pgrdf.graph_id('{dg}'), pgrdf.graph_id('{sg}'));"
         f"SELECT pgrdf.drop_graph('{sg}');SELECT pgrdf.drop_graph('{dg}');")
    ok, out, e = sql(q)
    if not ok:
        return {"ok": False, "error": err1(e), "shape_ttl": shape_ttl, "data_ttl": data_ttl}
    line = next((l for l in out.splitlines() if '"conforms"' in l), None)
    if not line:
        return {"ok": False, "error": "no validation result"}
    r = json.loads(line)
    viols = [{"path": v.get("resultPath"), "message": v.get("resultMessage")}
             for v in (r.get("results") or [])]
    return {"ok": True, "conforms": bool(r.get("conforms")), "violations": viols,
            "shape_ttl": shape_ttl, "data_ttl": data_ttl}


def h_shape_seal(d):
    kernel = (d.get("kernel") or "forge").strip()
    tc = d.get("targetClass") or "urn:forge:Thing"
    props = d.get("properties") or []
    shape_ttl = build_shape_ttl(tc, props)
    g = f"urn:forge:kernel:{slug(kernel)}"
    q = (f"DO $do$ BEGIN BEGIN PERFORM pgrdf.drop_graph('{g}'); EXCEPTION WHEN OTHERS THEN NULL; END; "
         f"PERFORM pgrdf.add_graph('{g}'); "
         f"PERFORM pgrdf.parse_turtle($shp${shape_ttl}$shp$, pgrdf.graph_id('{g}')); END $do$; SELECT 'ok';")
    ok, out, e = sql(q)
    if not ok:
        return {"ok": False, "error": err1(e)}
    return {"ok": True, "kernel": kernel, "graph": g, "properties": len(props), "shape_ttl": shape_ttl}


def h_affordances(d):
    ok, out, e = sql(
        "SELECT COALESCE(json_agg(json_build_object('name',j->>'a','in',j->>'it','out',j->>'ot')),'[]') "
        "FROM pgrdf.sparql($q$ PREFIX ckp:<https://conceptkernel.org/ontology/v3.8/core#> "
        "SELECT ?a ?it ?ot WHERE { GRAPH ?g { ?a a ckp:Affordance . "
        "OPTIONAL { ?a ckp:inTopic ?it } OPTIONAL { ?a ckp:outTopic ?ot } } } ORDER BY ?a $q$) AS j;")
    return {"ok": ok, "affordances": json.loads(out or "[]")} if ok else {"ok": False, "error": err1(e)}


def h_verify(d):
    tid = str(d.get("id") or "")
    ok, out, e = sql(f"SELECT ckp.verify('{tid}');")
    return {"ok": ok, "id": tid, "verified": out.strip() == "t"} if ok else {"ok": False, "error": err1(e)}


HANDLERS = {
    "participant.join": h_participant_join, "kernel.create": h_kernel_create,
    "task.create": h_task_create, "task.update": h_task_update,
    "snapshot.board": h_snapshot, "provenance": h_provenance,
    "kernel.detail": h_kernel_detail,
    "shape.validate": h_shape_validate, "shape.seal": h_shape_seal,
    "affordances": h_affordances, "instance.verify": h_verify,
}


async def main():
    nc = NATS()
    url = os.getenv("NATS_URL", "nats://127.0.0.1:14222")
    await nc.connect(url, name="pgck-tutorial-dispatcher")
    print(f"[dispatcher] connected {url}; verbs={list(HANDLERS)}", flush=True)

    async def handler(msg):
        try:
            data = json.loads(msg.data.decode() or "{}")
        except Exception:
            return
        verb = msg.subject.split("action.", 1)[-1]
        fn = HANDLERS.get(verb)
        res = fn(data) if fn else {"ok": False, "error": f"unknown verb: {verb}"}
        res["req"] = data.get("req")
        await nc.publish(f"result.kernel.pgCK.action.{verb}", json.dumps(res, default=str).encode())
        if verb in ("task.create", "task.update", "kernel.create") and res.get("ok"):
            await nc.publish("event.kernel.pgCK.board.changed",
                             json.dumps({"kind": "board_changed", "verb": verb}).encode())
        print(f"[dispatcher] {verb} -> ok={res.get('ok')}", flush=True)

    await nc.subscribe("input.kernel.pgCK.action.>", cb=handler)
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
