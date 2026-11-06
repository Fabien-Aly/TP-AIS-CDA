cat > /root/install-ai-hub.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  DÉPLOIEMENT AI HUB & SMART CONTEXT RELAY (FastAPI + Mistral + SQLite)
#  S'intègre au portail VPS existant (/opt/portal + Nginx) sans aucun conflit.
#  Aucun utilisateur ni domaine en dur : détecte automatiquement /opt/portal/.env
# =============================================================================
set -euo pipefail

# ============================ VOS RÉGLAGES ===================================
# Renseignez votre clé API Mistral (ou laissez vide si déjà dans /opt/ai-hub/.env)
MISTRAL_API_KEY=""
MISTRAL_MODEL="mistral-small-latest"
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { err "Lancez ce script en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/6 Détection automatique du domaine et des secrets du portail"
# -----------------------------------------------------------------------------
DOMAIN=""
if [ -f /opt/portal/.env ]; then
    DOMAIN=$(grep -s '^RP_ID=' /opt/portal/.env | cut -d= -f2- || true)
fi
if [ -z "$DOMAIN" ] && [ -f /root/portal.conf ]; then
    # shellcheck disable=SC1091
    . /root/portal.conf
fi
if [ -z "$DOMAIN" ] && [ -f /etc/nginx/sites-available/portal ]; then
    DOMAIN=$(awk '/server_name/ && !/notes\./ {print $2; exit}' /etc/nginx/sites-available/portal | tr -d ';')
fi
[ -n "$DOMAIN" ] || { err "Impossible de détecter le domaine. Vérifiez /opt/portal/.env."; exit 1; }

PORTAL_SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env | cut -d= -f2- || true)
ok "Domaine détecté : ${DOMAIN}"

# -----------------------------------------------------------------------------
step "2/6 Configuration des secrets (/opt/ai-hub/.env)"
# -----------------------------------------------------------------------------
mkdir -p /opt/ai-hub/data
chmod 700 /opt/ai-hub

EXISTING_TOKEN=$(grep -s '^APP_SECRET_TOKEN=' /opt/ai-hub/.env | cut -d= -f2- || true)
APP_SECRET_TOKEN="${EXISTING_TOKEN:-$(openssl rand -hex 32)}"

EXISTING_MISTRAL=$(grep -s '^MISTRAL_API_KEY=' /opt/ai-hub/.env | cut -d= -f2- || true)
FINAL_MISTRAL_KEY="${MISTRAL_API_KEY:-$EXISTING_MISTRAL}"

if [ -z "$FINAL_MISTRAL_KEY" ]; then
    warn "MISTRAL_API_KEY est vide ! Vous pourrez l'ajouter dans /opt/ai-hub/.env puis relancer : docker compose -f /opt/ai-hub/docker-compose.yml restart"
fi

cat > /opt/ai-hub/.env <<EOF
MISTRAL_API_KEY=${FINAL_MISTRAL_KEY}
APP_SECRET_TOKEN=${APP_SECRET_TOKEN}
PORTAL_SECRET=${PORTAL_SECRET}
ALLOWED_FRONTEND_ORIGIN=https://${DOMAIN}
SQLITE_DB_PATH=/app/data/ai_hub.db
MISTRAL_MODEL=${MISTRAL_MODEL}
EOF
chmod 600 /opt/ai-hub/.env
ok "Fichier /opt/ai-hub/.env sécurisé (chmod 600)"

# -----------------------------------------------------------------------------
step "3/6 Écriture du Backend Docker FastAPI (/opt/ai-hub)"
# -----------------------------------------------------------------------------
cat > /opt/ai-hub/requirements.txt <<'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
httpx==0.28.1
pydantic==2.10.4
pydantic-settings==2.7.1
EOF

cat > /opt/ai-hub/Dockerfile <<'EOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN groupadd -r -g 10001 appgroup && useradd -r -u 10001 -g appgroup -d /app -s /sbin/nologin appuser \
    && mkdir -p /app/data \
    && chown -R 10001:10001 /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=10001:10001 main.py .

USER 10001:10001

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
EOF

chown -R 10001:10001 /opt/ai-hub/data

cat > /opt/ai-hub/docker-compose.yml <<'EOF'
services:
  ai-hub:
    build:
      context: .
      dockerfile: Dockerfile
    image: ai-hub-backend:latest
    container_name: ai-hub
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /tmp:size=32m,mode=1777
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 256m
    pids_limit: 64
    env_file:
      - .env
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:8000:8000"
    environment:
      - TZ=Europe/Paris
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

cat > /opt/ai-hub/main.py <<'PYEOF'
import hashlib
import hmac
import logging
import os
import sqlite3
import time
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime
from pathlib import Path
from typing import Literal, Optional
from zoneinfo import ZoneInfo

import httpx
from fastapi import Cookie, Depends, FastAPI, Header, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("ai-hub")

PARIS_TZ = ZoneInfo("Europe/Paris")

MISTRAL_API_KEY: str = os.getenv("MISTRAL_API_KEY", "").strip()
APP_SECRET_TOKEN: str = os.getenv("APP_SECRET_TOKEN", "").strip()
PORTAL_SECRET: str = os.getenv("PORTAL_SECRET", "").strip()
ALLOWED_FRONTEND_ORIGIN: str = os.getenv("ALLOWED_FRONTEND_ORIGIN", "http://localhost:3000").strip()
SQLITE_DB_PATH: str = os.getenv("SQLITE_DB_PATH", "/app/data/ai_hub.db")
MISTRAL_MODEL: str = os.getenv("MISTRAL_MODEL", "mistral-small-latest")
MISTRAL_API_URL: str = "https://api.mistral.ai/v1/chat/completions"

MAX_CHARS_LIMIT: int = 100_000
HISTORY_RETENTION_LIMIT: int = 50

PROVIDERS: dict[str, str] = {
    "chatgpt": "https://chatgpt.com/",
    "gemini": "https://gemini.google.com/app",
    "claude": "https://claude.ai/new",
    "mistral": "https://chat.mistral.ai/chat",
}

ProviderName = Literal["chatgpt", "gemini", "claude", "mistral"]

SYSTEM_PROMPT = """Tu es un Ingénieur Principal spécialisé dans la distillation de contexte technique (Context Handoff) entre modèles d'IA.
Ta mission : compresser une conversation technique brute en un prompt de reprise autonome, dense, précis et directement exploitable par une autre IA, sans perte d'information critique.

Structure OBLIGATOIRE de ta réponse (utilise exactement ces 4 sections en Markdown) :

### 1. Objectif & Stack
- But final précis, architecture cible, langages, frameworks, versions et contraintes système/métier.

### 2. Code & Acquis Validés
- Décisions d'architecture figées, composants déjà fonctionnels, schémas de données, extraits ou signatures de code critiques qu'il ne faut PAS réécrire.

### 3. Pistes Échouées (À ne pas refaire)
- Approches testées et rejetées, bugs rencontrés, limitations d'API ou erreurs de configuration déjà écartées.

### 4. Tâche Immédiate à Résoudre
- La question exacte, le blocage actuel ou la prochaine étape concrète que la nouvelle IA doit traiter immédiatement.

Règles strictes :
- Pas d'introduction ni de conclusion.
- Conserve les noms exacts des variables, fichiers, routes et erreurs.
- Sois concis, factuel et directement actionnable."""


@contextmanager
def get_db():
    Path(SQLITE_DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(SQLITE_DB_PATH, timeout=10.0)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    with get_db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS quota_stats (
                date TEXT NOT NULL,
                provider TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date, provider)
            );

            CREATE TABLE IF NOT EXISTS relay_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                source_provider TEXT NOT NULL,
                target_provider TEXT NOT NULL,
                raw_char_count INTEGER NOT NULL,
                truncated INTEGER NOT NULL DEFAULT 0,
                summary TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_relay_created_at
            ON relay_history(id DESC);
            """
        )


def today_paris() -> str:
    return datetime.now(PARIS_TZ).strftime("%Y-%m-%d")


def increment_provider_quota(provider: str) -> int:
    today = today_paris()
    with get_db() as conn:
        conn.execute(
            """
            INSERT INTO quota_stats (date, provider, count)
            VALUES (?, ?, 1)
            ON CONFLICT(date, provider) DO UPDATE SET count = count + 1;
            """,
            (today, provider),
        )
        row = conn.execute(
            "SELECT count FROM quota_stats WHERE date = ? AND provider = ?",
            (today, provider),
        ).fetchone()
        return int(row["count"]) if row else 1


def save_relay_summary(
    source_provider: str,
    target_provider: str,
    raw_char_count: int,
    truncated: bool,
    summary: str,
) -> int:
    now_iso = datetime.now(PARIS_TZ).isoformat(timespec="seconds")
    with get_db() as conn:
        cursor = conn.execute(
            """
            INSERT INTO relay_history (
                created_at, source_provider, target_provider,
                raw_char_count, truncated, summary
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                now_iso,
                source_provider,
                target_provider,
                raw_char_count,
                1 if truncated else 0,
                summary,
            ),
        )
        record_id = cursor.lastrowid or 0
        conn.execute(
            """
            DELETE FROM relay_history
            WHERE id NOT IN (
                SELECT id FROM relay_history
                ORDER BY id DESC
                LIMIT ?
            )
            """,
            (HISTORY_RETENTION_LIMIT,),
        )
        return int(record_id)


http_client: Optional[httpx.AsyncClient] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    init_db()
    http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(connect=10.0, read=55.0, write=10.0, pool=10.0),
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    )
    yield
    await http_client.aclose()


app = FastAPI(
    title="AI Hub & Smart Context Relay",
    version="1.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_FRONTEND_ORIGIN],
    allow_origin_regex=r"^chrome-extension://[a-z]{32}$",
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Token"],
)


def is_valid_portal_cookie(cookie_val: Optional[str]) -> bool:
    if not cookie_val or not PORTAL_SECRET:
        return False
    secret_bytes = PORTAL_SECRET.encode("utf-8")
    try:
        if "." in cookie_val:
            jti, exp_s, user, sig = cookie_val.split(".", 3)
            if int(exp_s) <= time.time():
                return False
            expected_sig = hmac.new(secret_bytes, f"{jti}.{exp_s}.{user}".encode("utf-8"), hashlib.sha256).hexdigest()
            return hmac.compare_digest(sig, expected_sig)
        elif "|" in cookie_val:
            user, exp_s, sig = cookie_val.split("|", 2)
            if int(exp_s) <= time.time():
                return False
            expected_sig = hmac.new(secret_bytes, f"{user}|{exp_s}".encode("utf-8"), hashlib.sha256).hexdigest()
            return hmac.compare_digest(sig, expected_sig)
    except Exception:
        return False
    return False


async def verify_auth(
    x_api_token: Optional[str] = Header(default=None, alias="X-API-Token"),
    portal_session: Optional[str] = Cookie(default=None),
) -> None:
    if not APP_SECRET_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Server misconfigured: missing APP_SECRET_TOKEN.",
        )
    if x_api_token and hmac.compare_digest(x_api_token.encode("utf-8"), APP_SECRET_TOKEN.encode("utf-8")):
        return
    if is_valid_portal_cookie(portal_session):
        return
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Unauthorized: valid X-API-Token header or portal_session cookie required.",
    )


class RelayRequest(BaseModel):
    raw_text: str = Field(..., min_length=10)
    source_provider: str = Field(default="unknown", max_length=32)
    target_provider: ProviderName = Field(default="claude")


class RelayResponse(BaseModel):
    id: int
    summary: str
    source_provider: str
    target_provider: str
    raw_char_count: int
    truncated: bool
    redirect_url: str


class QuotaIncrementRequest(BaseModel):
    provider: ProviderName


@app.get("/health")
async def healthcheck():
    return {"status": "ok"}


@app.get("/go/{provider}")
async def redirect_to_provider(provider: ProviderName):
    target_url = PROVIDERS[provider]
    increment_provider_quota(provider)
    return RedirectResponse(url=target_url, status_code=status.HTTP_302_FOUND)


@app.post("/api/stats", dependencies=[Depends(verify_auth)])
async def manual_increment_stats(payload: QuotaIncrementRequest):
    new_count = increment_provider_quota(payload.provider)
    return {
        "date": today_paris(),
        "provider": payload.provider,
        "count": new_count,
    }


@app.get("/api/stats", dependencies=[Depends(verify_auth)])
async def get_stats(
    limit: int = Query(default=20, ge=1, le=HISTORY_RETENTION_LIMIT),
):
    today = today_paris()
    with get_db() as conn:
        today_rows = conn.execute(
            "SELECT provider, count FROM quota_stats WHERE date = ?",
            (today,),
        ).fetchall()

        weekly_rows = conn.execute(
            """
            SELECT date, provider, count
            FROM quota_stats
            ORDER BY date DESC, provider ASC
            LIMIT 28
            """
        ).fetchall()

        history_rows = conn.execute(
            """
            SELECT id, created_at, source_provider, target_provider,
                   raw_char_count, truncated, summary
            FROM relay_history
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    quotas_today = {p: 0 for p in PROVIDERS}
    for row in today_rows:
        quotas_today[row["provider"]] = row["count"]

    return {
        "date": today,
        "quotas_today": quotas_today,
        "weekly_breakdown": [dict(r) for r in weekly_rows],
        "recent_relays": [
            {
                "id": r["id"],
                "created_at": r["created_at"],
                "source_provider": r["source_provider"],
                "target_provider": r["target_provider"],
                "raw_char_count": r["raw_char_count"],
                "truncated": bool(r["truncated"]),
                "summary": r["summary"],
            }
            for r in history_rows
        ],
    }


@app.post("/api/relay", response_model=RelayResponse, dependencies=[Depends(verify_auth)])
async def relay_context(payload: RelayRequest):
    if not MISTRAL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="MISTRAL_API_KEY non configurée dans /opt/ai-hub/.env.",
        )

    cleaned_text = payload.raw_text.strip()
    original_length = len(cleaned_text)
    was_truncated = original_length > MAX_CHARS_LIMIT

    if was_truncated:
        head_len = 30_000
        tail_len = MAX_CHARS_LIMIT - head_len
        cleaned_text = (
            cleaned_text[:head_len]
            + "\n\n[... TRONCATURE DE SÉCURITÉ AU MILIEU DE LA CONVERSATION ...]\n\n"
            + cleaned_text[-tail_len:]
        )

    mistral_payload = {
        "model": MISTRAL_MODEL,
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Voici la transcription brute d'une session issue de '{payload.source_provider}' "
                    f"à transférer vers '{payload.target_provider}'. "
                    f"Génère le résumé de transfert en 4 points :\n\n{cleaned_text}"
                ),
            },
        ],
    }

    assert http_client is not None
    try:
        response = await http_client.post(
            MISTRAL_API_URL,
            headers={
                "Authorization": f"Bearer {MISTRAL_API_KEY}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            json=mistral_payload,
        )
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="Mistral API timed out while distilling context.",
        ) from exc
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Failed to reach Mistral API.",
        ) from exc

    if response.status_code != 200:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Mistral API returned HTTP {response.status_code}.",
        )

    data = response.json()
    try:
        summary = data["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, AttributeError) as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Invalid response format from Mistral API.",
        ) from exc

    record_id = save_relay_summary(
        source_provider=payload.source_provider,
        target_provider=payload.target_provider,
        raw_char_count=original_length,
        truncated=was_truncated,
        summary=summary,
    )

    return RelayResponse(
        id=record_id,
        summary=summary,
        source_provider=payload.source_provider,
        target_provider=payload.target_provider,
        raw_char_count=original_length,
        truncated=was_truncated,
        redirect_url=f"/go/{payload.target_provider}",
    )
PYEOF

docker compose -f /opt/ai-hub/docker-compose.yml up -d --build --force-recreate
ok "Conteneur Docker ai-hub démarré sur 127.0.0.1:8000"

# -----------------------------------------------------------------------------
step "4/6 Création du Dashboard Web AI Hub (/var/www/portal/ai.html) + Carte Portail"
# -----------------------------------------------------------------------------
cat > /var/www/portal/ai.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Hub & Context Relay</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--txt:#e2e8f0;--muted:#94a3b8;--glass:rgba(15,23,42,.65);--line:rgba(255,255,255,.09)}
body{min-height:100vh;font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;background:#070b17;color:var(--txt);padding:28px clamp(16px,4vw,48px)}
header{max-width:1050px;margin:0 auto 28px;display:flex;justify-content:space-between;align-items:center}
.brand{display:flex;align-items:center;gap:12px;font-weight:700;font-size:1.2rem}
.brand i{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;font-style:normal;background:linear-gradient(135deg,#7c3aed,#0ea5e9)}
a.back{color:var(--muted);text-decoration:none;font-size:.88rem;padding:9px 15px;border-radius:10px;border:1px solid var(--line);background:var(--glass)}
a.back:hover{color:#fff}
main{max-width:1050px;margin:0 auto}
h2{font-size:1rem;color:var(--muted);text-transform:uppercase;letter-spacing:.6px;margin:22px 0 12px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}
.p-card{display:flex;justify-content:space-between;align-items:center;padding:20px;border-radius:16px;text-decoration:none;color:var(--txt);background:var(--glass);border:1px solid var(--line);transition:.2s}
.p-card:hover{transform:translateY(-3px);border-color:#8b5cf6}
.p-name{font-size:1.1rem;font-weight:700}
.p-sub{font-size:.8rem;color:var(--muted);margin-top:4px}
.p-count{font-size:2rem;font-weight:800;background:linear-gradient(135deg,#fff,#a5b4fc);-webkit-background-clip:text;background-clip:text;color:transparent}
.relay-list{display:flex;flex-direction:column;gap:14px;margin-top:10px}
.relay-card{padding:20px;border-radius:16px;background:var(--glass);border:1px solid var(--line)}
.relay-top{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;gap:10px;flex-wrap:wrap}
.badge{font-size:.78rem;padding:4px 10px;border-radius:999px;background:rgba(124,58,237,.2);border:1px solid rgba(124,58,237,.4);color:#c4b5fd;font-weight:600}
.copy-btn{padding:7px 14px;border-radius:8px;border:1px solid var(--line);background:rgba(255,255,255,.06);color:#fff;cursor:pointer;font-size:.82rem;font-weight:600}
.copy-btn:hover{background:#7c3aed;border-color:#7c3aed}
pre{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.84rem;line-height:1.55;color:#cbd5e1;background:rgba(2,6,23,.65);padding:14px;border-radius:12px;border:1px solid var(--line);max-height:320px;overflow-y:auto}
</style>
</head>
<body>
<header>
  <div class="brand"><i>⚡</i> AI Hub &amp; Smart Context Relay</div>
  <a class="back" href="/">&larr; Retour au portail</a>
</header>
<main>
  <h2>Accès Rapide &amp; Quotas du Jour</h2>
  <div class="grid">
    <a class="p-card" href="/go/claude" target="_blank" rel="noopener">
      <div><div class="p-name">Claude</div><div class="p-sub">Ouvrir &amp; compter &rarr;</div></div>
      <div class="p-count" id="c-claude">0</div>
    </a>
    <a class="p-card" href="/go/chatgpt" target="_blank" rel="noopener">
      <div><div class="p-name">ChatGPT</div><div class="p-sub">Ouvrir &amp; compter &rarr;</div></div>
      <div class="p-count" id="c-chatgpt">0</div>
    </a>
    <a class="p-card" href="/go/gemini" target="_blank" rel="noopener">
      <div><div class="p-name">Gemini</div><div class="p-sub">Ouvrir &amp; compter &rarr;</div></div>
      <div class="p-count" id="c-gemini">0</div>
    </a>
    <a class="p-card" href="/go/mistral" target="_blank" rel="noopener">
      <div><div class="p-name">Mistral</div><div class="p-sub">Ouvrir &amp; compter &rarr;</div></div>
      <div class="p-count" id="c-mistral">0</div>
    </a>
  </div>

  <h2>50 Derniers Contextes Distillés (PC &amp; Mobile)</h2>
  <div class="relay-list" id="relayList">
    <p style="color:var(--muted);padding:20px;text-align:center">Chargement des contextes…</p>
  </div>
</main>
<script>
async function loadStats() {
  try {
    const r = await fetch('/api/stats?limit=50', { credentials: 'same-origin' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    if (data.quotas_today) {
      for (const [k, v] of Object.entries(data.quotas_today)) {
        const el = document.getElementById('c-' + k);
        if (el) el.textContent = v;
      }
    }
    const list = document.getElementById('relayList');
    const items = data.recent_relays || [];
    if (!items.length) {
      list.innerHTML = '<p style="color:var(--muted);padding:20px;text-align:center">Aucun contexte distillé pour le moment.</p>';
      return;
    }
    list.innerHTML = '';
    items.forEach(item => {
      const card = document.createElement('div');
      card.className = 'relay-card';
      const top = document.createElement('div');
      top.className = 'relay-top';
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = `${item.source_provider} → ${item.target_provider} · ${new Date(item.created_at).toLocaleString('fr-FR')} (${item.raw_char_count} car.)`;
      const btn = document.createElement('button');
      btn.className = 'copy-btn';
      btn.textContent = 'Copier le prompt';
      btn.onclick = async () => {
        await navigator.clipboard.writeText(item.summary);
        btn.textContent = '✓ Copié !';
        setTimeout(() => btn.textContent = 'Copier le prompt', 1500);
      };
      const pre = document.createElement('pre');
      pre.textContent = item.summary;
      top.appendChild(badge);
      top.appendChild(btn);
      card.appendChild(top);
      card.appendChild(pre);
      list.appendChild(card);
    });
  } catch (e) {
    document.getElementById('relayList').innerHTML = '<p style="color:#f87171;padding:20px;text-align:center">Erreur de chargement des statistiques.</p>';
  }
}
loadStats();
</script>
</body>
</html>
HTMLEOF

# Remplace la carte "Nouveau service" dans /var/www/portal/index.html par AI Hub si présente
if [ -f /var/www/portal/index.html ] && grep -q "Nouveau service" /var/www/portal/index.html; then
    python3 -c '
p = "/var/www/portal/index.html"
s = open(p, encoding="utf-8").read()
old = """  { name: "Nouveau service", desc: "Emplacement libre : Nextcloud, Portainer, Uptime Kuma…",
    icon: "➕", url: "#", color: ["#334155", "#64748b"], tag: "Bientôt", soon: true }"""
new = """  { name: "AI Hub & Relay", desc: "Quotas IA (Claude, ChatGPT, Gemini, Mistral) & 50 derniers contextes distillés.",
    icon: "⚡", url: "/ai.html", status: "/status/ai-hub", color: ["#0ea5e9", "#38bdf8"], tag: "Hub · Mistral" }"""
if old in s:
    open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
'
    ok "Carte 'AI Hub & Relay' activée sur le portail principal"
fi

# -----------------------------------------------------------------------------
step "5/6 Mise à jour non-destructive de Nginx (/etc/nginx/sites-available/portal)"
# -----------------------------------------------------------------------------
cat > /etc/nginx/conf.d/ai-hub-ratelimit.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=ai_hub_api:10m rate=10r/s;
EOF

if ! grep -q "location /api/" /etc/nginx/sites-available/portal; then
    python3 -c '
p = "/etc/nginx/sites-available/portal"
content = open(p, encoding="utf-8").read()
target = "    location = /status/trilium {"
block = """    location = /status/ai-hub {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8000/health;
        proxy_connect_timeout 3s;
    }

    location /api/ {
        limit_req zone=ai_hub_api burst=20 nodelay;
        client_max_body_size 15M;
        client_body_buffer_size 1M;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Cookie $http_cookie;
        proxy_connect_timeout 10s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    location /go/ {
        limit_req zone=ai_hub_api burst=20 nodelay;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

"""
if target in content:
    content = content.replace(target, block + target, 1)
    open(p, "w", encoding="utf-8").write(content)
'
    ok "Routes /api/, /go/ et /status/ai-hub injectées dans Nginx sans toucher au SSL"
else
    ok "Routes Nginx AI Hub déjà présentes"
fi

nginx -t && systemctl reload nginx
ok "Nginx validé et rechargé"

# -----------------------------------------------------------------------------
step "6/6 Sauvegarde quotidienne SQLite (/etc/cron.daily/backup-ai-hub)"
# -----------------------------------------------------------------------------
mkdir -p /opt/backups/ai-hub
chmod 700 /opt/backups /opt/backups/ai-hub
cat > /etc/cron.daily/backup-ai-hub <<'EOF'
#!/bin/bash
umask 077
if [ -f /opt/ai-hub/data/ai_hub.db ]; then
    sqlite3 /opt/ai-hub/data/ai_hub.db ".backup '/opt/backups/ai-hub/ai_hub-$(date +%F).db'" 2>/dev/null \
      || cp /opt/ai-hub/data/ai_hub.db "/opt/backups/ai-hub/ai_hub-$(date +%F).db"
    gzip -f "/opt/backups/ai-hub/ai_hub-$(date +%F).db"
    find /opt/backups/ai-hub/ -type f -name "*.gz" -mtime +7 -delete
fi
EOF
chmod 700 /etc/cron.daily/backup-ai-hub
ok "Sauvegarde quotidienne SQLite activée (/opt/backups/ai-hub)"

echo -e "\n\033[1;32m==================================================================\033[0m"
echo -e "\033[1;32m✅ AI Hub & Smart Context Relay déployé avec succès !\033[0m"
echo -e "\033[1;32m==================================================================\033[0m"
echo "   Dashboard Web : https://${DOMAIN}/ai.html"
echo "   URL Extension : https://${DOMAIN}"
echo "   X-API-Token   : ${APP_SECRET_TOKEN}"
echo "=================================================================="
SCRIPT_EOF
chmod 700 /root/install-ai-hub.sh
bash /root/install-ai-hub.sh
