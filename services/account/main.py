import os
import json
import time
import threading
from typing import Dict, Optional
from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

APP_NAME = "tp1-account"
ACCOUNT_NAME = os.getenv("ACCOUNT_NAME", "A")
INITIAL_BALANCE = int(os.getenv("INITIAL_BALANCE", "1000"))
DATA_PATH = os.getenv("DATA_PATH", "/data")
STATE_FILE = os.path.join(DATA_PATH, "state.json")

app = FastAPI(title=f"{APP_NAME}-{ACCOUNT_NAME}")
lock = threading.Lock()

metrics = {
    "prepares_total": 0,
    "commits_total": 0,
    "rollbacks_total": 0,
}

# ---------- Persistência simples em arquivo JSON (com lock) ----------

def _ensure_state():
    if not os.path.isdir(DATA_PATH):
        os.makedirs(DATA_PATH, exist_ok=True)
    if not os.path.exists(STATE_FILE):
        state = {"account": ACCOUNT_NAME, "balance": INITIAL_BALANCE, "holds": {}, "pendings": {}}
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)


def _read_state() -> Dict:
    _ensure_state()
    with open(STATE_FILE, "r") as f:
        return json.load(f)


def _write_state(state: Dict):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)  # atomic

# ---------- Modelos ----------
class PrepareIn(BaseModel):
    transaction_id: str
    amount: int
    direction: str  # "debit" ou "credit"
    crash_after_prepare: Optional[bool] = False

class TxnIn(BaseModel):
    transaction_id: str

# ---------- Endpoints ----------
@app.get("/healthz")
async def healthz():
    return {"ok": True, "account": ACCOUNT_NAME}

@app.get("/metrics", response_class=PlainTextResponse)
async def metrics_ep():
    state = _read_state()
    lines = [
        f"prepares_total {int(metrics['prepares_total'])}",
        f"commits_total {int(metrics['commits_total'])}",
        f"rollbacks_total {int(metrics['rollbacks_total'])}",
        f"balance {int(state['balance'])}",
        f"holds {len(state['holds'])}",
        f"pendings {len(state['pendings'])}",
    ]
    return "\n".join(lines) + "\n"

@app.get("/balance")
async def balance():
    with lock:
        state = _read_state()
        return {"account": ACCOUNT_NAME, "balance": state["balance"], "holds": state["holds"], "pendings": state["pendings"]}

@app.post("/prepare")
async def prepare(inp: PrepareIn):
    with lock:
        state = _read_state()
        if inp.direction not in ("debit", "credit"):
            raise HTTPException(400, "direction invalid")

        # Idempotência: se já preparado, OK
        if inp.direction == "debit" and inp.transaction_id in state["holds"]:
            return {"prepared": True}
        if inp.direction == "credit" and inp.transaction_id in state["pendings"]:
            return {"prepared": True}

        if inp.direction == "debit":
            # precisa ter saldo suficiente
            if state["balance"] < inp.amount:
                raise HTTPException(409, "insufficient funds")
            state["holds"][inp.transaction_id] = inp.amount
        else:
            # crédito pendente
            state["pendings"][inp.transaction_id] = inp.amount

        _write_state(state)
        metrics["prepares_total"] += 1

    # simular crash após o prepare (o container reinicia via restart:on-failure)
    if inp.crash_after_prepare:
        os._exit(1)

    return {"prepared": True}

@app.post("/commit")
async def commit(inp: TxnIn):
    with lock:
        state = _read_state()
        # Idempotente
        if inp.transaction_id in state["holds"]:
            amount = state["holds"].pop(inp.transaction_id)
            state["balance"] -= int(amount)
            _write_state(state)
            metrics["commits_total"] += 1
            return {"committed": True}
        if inp.transaction_id in state["pendings"]:
            amount = state["pendings"].pop(inp.transaction_id)
            state["balance"] += int(amount)
            _write_state(state)
            metrics["commits_total"] += 1
            return {"committed": True}

    # Se nada a fazer, ainda é idempotente (ok)
    metrics["commits_total"] += 1
    return {"committed": True}

@app.post("/rollback")
async def rollback(inp: TxnIn):
    with lock:
        state = _read_state()
        changed = False
        if inp.transaction_id in state["holds"]:
            state["holds"].pop(inp.transaction_id, None)
            changed = True
        if inp.transaction_id in state["pendings"]:
            state["pendings"].pop(inp.transaction_id, None)
            changed = True
        if changed:
            _write_state(state)
            metrics["rollbacks_total"] += 1
        return {"rolled_back": True}