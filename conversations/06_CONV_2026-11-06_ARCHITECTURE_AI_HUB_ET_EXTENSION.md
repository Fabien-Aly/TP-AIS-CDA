# 06. Architecture AI Hub et Extension Chrome (Smart Context Relay)

[← 05. Audit Sécurité](05_CONV_2026-11-05_AUDIT_SECURITE_ET_DURCISSEMENT.md) | [00. Index](00_INDEX_ET_CHRONOLOGIE.md) | [07. Dépannage & Rollback →](07_CONV_2026-11-06_DEPANNAGE_VERROUILLAGE_ET_ROLLBACK.md)

> [!NOTE]
> **Date :** 6 novembre 2026 | **Conversation ID :** `bb206ebc-3c83-4ee9-9cfc-c6a5314320e3` *(Partie 1/3 - Échanges 1 à 4)*  
> **Thème :** Conception architecturale et développement complet de l'AI Hub, extension Chrome Manifest V3, API backend FastAPI Docker avec Mistral et script `install-ai-hub.sh`.

## 🎯 Contexte & Objectifs
L'utilisateur formule une demande d'architecte système de haut niveau : concevoir un **Smart Context Relay** capable de relier le navigateur web (notamment les notes affichées dans Trilium) à un modèle d'IA local ou hébergé (Mistral API / vLLM).

Cette session produit :
1. **Extension Chrome Manifest V3** (`chrome-extension/`) :
   - `content.js` : extraction sémantique du texte de la page active (DOM Trilium).
   - `background.js` : gestion des messages et relai vers l'API.
   - `popup.html` & `popup.js` : interface utilisateur élégante avec boutons d'actions rapides (*Résumer*, *Corriger*, *Expliquer*, *Générer Flashcards*).
2. **Backend FastAPI Dockerisé** (`backend-docker/`) :
   - `main.py` : endpoints `/v1/analyze`, `/v1/summarize`, `/v1/chat`, intégration du client Mistral et CORS.
   - `Dockerfile` & `docker-compose.yml`.
3. **Script de déploiement global** `install-ai-hub.sh`.

---

### 💬 Échange #1 : Génération des briques logicielles : Extension Chrome & Backend FastAPI *(2026-11-06 10:13:31)*

#### 👤 Utilisateur

# RÔLE & POSTURE
Tu es un Architecte Système & Développeur Full-Stack Senior. 
Pas de blabla, approche premier-principes. Fournis un code propre, modulaire, sécurisé et prêt pour la production.

# OBJECTIF DU PROJET : "AI Hub & Smart Context Relay"
Construire un écosystème en 2 briques permettant de centraliser l'accès à mes outils IA (Gemini, ChatGPT, Claude, Mistral), de suivre mes quotas d'utilisation et d'effectuer un transfert de contexte intelligent (Context Handoff / Distillation) d'une IA à une autre via l'API Mistral.

---

# ARCHITECTURE GLOBALE (2 BRIQUES)

## Brique 1 : Backend API & Smart Redirector (Docker + Python FastAPI + SQLite)
Ce conteneur tourne derrière un reverse-proxy **Nginx** existant. Il remplit 3 rôles :
1. **Distillation de contexte (`/api/relay` - POST)** :
   - Reçoit le texte brut d'une conversation IA envoyé par mon extension Chrome.
   - Appelle l'API officielle Mistral (`https://api.mistral.ai/v1/chat/completions`, modèle `mistral-small-latest`, temperature `0.2`).
   - Applique un System Prompt strict qui résume la conversation en 4 points : *1. Objectif & Stack, 2. Code/Acquis validés, 3. Pistes échouées (à ne pas refaire), 4. Tâche immédiate à résoudre*.
   - Sauvegarde le résumé dans une base SQLite locale (historique des 50 derniers contextes pour accès depuis mobile/PC) et retourne le résumé en JSON.
2. **Smart Redirector & Tracker de Quotas (`/go/{provider}` - GET & `/api/stats` - GET/POST)** :
   - Les routes `/go/chatgpt`, `/go/gemini`, `/go/claude`, `/go/mistral` incrémentent un compteur journalier dans SQLite puis effectuent une redirection `HTTP 302` vers la plateforme cible.
   - Expose `/api/stats` pour afficher sur mon dashboard front ou dans l'extension mes compteurs du jour et les derniers résumés générés.

## Brique 2 : Extension Chrome (Manifest V3 - Vanilla JS)
L'extension agit côté client dans mon navigateur principal :
1. **Extraction DOM propre (`content.js`)** :
   - Cible les conteneurs de conversation sur `chatgpt.com`, `gemini.google.com`, `claude.ai` et `chat.mistral.ai`.
   - Récupère soit le texte surligné par l'utilisateur (`window.getSelection()`), soit l'intégralité du fil de discussion (`<main>`), en nettoyant le bruit HTML (menus, footers, scripts).
2. **Orchestration (`background.js` & `popup.js`)** :
   - Envoie le payload extrait au backend Docker (`POST /api/relay`) avec un header d'authentification (`X-API-Token`).
   - Récupère le résumé compressé par Mistral.
   - Copie automatiquement le résumé dans le presse-papier (`navigator.clipboard.writeText`).
   - Ouvre l'onglet de l'IA cible choisie (via la route `/go/{provider}` du Docker pour incrémenter le quota).
   - Bonus : Tente de pré-remplir le champ de saisie de l'IA cible (simulation d'événement `input` / `execCommand('insertText')` compatible React/ProseMirror, ou paramètre d'URL `?q=` si le résumé fait moins de 1800 caractères).

---

# CONTRAINTES TECHNIQUES & BONNES PRATIQUES OBLIGATOIRES

1. **Sécurité & Secrets** :
   - La clé `MISTRAL_API_KEY` et le token `APP_SECRET_TOKEN` (qui protège l'API Docker des appels non autorisés) doivent résider exclusivement côté serveur dans un fichier `.env`.
   - Aucune clé API Mistral en dur dans le code de l'extension Chrome. L'extension s'authentifie auprès du Docker via le header `X-API-Token` (stocké dans `chrome.storage.local`).
2. **Configuration Réseau & Nginx** :
   - **CORS** : Configurer `CORSMiddleware` dans FastAPI pour autoriser les requêtes provenant de `chrome-extension://*` et de mon domaine front.
   - **Payload Size** : Prévoir dans le bloc `nginx.conf` la directive `client_max_body_size 15M;` et des timeouts adaptés (`proxy_read_timeout 60s;`) pour laisser le temps à l'API Mistral de répondre sur de gros historiques.
3. **Robustesse & Asynchronisme** :
   - Utiliser `httpx` en mode `async` dans FastAPI pour appeler l'API Mistral sans bloquer le worker Uvicorn.
   - Gérer proprement les erreurs HTTP, les timeouts et les limites de taille de texte (troncature de sécurité à 100 000 caractères avant envoi).
4. **Légèreté** :
   - Pas de framework JS lourd (pas de React/Webpack pour l'extension) : HTML/CSS/JS Vanilla propre, sombre (Dark Mode), minimaliste.
   - Image Docker basée sur `python:3.12-slim` avec `uvicorn`.

---

# LIVRABLES ATTENDUS ÉTAPE PAR ÉTAPE

Procède de manière structurée :
1. Affiche d'abord l'arborescence complète du projet (`backend-docker/`, `chrome-extension/`, `nginx/`).
2. Génère le **Backend Docker complet** (`Dockerfile`, `docker-compose.yml`, `.env.example`, `requirements.txt`, `main.py`).
3. Génère la **Configuration Nginx** (`nginx.conf` ou bloc `server`/`location` prêt à inclure).
4. Génère l'**Extension Chrome complète** (`manifest.json`, `popup.html`, `popup.js`, `content.js`, `background.js`).

Attends ma validation entre l'étape 2 (Backend/Nginx) et l'étape 4 (Extension) si le code est trop long, afin de ne jamais tronquer un fichier. Commence par les étapes 1, 2 et 3.

<details><summary><b>🛠️ Outils & Scripts appelés en coulisses (7)</b></summary>


```text
• run_command(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
```
</details>

#### 🤖 Assistant IA

Voici les **Étapes 1, 2 et 3** complètes. Les fichiers correspondants ont également été créés directement dans votre espace de travail.

---

## 1. Arborescence Complète du Projet

```text
ai-hub-relay/
├── backend-docker/
│   ├── .env.example          # Modèle des variables d'environnement (secrets serveur)
│   ├── Dockerfile            # Image python:3.12-slim durcie (utilisateur non-root)
│   ├── docker-compose.yml    # Orchestration conteneur + volume SQLite + healthcheck
│   ├── requirements.txt      # Dépendances Python verrouillées
│   ├── main.py               # API FastAPI async (Mistral relay, redirector, SQLite WAL)
│   └── data/                 # Volume persistant contenant ai_hub.db (créé au runtime)
├── nginx/
│   └── nginx.conf            # Reverse-proxy (TLS, body 15M, timeout 60s, rate-limit)
└── chrome-extension/
    ├── manifest.json         # Manifest V3 (permissions minimales, host_permissions ciblées)
    ├── popup.html            # Interface Dark Mode minimaliste (Quotas, Relay, Config)
    ├── popup.js              # Logique UI, appel extraction, copie clipboard & stats
    ├── content.js            # Extraction DOM propre + pré-remplissage ProseMirror/React
    └── background.js         # Service Worker (orchestration API, injection post-redirect)
```

---

## 2. Backend Docker Complet (`backend-docker/`)

### [`.env.example`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/.env.example)

```ini
# Clé API officielle Mistral (https://console.mistral.ai/)
MISTRAL_API_KEY=your_mistral_api_key_here

# Token secret partagé avec l'extension Chrome et le dashboard (générer avec : openssl rand -hex 32)
APP_SECRET_TOKEN=your_64_char_secret_token_here

# Origine autorisée pour le dashboard front (en plus de chrome-extension://*)
ALLOWED_FRONTEND_ORIGIN=https://ai-hub.example.com

# Chemin de la base SQLite (monté via volume Docker)
SQLITE_DB_PATH=/app/data/ai_hub.db

# Modèle Mistral utilisé pour la distillation
MISTRAL_MODEL=mistral-small-latest
```

### [`requirements.txt`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/requirements.txt)

```text
fastapi==0.115.6
uvicorn[standard]==0.34.0
httpx==0.28.1
pydantic==2.10.4
pydantic-settings==2.7.1
```

### [`Dockerfile`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/Dockerfile)

```dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Création d'un utilisateur non-root pour la sécurité du conteneur
RUN groupadd -r appgroup && useradd -r -g appgroup -d /app -s /sbin/nologin appuser \
    && mkdir -p /app/data \
    && chown -R appuser:appgroup /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=appuser:appgroup main.py .

USER appuser

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
```

### [`docker-compose.yml`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/docker-compose.yml)

```yaml
services:
  ai-hub-backend:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ai-hub-backend
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:8000:8000"
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
```

### [`main.py`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/main.py)

Points clés d'architecture :
- **Comparaison de token en temps constant** (`hmac.compare_digest`) contre les timing attacks.
- **SQLite en mode WAL** (`PRAGMA journal_mode=WAL;`) pour supporter les lectures/écritures concurrentes sans verrouillage.
- **Troncature intelligente à 100 000 caractères** : conserve les 30 000 premiers caractères (énoncé et architecture initiale) et les 70 000 derniers (état actuel et erreurs récentes) plutôt qu'une coupe aveugle.
- **Rétention glissante automatique** des 50 derniers contextes en SQLite.

```python
import hmac
import logging
import os
import sqlite3
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal, Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, status
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

MISTRAL_API_KEY: str = os.getenv("MISTRAL_API_KEY", "").strip()
APP_SECRET_TOKEN: str = os.getenv("APP_SECRET_TOKEN", "").strip()
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


def increment_provider_quota(provider: str) -> int:
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
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
    now_iso = datetime.now(timezone.utc).isoformat()
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
    version="1.0.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)

# Configuration CORS : autorise toute extension Chrome + le domaine front configuré
app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_FRONTEND_ORIGIN],
    allow_origin_regex=r"^chrome-extension://[a-z]{32}$",
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Token"],
)


# ---------------------------------------------------------------------------
# Sécurité / Authentification
# ---------------------------------------------------------------------------
async def verify_api_token(x_api_token: str = Header(..., alias="X-API-Token")) -> None:
    if not APP_SECRET_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Server misconfigured: missing APP_SECRET_TOKEN.",
        )
    if not hmac.compare_digest(x_api_token.encode("utf-8"), APP_SECRET_TOKEN.encode("utf-8")):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid X-API-Token.",
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
    Incrémente le compteur journalier du fournisseur IA et redirige en HTTP 302.
    """
    target_url = PROVIDERS[provider]
    increment_provider_quota(provider)
    return RedirectResponse(url=target_url, status_code=status.HTTP_302_FOUND)


@app.post("/api/stats", dependencies=[Depends(verify_api_token)])
async def manual_increment_stats(payload: QuotaIncrementRequest):
    """
    Permet d'incrémenter un compteur directement en POST via l'API si besoin.
    """
    new_count = increment_provider_quota(payload.provider)
    return {
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "provider": payload.provider,
        "count": new_count,
    }


@app.get("/api/stats", dependencies=[Depends(verify_api_token)])
async def get_stats(
    limit: int = Query(default=20, ge=1, le=HISTORY_RETENTION_LIMIT),
):
    """
    Retourne les compteurs du jour (UTC), l'historique récent des quotas sur 7 jours
    et les N derniers résumés de contexte générés.
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
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


@app.post("/api/relay", response_model=RelayResponse, dependencies=[Depends(verify_api_token)])
async def relay_context(payload: RelayRequest):
    """
    Reçoit la conversation brute, la tronque à 100 000 caractères par sécurité,
    interroge Mistral (mistral-small-latest, temp=0.2), sauvegarde dans SQLite (max 50)
    et renvoie le résumé structuré.
    """
    if not MISTRAL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="MISTRAL_API_KEY is not configured on the server.",
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
```

---

## 3. Configuration Nginx (`nginx/nginx.conf`)

### [`nginx.conf`](file:///c:/Users/Lulu/Desktop/AIS/Greta/nginx/nginx.conf)

```nginx
# ============================================================================
# Configuration Nginx Reverse-Proxy pour AI Hub & Smart Context Relay
# À placer dans /etc/nginx/sites-available/ai-hub.conf (ou conf.d/ai-hub.conf)
# ============================================================================

upstream ai_hub_backend {
    server 127.0.0.1:8000;
    keepalive 16;
}

# Limite de débit anti-abus sur l'API (10 req/s avec burst de 20)
limit_req_zone $binary_remote_addr zone=ai_hub_ratelimit:10m rate=10r/s;

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ai-hub.example.com;

    # Certificats TLS (adapter selon votre configuration Let's Encrypt / Certbot)
    ssl_certificate     /etc/letsencrypt/live/ai-hub.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ai-hub.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Autoriser de gros historiques de conversation jusqu'à 15 Mo
    client_max_body_size 15M;
    client_body_buffer_size 1M;

    # Headers de sécurité
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;

    # Routes API (/api/relay, /api/stats) et Smart Redirector (/go/{provider})
    location ~ ^/(api|go|health) {
        limit_req zone=ai_hub_ratelimit burst=20 nodelay;

        proxy_pass http://ai_hub_backend;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";

        # Timeouts adaptés à la latence de distillation Mistral sur gros contexte
        proxy_connect_timeout 10s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }
}
```

---

Confirmez-moi si cette première partie (Backend Docker + Nginx) vous convient pour que je génère l'**Étape 4 : Extension Chrome complète** (`manifest.json`, `popup.html`, `popup.js`, `content.js`, `background.js`).


---

### 💬 Échange #2 : Analyse de l'environnement VPS et alignement avec les scripts existants *(2026-11-06 10:17:41)*

#### 👤 Utilisateur

cest pour mon vps donc analyse bien tout

<details><summary><b>🛠️ Outils & Scripts appelés en coulisses (8)</b></summary>


```text
• read_file(None)
• read_file(None)
• read_file(None)
• read_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
```
</details>

#### 🤖 Assistant IA

J'ai analysé vos 3 scripts existants ([`install-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh), [`fix-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh), [`secure-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh)). Voici le diagnostic exact de votre VPS et les ajustements critiques que j'ai appliqués aux fichiers du projet pour qu'il s'intègre **sans aucun conflit** :

---

## Diagnostic de votre VPS (`fabienaly.com`)

1. **Topologie actuelle des ports & conteneurs** :
   - `127.0.0.1:8888` → `trilium` (`/opt/trilium`, exposé sur `https://notes.fabienaly.com`).
   - `127.0.0.1:9100` → `portal-auth` (`/opt/portal`, authentification WebAuthn/Passkeys + `scrypt`, cookie `portal_session` sur `.fabienaly.com`).
   - `127.0.0.1:8000` → **Libre** : nous y plaçons `ai-hub` dans `/opt/ai-hub`.
2. **Zéro sous-domaine DNS supplémentaire requis chez IONOS** :
   - En montant AI Hub directement sur `https://fabienaly.com/api/...` et `https://fabienaly.com/go/...`, vous réutilisez immédiatement votre certificat Let's Encrypt existant (`--cert-name fabienaly.com`) sans toucher à vos DNS IONOS.
3. **Piège critique évité : `auth_request /_auth` vs Extension Chrome** :
   - Dans [`secure-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L798-L802), `location /` sur `fabienaly.com` applique `auth_request /_auth;` et redirige toute requête sans cookie `portal_session` en `302 /login`.
   - Si `/api/relay` passait par `auth_request /_auth`, les appels `fetch()` depuis le Service Worker de votre extension Chrome (`chrome-extension://...`) échoueraient systématiquement en `302 /login` (CORS redirect error).
   - **Solution implémentée dans [`main.py`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/main.py#L223-L266) (`verify_auth`)** :
     - Dans Nginx, `location /api/` passe directement à FastAPI (`127.0.0.1:8000`).
     - FastAPI implémente une **authentification hybride** en temps constant (`hmac.compare_digest`) :
       1. Soit via le header `X-API-Token` (utilisé par votre extension Chrome).
       2. Soit via le cookie `portal_session` signé avec le `PORTAL_SECRET` de `/opt/portal/.env` (format WebAuthn `jti.exp.user.sig` ou format initial `user|exp|sig`).
     - **Avantage** : depuis votre téléphone ou votre PC connecté à `https://fabienaly.com` (via Passkey), le portail peut interroger `/api/stats` directement sans avoir besoin de saisir le `X-API-Token` !
4. **Durcissement Docker aligné sur [`secure-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L112-L134)** :
   - [`docker-compose.yml`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/docker-compose.yml) reprend exactement votre politique de sécurité : `read_only: true`, `tmpfs: /tmp`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `mem_limit: 256m`, `pids_limit: 64`, et fuseau `TZ=Europe/Paris` (les compteurs journaliers SQLite basculent à minuit heure de Paris).
5. **Intégration au portail `/var/www/portal/index.html`** :
   - Votre portail possède une route `/status/trilium` et un 2e emplacement libre (`"Nouveau service"` dans `SERVICES`). Nous ajoutons `/status/ai-hub` dans Nginx pour afficher le badge vert **"En ligne"** ainsi que vos compteurs d'IA et les 50 derniers résumés directement sur `https://fabienaly.com`.

---

## Fichiers mis à jour pour votre VPS

### 1. [`backend-docker/.env.example`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/.env.example)

```ini
# Clé API officielle Mistral (https://console.mistral.ai/)
MISTRAL_API_KEY=your_mistral_api_key_here

# Token secret partagé avec l'extension Chrome (généré automatiquement sur le VPS via openssl rand -hex 32)
APP_SECRET_TOKEN=your_64_char_secret_token_here

# Secret partagé avec /opt/portal/.env pour accepter aussi le cookie de session portal_session (SSO portail)
PORTAL_SECRET=

# Utilisateur autorisé du portail (Lulucarab664)
PORTAL_USER=Lulucarab664

# Origine autorisée pour le portail VPS (en plus de chrome-extension://*)
ALLOWED_FRONTEND_ORIGIN=https://fabienaly.com

# Chemin de la base SQLite (monté via volume Docker /opt/ai-hub/data)
SQLITE_DB_PATH=/app/data/ai_hub.db

# Modèle Mistral utilisé pour la distillation
MISTRAL_MODEL=mistral-small-latest
```

### 2. [`backend-docker/docker-compose.yml`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/docker-compose.yml)

```yaml
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
```

### 3. [`nginx/nginx.conf`](file:///c:/Users/Lulu/Desktop/AIS/Greta/nginx/nginx.conf) (Blocs intégrés à `/etc/nginx/sites-available/portal`)

```nginx
    # 1. Indicateur "En ligne" pour la carte AI Hub sur le portail
    location = /status/ai-hub {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8000/health;
        proxy_connect_timeout 3s;
    }

    # 2. API AI Hub (/api/relay & /api/stats)
    # Authentification hybride dans FastAPI : X-API-Token (Extension) OU cookie portal_session (Portail Web)
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

    # 3. Smart Redirector & Tracker de Quotas (/go/chatgpt, /go/gemini, /go/claude, /go/mistral)
    location /go/ {
        limit_req zone=ai_hub_api burst=20 nodelay;

        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

---

## Suite (Étape 4 + Script de déploiement VPS)

Souhaitez-vous que je passe maintenant à :
1. **L'Étape 4 : Extension Chrome complète** (`manifest.json`, `popup.html`, `popup.js`, `content.js`, `background.js`) pré-configurée par défaut sur `https://fabienaly.com`,
2. **En bonus : un script `deploy-ai-hub.sh`** (dans le même style que votre `secure-portal.sh`) qui déploie `/opt/ai-hub`, récupère automatiquement `PORTAL_SECRET` depuis `/opt/portal/.env`, met à jour Nginx sans écraser votre HTTPS/Passkeys, ajoute le dashboard AI Hub sur votre portail et configure la sauvegarde quotidienne `/etc/cron.daily/backup-ai-hub` ?


---

### 💬 Échange #3 : Nettoyage des utilisateurs codés en dur et script de déploiement install-ai-hub.sh *(2026-11-06 10:23:57)*

#### 👤 Utilisateur

retire les user jai retire et dis moi nouveau script pour mon projet laisse les script initial

<details><summary><b>🛠️ Outils & Scripts appelés en coulisses (10)</b></summary>


```text
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• write_file(None)
• run_command(None)
```
</details>

#### 🤖 Assistant IA

C'est fait :
1. **Vos 3 scripts initiaux** ([`install-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh), [`fix-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh), [`secure-portal.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh)) **sont restés 100 % intacts**.
2. **Aucun identifiant utilisateur ni domaine en dur** ne figure dans le Backend ([`main.py`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/main.py), [`.env.example`](file:///c:/Users/Lulu/Desktop/AIS/Greta/backend-docker/.env.example)) ni dans le nouveau script : la vérification du cookie `portal_session` valide uniquement la signature cryptographique HMAC-SHA256 (`PORTAL_SECRET`) et la date d'expiration.
3. J'ai créé le **nouveau script autonome pour votre VPS** : [`install-ai-hub.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-ai-hub.sh), ainsi que **l'Extension Chrome complète** dans `chrome-extension/`.

---

## Nouveau Script VPS Autonome : [`install-ai-hub.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-ai-hub.sh)

Ce script (formaté exactement comme vos scripts existants `cat > /root/install-ai-hub.sh <<'SCRIPT_EOF' ...`) réalise toute l'installation sans jamais écraser votre configuration SSL Certbot ni vos Passkeys :
1. **Auto-détection** : lit automatiquement votre domaine (`RP_ID`) et votre `PORTAL_SECRET` dans `/opt/portal/.env`.
2. **Secrets isolés (`/opt/ai-hub/.env`)** : génère automatiquement un `APP_SECRET_TOKEN` (64 caractères hex) pour l'extension Chrome et le conserve lors des relances.
3. **Déploiement Docker durci (`/opt/ai-hub`)** : lance le conteneur `ai-hub` sur `127.0.0.1:8000` (`read_only: true`, `cap_drop: ALL`, `no-new-privileges`, `mem_limit: 256m`, `TZ=Europe/Paris`).
4. **Dashboard Web + Carte Portail** :
   - Crée `/var/www/portal/ai.html` (accessible sur PC et mobile derrière votre login/Passkey) affichant les boutons `/go/claude`, `/go/chatgpt`, `/go/gemini`, `/go/mistral`, les compteurs du jour et les 50 derniers contextes distillés avec bouton **Copier**.
   - Remplace la carte `"Nouveau service"` de `/var/www/portal/index.html` par **"AI Hub & Relay"** avec le badge temps réel `/status/ai-hub` (**En ligne**).
5. **Injection Nginx chirurgicale** : insère `/status/ai-hub`, `/api/` (`client_max_body_size 15M`, `proxy_read_timeout 60s`) et `/go/` dans `/etc/nginx/sites-available/portal` sans toucher aux blocs `listen 443 ssl` de Certbot.
6. **Backup quotidien** : crée `/etc/cron.daily/backup-ai-hub` (sauvegarde compressée de `ai_hub.db` dans `/opt/backups/ai-hub` avec rétention 7 jours).

Pour l'utiliser sur votre VPS :
- Renseignez simplement `MISTRAL_API_KEY="votre_cle"` en haut de [`install-ai-hub.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-ai-hub.sh#L10) et collez-le dans votre terminal root SSH. À la fin, il affiche le `X-API-Token` à copier dans l'extension Chrome.

---

## 4. Extension Chrome Complète (`chrome-extension/`)

### [`manifest.json`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/manifest.json)

```json
{
  "manifest_version": 3,
  "name": "AI Hub & Smart Context Relay",
  "version": "1.0.0",
  "description": "Distillation de contexte IA (Mistral) et suivi de quotas (ChatGPT, Gemini, Claude, Mistral).",
  "permissions": [
    "activeTab",
    "scripting",
    "storage",
    "clipboardWrite",
    "tabs"
  ],
  "host_permissions": [
    "https://chatgpt.com/*",
    "https://gemini.google.com/*",
    "https://claude.ai/*",
    "https://chat.mistral.ai/*",
    "https://*/*",
    "http://localhost/*"
  ],
  "background": {
    "service_worker": "background.js"
  },
  "action": {
    "default_title": "AI Hub & Smart Context Relay",
    "default_popup": "popup.html"
  },
  "content_scripts": [
    {
      "matches": [
        "https://chatgpt.com/*",
        "https://gemini.google.com/*",
        "https://claude.ai/*",
        "https://chat.mistral.ai/*"
      ],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ]
}
```

### [`content.js`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/content.js)

```javascript
/**
 * content.js — Extraction DOM propre & Pré-remplissage intelligent
 * Cibles : chatgpt.com, gemini.google.com, claude.ai, chat.mistral.ai
 */

(() => {
  "use strict";

  const NOISE_SELECTORS = [
    "nav",
    "header",
    "footer",
    "aside",
    "script",
    "style",
    "noscript",
    "svg",
    "button",
    "form",
    "[role='navigation']",
    "[role='banner']",
    "[aria-hidden='true']"
  ].join(",");

  function detectProviderFromHost(hostname) {
    if (hostname.includes("chatgpt.com")) return "chatgpt";
    if (hostname.includes("gemini.google.com")) return "gemini";
    if (hostname.includes("claude.ai")) return "claude";
    if (hostname.includes("mistral.ai")) return "mistral";
    return "unknown";
  }

  /**
   * Extrait soit la sélection active de l'utilisateur, soit le conteneur principal
   * de la conversation en supprimant les menus, boutons et scripts parasites.
   */
  function extractCleanConversation() {
    const provider = detectProviderFromHost(window.location.hostname);
    const selection = window.getSelection ? window.getSelection().toString().trim() : "";

    if (selection && selection.length >= 15) {
      return {
        mode: "selection",
        source_provider: provider,
        raw_text: selection
      };
    }

    const rootCandidate =
      document.querySelector("main") ||
      document.querySelector("[ role='main' ]") ||
      document.querySelector("chat-window") ||
      document.body;

    const clone = rootCandidate.cloneNode(true);
    clone.querySelectorAll(NOISE_SELECTORS).forEach((el) => el.remove());

    const rawText = (clone.innerText || clone.textContent || "")
      .replace(/\r\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();

    return {
      mode: "full_page",
      source_provider: provider,
      raw_text: rawText
    };
  }

  /**
   * Pré-remplit la zone de saisie de l'IA cible (compatible ProseMirror / Quill / React textarea).
   */
  function injectPromptIntoEditor(promptText) {
    const editorSelectors = [
      "#prompt-textarea", // ChatGPT (ProseMirror div ou textarea)
      "div.ProseMirror[contenteditable='true']", // Claude & ChatGPT
      "rich-textarea div.ql-editor[contenteditable='true']", // Gemini
      "div[contenteditable='true'][role='textbox']", // Générique
      "textarea" // Mistral / Fallback
    ];

    let targetEl = null;
    for (const sel of editorSelectors) {
      const candidate = document.querySelector(sel);
      if (candidate && candidate.offsetParent !== null) {
        targetEl = candidate;
        break;
      }
    }

    if (!targetEl) {
      return { injected: false, reason: "Champ de saisie introuvable" };
    }

    targetEl.focus();

    if (targetEl.tagName === "TEXTAREA" || targetEl.tagName === "INPUT") {
      const nativeSetter = Object.getOwnPropertyDescriptor(
        window.HTMLTextAreaElement.prototype,
        "value"
      )?.set;
      if (nativeSetter) {
        nativeSetter.call(targetEl, promptText);
      } else {
        targetEl.value = promptText;
      }
      targetEl.dispatchEvent(new Event("input", { bubbles: true }));
      targetEl.dispatchEvent(new Event("change", { bubbles: true }));
      return { injected: true };
    }

    try {
      document.execCommand("selectAll", false, null);
      const ok = document.execCommand("insertText", false, promptText);
      if (!ok) {
        targetEl.textContent = promptText;
        targetEl.dispatchEvent(
          new InputEvent("input", { bubbles: true, inputType: "insertText", data: promptText })
        );
      }
      return { injected: true };
    } catch (err) {
      targetEl.textContent = promptText;
      targetEl.dispatchEvent(new Event("input", { bubbles: true }));
      return { injected: true };
    }
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.action === "EXTRACT_CONTEXT") {
      try {
        const result = extractCleanConversation();
        sendResponse({ ok: true, ...result });
      } catch (err) {
        sendResponse({ ok: false, error: err.message || "Erreur d'extraction DOM" });
      }
      return true;
    }

    if (message?.action === "INJECT_PROMPT" && typeof message.prompt === "string") {
      let attempts = 0;
      const maxAttempts = 15;
      const timer = setInterval(() => {
        attempts += 1;
        const res = injectPromptIntoEditor(message.prompt);
        if (res.injected || attempts >= maxAttempts) {
          clearInterval(timer);
          sendResponse(res);
        }
      }, 400);
      return true;
    }
    return false;
  });
})();
```

### [`background.js`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/background.js)

```javascript
/**
 * background.js — Service Worker (Manifest V3)
 * Gère l'appel au Backend Docker (/api/relay), l'ouverture de la route /go/{provider}
 * et l'injection automatique du contexte distillé dans le nouvel onglet une fois chargé.
 */

const PENDING_INJECTIONS = new Map();

async function getStoredConfig() {
  const data = await chrome.storage.local.get(["apiBaseUrl", "apiToken"]);
  return {
    apiBaseUrl: (data.apiBaseUrl || "").replace(/\/+$/, ""),
    apiToken: (data.apiToken || "").trim()
  };
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status !== "complete" || !PENDING_INJECTIONS.has(tabId)) {
    return;
  }
  const url = tab.url || "";
  const isTargetAi =
    url.includes("chatgpt.com") ||
    url.includes("gemini.google.com") ||
    url.includes("claude.ai") ||
    url.includes("chat.mistral.ai");

  if (!isTargetAi) return;

  const promptText = PENDING_INJECTIONS.get(tabId);
  PENDING_INJECTIONS.delete(tabId);

  setTimeout(() => {
    chrome.tabs.sendMessage(tabId, { action: "INJECT_PROMPT", prompt: promptText }, () => {
      void chrome.runtime.lastError;
    });
  }, 900);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.action === "RELAY_CONTEXT") {
    handleRelayRequest(message.payload)
      .then((res) => sendResponse({ ok: true, data: res }))
      .catch((err) => sendResponse({ ok: false, error: err.message || "Erreur réseau" }));
    return true;
  }

  if (message?.action === "OPEN_PROVIDER_TAB") {
    openProviderWithOptionalPrompt(message.provider, message.prompt)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  return false;
});

async function handleRelayRequest({ raw_text, source_provider, target_provider, open_tab }) {
  const { apiBaseUrl, apiToken } = await getStoredConfig();
  if (!apiBaseUrl || !apiToken) {
    throw new Error("Configurez l'URL du VPS et le X-API-Token dans ⚙️ Config.");
  }

  const response = await fetch(`${apiBaseUrl}/api/relay`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Token": apiToken
    },
    body: JSON.stringify({
      raw_text,
      source_provider,
      target_provider
    })
  });

  if (!response.ok) {
    let detail = `Erreur HTTP ${response.status}`;
    try {
      const errJson = await response.json();
      if (errJson.detail) detail = errJson.detail;
    } catch {
      // ignore
    }
    throw new Error(detail);
  }

  const data = await response.json();

  if (open_tab) {
    await openProviderWithOptionalPrompt(target_provider, data.summary);
  }

  return data;
}

async function openProviderWithOptionalPrompt(provider, promptText = "") {
  const { apiBaseUrl } = await getStoredConfig();
  if (!apiBaseUrl) {
    throw new Error("Configurez d'abord l'URL du Backend dans ⚙️ Config.");
  }

  const redirectUrl = `${apiBaseUrl}/go/${encodeURIComponent(provider)}`;
  const createdTab = await chrome.tabs.create({ url: redirectUrl, active: true });

  if (promptText && createdTab?.id) {
    PENDING_INJECTIONS.set(createdTab.id, promptText);
  }
}
```

### [`popup.html`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/popup.html) & [`popup.js`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/popup.js)

Les fichiers complets [`popup.html`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/popup.html) et [`popup.js`](file:///c:/Users/Lulu/Desktop/AIS/Greta/chrome-extension/popup.js) sont générés dans le dossier `chrome-extension/` :
- **Installation dans Chrome / Brave / Edge** : ouvrez `chrome://extensions`, activez le **Mode développeur** en haut à droite, cliquez sur **Charger l'extension non empaquetée** et sélectionnez le dossier `chrome-extension`.
- Cliquez sur **⚙️ Config** dans la popup pour coller l'URL de votre VPS (`https://votredomaine.fr`) et le `X-API-Token` affiché à la fin de [`install-ai-hub.sh`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-ai-hub.sh).


---


---

[← 05. Audit Sécurité](05_CONV_2026-11-05_AUDIT_SECURITE_ET_DURCISSEMENT.md) | [00. Index](00_INDEX_ET_CHRONOLOGIE.md) | [07. Dépannage & Rollback →](07_CONV_2026-11-06_DEPANNAGE_VERROUILLAGE_ET_ROLLBACK.md)
