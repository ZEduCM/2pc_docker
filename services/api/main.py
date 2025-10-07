import os
import time
import json
import asyncio
from typing import Optional, Dict
from uuid import uuid4

import httpx
import jwt
from fastapi import FastAPI, Depends, HTTPException, Header
from fastapi.responses import PlainTextResponse, JSONResponse
from pydantic import BaseModel, Field
import redis.asyncio as redis

APP_NAME = "tp1-api"
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
A_URL = os.getenv("PARTICIPANT_A_URL", "http://account-a:8000")
B_URL = os.getenv("PARTICIPANT_B_URL", "http://account-b:8000")
JWT_SECRET = os.getenv("JWT_SECRET", "dev-secret")
RECOVERY_ROLLBACK_TIMEOUT_SECONDS = int(os.getenv("RECOVERY_ROLLBACK_TIMEOUT_SECONDS", "10"))

app = FastAPI(title=APP_NAME)
r = redis.from_url(REDIS_URL, decode_responses=True)

participants = {"A": A_URL, "B": B_URL}

# -------------------- Métricas simples --------------------
metrics: Dict[str, float] = {
    "transfer_requests_total": 0,
    "transfer_commits_total": 0,
    "transfer_rollbacks_total": 0,
    "transfer_idempotent_hits_total": 0,
    "transfer_latency_ms_avg": 0.0,
}

# -------------------- Modelos ------------------------------
class CrashParticipant(BaseModel):
    name: str  # "A" ou "B"
    stage: str # "after_prepare"

class Simulate(BaseModel):
    crash_coordinator_after_prepare: Optional[bool] = False
    crash_participant: Optional[CrashParticipant] = None

class TransferIn(BaseModel):
    from_account: str = Field(pattern="^[AB]$")
    to_account: str = Field(pattern="^[AB]$")
    amount: int = Field(gt=0)
    idempotency_key: Optional[str] = None
    simulate: Optional[Simulate] = None

# -------------------- Auth (JWT HS256) ---------------------
async def require_jwt(Authorization: str = Header(default=None)):
    if not Authorization or not Authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = Authorization.split(" ", 1)[1]
    try:
        jwt.decode(token, JWT_SECRET, algorithms=["HS256"])  # valida exp/iat etc
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"invalid token: {e}")

# -------------------- Utils -------------------------------
async def idempotency_get(key: str) -> Optional[dict]:
    if not key:
        return None
    raw = await r.get(f"idem:{key}")
    return json.loads(raw) if raw else None

async def idempotency_set(key: str, value: dict):
    if not key:
        return
    await r.set(f"idem:{key}", json.dumps(value), ex=60*60*24)  # 24h

async def log_txn(txn_id: str, **fields):
    await r.hset(f"txn:{txn_id}", mapping={**fields, "updated_at": time.time()})

# -------------------- Endpoints ----------------------------
@app.get("/healthz")
async def healthz():
    return {"ok": True, "service": APP_NAME}

@app.get("/metrics", response_class=PlainTextResponse)
async def metrics_ep():
    lines = [
        f"transfer_requests_total {int(metrics['transfer_requests_total'])}",
        f"transfer_commits_total {int(metrics['transfer_commits_total'])}",
        f"transfer_rollbacks_total {int(metrics['transfer_rollbacks_total'])}",
        f"transfer_idempotent_hits_total {int(metrics['transfer_idempotent_hits_total'])}",
        f"transfer_latency_ms_avg {round(metrics['transfer_latency_ms_avg'], 2)}",
    ]
    return "\n".join(lines) + "\n"

@app.get("/transactions/{txn_id}")
async def get_txn(txn_id: str):
    data = await r.hgetall(f"txn:{txn_id}")
    if not data:
        raise HTTPException(404, "txn not found")
    return data

@app.post("/transfer")
async def transfer(body: TransferIn, _: None = Depends(require_jwt)):
    t0 = time.time()
    metrics["transfer_requests_total"] += 1

    if body.from_account == body.to_account:
        raise HTTPException(400, "from == to")

    # Idempotência de requisição
    if body.idempotency_key:
        found = await idempotency_get(body.idempotency_key)
        if found:
            metrics["transfer_idempotent_hits_total"] += 1
            return found

    a_url = participants[body.from_account]
    b_url = participants[body.to_account]

    # Lock distribuído por par (A->B ou B->A) para evitar interleaving
    pair = f"{body.from_account}:{body.to_account}"
    lock = r.lock(f"lock:pair:{pair}", timeout=15, blocking_timeout=5)

    txn_id = str(uuid4())
    await log_txn(txn_id, state="INIT", amount=body.amount, src=body.from_account, dst=body.to_account, created_at=time.time())

    acquired = await lock.acquire()
    if not acquired:
        raise HTTPException(423, "pair busy, try again")

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            prepared = []
            # Fase 1: PREPARE
            for (url, direction, name) in [
                (a_url, "debit", body.from_account),
                (b_url, "credit", body.to_account),
            ]:
                payload = {"transaction_id": txn_id, "amount": body.amount, "direction": direction}
                if body.simulate and body.simulate.crash_participant and \
                   body.simulate.crash_participant.name == name and \
                   body.simulate.crash_participant.stage == "after_prepare":
                    payload["crash_after_prepare"] = True
                resp = await client.post(f"{url}/prepare", json=payload)
                if resp.status_code != 200:
                    raise RuntimeError(f"prepare failed at {name}: {resp.text}")
                prepared.append((url, name))

            await log_txn(txn_id, state="PREPARED_ALL", prepared_at=time.time())

            # Simular crash do coordenador após prepare
            if body.simulate and body.simulate.crash_coordinator_after_prepare:
                # Loga PREPARED_ALL e morre (Compose reinicia)
                os._exit(1)

            # Fase 2: COMMIT (best-effort + idempotente nos participantes)
            for url, _ in prepared:
                resp = await client.post(f"{url}/commit", json={"transaction_id": txn_id})
                if resp.status_code != 200:
                    raise RuntimeError(f"commit failed at {url}: {resp.text}")

            await log_txn(txn_id, state="COMMITTED", committed_at=time.time())
            metrics["transfer_commits_total"] += 1
            result = {"transaction_id": txn_id, "status": "committed"}

            if body.idempotency_key:
                await idempotency_set(body.idempotency_key, result)
            return JSONResponse(result)

    except Exception as e:
        # Aborta: tenta rollback idempotente em quem puder responder
        async with httpx.AsyncClient(timeout=5.0) as client:
            for url in [a_url, b_url]:
                try:
                    await client.post(f"{url}/rollback", json={"transaction_id": txn_id})
                except Exception:
                    pass
        await log_txn(txn_id, state="ABORTED", aborted_at=time.time(), error=str(e))
        metrics["transfer_rollbacks_total"] += 1
        raise HTTPException(status_code=409, detail=f"transaction aborted: {e}")
    finally:
        try:
            await lock.release()
        except Exception:
            pass
        # Latência média (EWMA simples)
        dt_ms = (time.time() - t0) * 1000
        metrics["transfer_latency_ms_avg"] = 0.8 * metrics["transfer_latency_ms_avg"] + 0.2 * dt_ms

# -------------------- Recovery Worker ---------------------
async def recovery_loop():
    await asyncio.sleep(2)
    while True:
        try:
            async for key in r.scan_iter("txn:*"):
                data = await r.hgetall(key)
                state = data.get("state")
                if state == "PREPARED_ALL":
                    prepared_at = float(data.get("prepared_at", data.get("updated_at", time.time())))
                    age = time.time() - prepared_at
                    if age >= RECOVERY_ROLLBACK_TIMEOUT_SECONDS:
                        src = data.get("src")
                        dst = data.get("dst")
                        amount = int(data.get("amount", "0"))
                        txn_id = key.split(":",1)[1]
                        # best-effort rollback em ambos
                        async with httpx.AsyncClient(timeout=5.0) as client:
                            for name in [src, dst]:
                                url = participants.get(name)
                                if not url:
                                    continue
                                try:
                                    await client.post(f"{url}/rollback", json={"transaction_id": txn_id})
                                except Exception:
                                    pass
                        await log_txn(txn_id, state="ABORTED_RECOVERED", recovered_at=time.time())
        except Exception:
            # não derruba o loop
            pass
        await asyncio.sleep(2)

@app.on_event("startup")
async def _startup():
    asyncio.create_task(recovery_loop())