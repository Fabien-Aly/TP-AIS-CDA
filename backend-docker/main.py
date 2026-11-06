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

# ---------------------------------------------------------------------------
# Configuration & Constantes
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# Couche SQLite (WAL mode, sans dépendance ORM lourde)
# ---------------------------------------------------------------------------
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
        # Purge automatique au-delà des 50 derniers résumés
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


# ---------------------------------------------------------------------------
# Cycle de vie FastAPI & Client HTTPX Async partagé
# ---------------------------------------------------------------------------
http_client: Optional[httpx.AsyncClient] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    if not APP_SECRET_TOKEN or APP_SECRET_TOKEN == "your_64_char_secret_token_here":
        logger.warning("ATTENTION: APP_SECRET_TOKEN non configuré ou valeur par défaut détectée !")
    if not MISTRAL_API_KEY or MISTRAL_API_KEY == "your_mistral_api_key_here":
        logger.warning("ATTENTION: MISTRAL_API_KEY non configurée !")

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

# Configuration CORS : autorise toute extension Chrome + le domaine du portail
app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_FRONTEND_ORIGIN],
    allow_origin_regex=r"^chrome-extension://[a-z]{32}$",
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Token"],
)


# ---------------------------------------------------------------------------
# Sécurité Hybride : Header X-API-Token (Extension) OU Cookie portal_session (Portail)
# ---------------------------------------------------------------------------
def is_valid_portal_cookie(cookie_val: Optional[str]) -> bool:
    """
    Vérifie la signature HMAC-SHA256 et l'expiration du cookie `portal_session`
    sans dépendre d'aucun nom d'utilisateur en dur :
    - Format WebAuthn : jti.exp.user.sig
    - Format standard : user|exp|sig
    """
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

    # 1. Authentification par Header X-API-Token (Extension Chrome)
    if x_api_token and hmac.compare_digest(x_api_token.encode("utf-8"), APP_SECRET_TOKEN.encode("utf-8")):
        return

    # 2. Authentification par Cookie SSO portal_session (Portail Web sur PC/Mobile)
    if is_valid_portal_cookie(portal_session):
        return

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Unauthorized: valid X-API-Token header or portal_session cookie required.",
    )


# ---------------------------------------------------------------------------
# Schémas Pydantic
# ---------------------------------------------------------------------------
class RelayRequest(BaseModel):
    raw_text: str = Field(..., min_length=10, description="Texte brut de la conversation extraite")
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


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/health")
async def healthcheck():
    return {"status": "ok"}


@app.get("/go/{provider}")
async def redirect_to_provider(provider: ProviderName):
    """
    Incrémente le compteur journalier (fuseau Europe/Paris) du fournisseur IA
    et redirige en HTTP 302 vers la plateforme cible.
    """
    target_url = PROVIDERS[provider]
    increment_provider_quota(provider)
    return RedirectResponse(url=target_url, status_code=status.HTTP_302_FOUND)


@app.post("/api/stats", dependencies=[Depends(verify_auth)])
async def manual_increment_stats(payload: QuotaIncrementRequest):
    """
    Permet d'incrémenter un compteur directement en POST via l'API si besoin.
    """
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
    """
    Retourne les compteurs du jour (Europe/Paris), l'historique récent des quotas
    et les N derniers résumés de contexte générés.
    """
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
    """
    Reçoit la conversation brute, la tronque à 100 000 caractères par sécurité,
    interroge Mistral (mistral-small-latest, temp=0.2), sauvegarde dans SQLite (max 50)
    et renvoie le résumé structuré.
    """
    if not MISTRAL_API_KEY or MISTRAL_API_KEY == "your_mistral_api_key_here":
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="MISTRAL_API_KEY non configurée dans /opt/ai-hub/.env sur le VPS.",
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
        logger.error("Mistral API timeout: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="Mistral API timed out while distilling context.",
        ) from exc
    except httpx.RequestError as exc:
        logger.error("Mistral API connection error: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Failed to reach Mistral API.",
        ) from exc

    if response.status_code != 200:
        logger.error("Mistral API error (%s): %s", response.status_code, response.text[:500])
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Mistral API returned HTTP {response.status_code}.",
        )

    data = response.json()
    try:
        summary = data["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, AttributeError) as exc:
        logger.error("Unexpected Mistral response format: %s", data)
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
