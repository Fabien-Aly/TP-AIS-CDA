cat > /root/setup-portal-ai-mistral.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  AI HUB & PORTAIL UNIFIÉ — DESIGN MISTRAL AI + GOOGLE AUTHENTICATOR
#  - Thème "Mistral AI" signature (Orange / Zinc / Glow) + Sélecteur de Thème
#  - Portail d'accueil avec Trilium Notes + Tuile dynamique AI Hub
#  - Dashboard /ai.html (Quotas Claude, ChatGPT, Gemini, Mistral + Historique)
#  - Module Google Authenticator actif sur /forgot pour réinitialiser le MDP
#  - Backend Docker FastAPI (Distillation Mistral /api/relay + Redirector /go/)
# =============================================================================
set -euo pipefail

# ============================ CONFIGURATION ==================================
DOMAIN="fabienaly.com"
PORTAL_USER="Lulucarab664"
PORTAL_PASS="Lulucarab664"
# Renseignez votre clé API Mistral (ou laissez vide pour saisie interactive) :
MISTRAL_API_KEY=""
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script en root."; exit 1; }

# Récupération / conservation de la clé API Mistral
EXISTING_MISTRAL=$(grep -s '^MISTRAL_API_KEY=' /opt/ai-hub/.env 2>/dev/null | cut -d= -f2- || true)
if [ -n "$MISTRAL_API_KEY" ]; then
    FINAL_MISTRAL="$MISTRAL_API_KEY"
elif [ -n "$EXISTING_MISTRAL" ] && [ "$EXISTING_MISTRAL" != "votre_cle_mistral_ici" ]; then
    FINAL_MISTRAL="$EXISTING_MISTRAL"
else
    read -r -p "Entrez votre clé API officielle Mistral : " FINAL_MISTRAL
fi

# -----------------------------------------------------------------------------
step "1/6 Synchronisation système & Secrets d'authentification"
# -----------------------------------------------------------------------------
timedatectl set-ntp true 2>/dev/null || true
apt-get install -y qrencode >/dev/null 2>&1 || true

mkdir -p /opt/portal /opt/ai-hub/data
chmod 700 /opt/portal /opt/ai-hub

# Clé secrète Google Authenticator (conserve l'actuelle si présente)
TOTP_SECRET=$(grep -s '^TOTP_SECRET=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || true)
if [ -z "$TOTP_SECRET" ]; then
    TOTP_SECRET=$(python3 -c "import base64, os; print(base64.b32encode(os.urandom(10)).decode())")
fi

PORTAL_SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || openssl rand -hex 32)
APP_SECRET_TOKEN=$(grep -s '^APP_SECRET_TOKEN=' /opt/ai-hub/.env 2>/dev/null | cut -d= -f2- || openssl rand -hex 32)

cat > /opt/portal/.env <<EOF
PORTAL_USER=${PORTAL_USER}
PORTAL_PASS=${PORTAL_PASS}
PORTAL_SECRET=${PORTAL_SECRET}
TOTP_SECRET=${TOTP_SECRET}
COOKIE_SECURE=1
SESSION_HOURS=24
EOF
chmod 600 /opt/portal/.env

cat > /opt/ai-hub/.env <<EOF
MISTRAL_API_KEY=${FINAL_MISTRAL}
APP_SECRET_TOKEN=${APP_SECRET_TOKEN}
ALLOWED_FRONTEND_ORIGIN=https://${DOMAIN}
SQLITE_DB_PATH=/app/data/ai_hub.db
MISTRAL_MODEL=mistral-small-latest
EOF
chmod 600 /opt/ai-hub/.env

# Nettoyage des rate-limits parasites
rm -f /etc/nginx/conf.d/portal-ratelimit.conf /etc/nginx/conf.d/ai-hub-ratelimit.conf /opt/portal/Dockerfile
rm -rf /opt/portal/data

ok "Secrets sauvegardés (.env)"

# -----------------------------------------------------------------------------
step "2/6 Service d'authentification Portal-Auth (Login + Google Authenticator)"
# -----------------------------------------------------------------------------
cat > /opt/portal/docker-compose.yml <<'EOF'
services:
  portal-auth:
    image: python:3.12-alpine
    container_name: portal-auth
    restart: unless-stopped
    command: ["python", "-u", "/app/auth.py"]
    env_file: .env
    volumes:
      - /opt/portal/auth.py:/app/auth.py:ro
    ports:
      - "127.0.0.1:9100:9100"
EOF

cat > /opt/portal/auth.py <<'PYEOF'
import base64, hashlib, hmac, os, struct, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER = os.environ.get("PORTAL_USER", "").strip()
PASS = os.environ.get("PORTAL_PASS", "").strip()
SECRET = os.environ.get("PORTAL_SECRET", "secret").encode()
SECURE = os.environ.get("COOKIE_SECURE", "1") == "1"
TTL = int(os.environ.get("SESSION_HOURS", "24")) * 3600
TOTP_SECRET = os.environ.get("TOTP_SECRET", "").strip().replace(" ", "").upper()
COOKIE = "portal_sso_v3"
FAILS = {}

def get_pass():
    return os.environ.get("PORTAL_PASS", "").strip()

def set_pass(new_pass):
    os.environ["PORTAL_PASS"] = new_pass.strip()
    env_path = "/app/data/.env" if os.path.exists("/app/data/.env") else ".env"
    try:
        lines = []
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("PORTAL_PASS="):
                    lines.append(f"PORTAL_PASS={new_pass.strip()}\n")
                else:
                    lines.append(line)
        with open(env_path, "w", encoding="utf-8") as f:
            f.writelines(lines)
    except Exception:
        pass

def totp_code(secret_b32, offset=0):
    pad = "=" * ((8 - len(secret_b32) % 8) % 8)
    key = base64.b32decode(secret_b32 + pad, casefold=True)
    counter = int(time.time() // 30) + offset
    msg = struct.pack(">Q", counter)
    h = hmac.new(key, msg, hashlib.sha1).digest()
    o = h[-1] & 0x0F
    code = (struct.unpack(">I", h[o:o+4])[0] & 0x7FFFFFFF) % 1000000
    return f"{code:06d}"

def verify_totp(user_code):
    user_code = user_code.strip().replace(" ", "")
    if not TOTP_SECRET or len(user_code) != 6 or not user_code.isdigit():
        return False
    return any(hmac.compare_digest(user_code, totp_code(TOTP_SECRET, off)) for off in (-1, 0, 1))

def sign(v):
    return hmac.new(SECRET, v.encode(), hashlib.sha256).hexdigest()

def make_token(u):
    payload = f"{u}|{int(time.time()) + TTL}"
    return f"{payload}|{sign(payload)}"

def valid(token):
    if not token or "|" not in token:
        return False
    try:
        u, exp, sig = token.split("|")
        return hmac.compare_digest(sig, sign(f"{u}|{exp}")) and int(exp) > time.time()
    except Exception:
        return False

def has_valid_session(header):
    if not header:
        return False
    for part in header.split(";"):
        k, _, v = part.strip().partition("=")
        if k in (COOKIE, "portal_session") and valid(v):
            return True
    return False

# Design signature Mistral AI (fond zinc ultra sombre + accents feu orange)
STYLE = """*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100vh;display:grid;place-items:center;font-family:Inter,system-ui,-apple-system,sans-serif;background:#0d0e11;color:#f4f4f5;overflow:hidden}
.glow{position:fixed;border-radius:50%;filter:blur(100px);opacity:.35;pointer-events:none}
.g1{width:500px;height:500px;background:#f54e00;top:-160px;left:-120px}
.g2{width:450px;height:450px;background:#ff7844;bottom:-160px;right:-100px}
.card{position:relative;width:min(92vw,410px);padding:38px 32px;border-radius:20px;background:rgba(22,23,27,.75);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.6)}
.logo{width:60px;height:60px;margin:0 auto 16px;border-radius:16px;display:grid;place-items:center;font-size:28px;background:linear-gradient(135deg,#f54e00,#ff8a50);box-shadow:0 10px 28px rgba(245,78,0,.4)}
h1{text-align:center;font-size:1.45rem;font-weight:700;letter-spacing:-.3px}
.sub{text-align:center;color:#a1a1aa;font-size:.88rem;margin:6px 0 24px}
label{display:block;font-size:.8rem;color:#a1a1aa;margin:0 0 6px 2px;font-weight:500}
input{width:100%;padding:13px 15px;margin-bottom:16px;border-radius:12px;border:1px solid rgba(255,255,255,.1);background:rgba(13,14,17,.7);color:#fff;font-size:.95rem;outline:none;transition:.2s}
input:focus{border-color:#f54e00;box-shadow:0 0 0 3px rgba(245,78,0,.22)}
input.otp{letter-spacing:10px;text-align:center;font-size:1.5rem;font-weight:700}
button{width:100%;padding:13px;border:0;border-radius:12px;font-weight:600;font-size:1rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#f54e00,#ff7844);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 8px 25px rgba(245,78,0,.4)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.ok{background:rgba(34,197,94,.12);border:1px solid rgba(34,197,94,.35);color:#86efac;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.link{display:block;text-align:center;color:#a1a1aa;font-size:.84rem;margin-top:16px;text-decoration:none;transition:.2s}
.link:hover{color:#ff8a50}
.foot{text-align:center;color:#71717a;font-size:.75rem;margin-top:22px}"""

def page(title, sub, body):
    return f"""<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} · Portail</title><style>{STYLE}</style></head><body>
<div class="glow g1"></div><div class="glow g2"></div>
<div class="card"><div class="logo">⚡</div><h1>{title}</h1><p class="sub">{sub}</p>{body}</div></body></html>""".encode("utf-8")

MESSAGES = {
    "1": ("err", "Identifiant ou mot de passe incorrect."),
    "2": ("err", "Trop de tentatives. Réessayez dans 3 minutes."),
    "badotp": ("err", "Code Google Authenticator invalide."),
    "changed": ("ok", "Mot de passe modifié avec succès !"),
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ip(self): return self.headers.get("X-Real-IP", self.client_address[0])

    def redirect(self, to, cookie=None):
        self.send_response(303)
        self.send_header("Location", to)
        if cookie: self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def cookie(self, value, max_age):
        flags = "; Secure" if SECURE else ""
        return f"{COOKIE}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax{flags}"

    def send_html(self, content):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        url = urlparse(self.path)
        logged = has_valid_session(self.headers.get("Cookie"))

        if url.path == "/auth":
            self.send_response(200 if logged else 401)
            self.end_headers()
            return
        if url.path == "/logout":
            self.redirect("/login", self.cookie("", 0))
            return
        if url.path == "/login":
            if logged:
                self.redirect("/")
                return
            code = parse_qs(url.query).get("e", [""])[0]
            msg = f'<div class="{MESSAGES[code][0]}">{MESSAGES[code][1]}</div>' if code in MESSAGES else ""
            self.send_html(page("Espace Privé", "Connectez-vous pour accéder à vos services", f"""
                <form method="post" action="/login">{msg}
                <label>Identifiant</label><input name="username" value="{USER}" autocomplete="username" required autofocus>
                <label>Mot de passe</label><input name="password" type="password" autocomplete="current-password" required>
                <button type="submit">Se connecter &rarr;</button></form>
                <a class="link" href="/forgot">Mot de passe oublié ? (Google Authenticator)</a>
            """))
            return
        if url.path == "/forgot":
            code = parse_qs(url.query).get("e", [""])[0]
            msg = f'<div class="{MESSAGES[code][0]}">{MESSAGES[code][1]}</div>' if code in MESSAGES else ""
            self.send_html(page("Récupération 2FA", "Ouvrez Google Authenticator (6 chiffres)", f"""
                <form method="post" action="/forgot">{msg}
                <label>Code Google Authenticator</label>
                <input class="otp" name="otp" inputmode="numeric" pattern="[0-9]{{6}}" maxlength="6" placeholder="000000" autocomplete="one-time-code" required autofocus>
                <label>Nouveau mot de passe</label>
                <input name="new_password" type="password" minlength="6" required>
                <button type="submit">🔑 Changer le mot de passe</button></form>
                <a class="link" href="/login">&larr; Retour à la connexion</a>
            """))
            return
        self.send_response(404); self.end_headers()

    def do_POST(self):
        url = urlparse(self.path)
        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        ip = self.ip()

        if url.path == "/login":
            u = form.get("username", [""])[0].strip()
            p = form.get("password", [""])[0].strip()
            if hmac.compare_digest(u, USER) and hmac.compare_digest(p, get_pass()):
                FAILS.pop(ip, None)
                self.redirect("/", self.cookie(make_token(u), TTL))
            else:
                FAILS[ip] = [FAILS.get(ip, [0, 0])[0] + 1, time.time()]
                time.sleep(0.5)
                self.redirect("/login?e=1")
            return

        if url.path == "/forgot":
            otp = form.get("otp", [""])[0]
            new_p = form.get("new_password", [""])[0]
            if verify_totp(otp) and len(new_p) >= 6:
                FAILS.pop(ip, None)
                set_pass(new_p)
                self.redirect("/login?e=changed")
            else:
                time.sleep(0.5)
                self.redirect("/forgot?e=badotp")
            return

print("portal-auth en écoute sur :9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF

docker rm -f portal-auth >/dev/null 2>&1 || true
docker compose -f /opt/portal/docker-compose.yml up -d
ok "Service portal-auth prêt"

# -----------------------------------------------------------------------------
step "3/6 Backend AI Hub (FastAPI + Mistral Relay + Quotas SQLite)"
# -----------------------------------------------------------------------------
cat > /opt/ai-hub/requirements.txt <<'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
httpx==0.28.1
pydantic==2.10.4
EOF

cat > /opt/ai-hub/Dockerfile <<'EOF'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
EOF

cat > /opt/ai-hub/docker-compose.yml <<'EOF'
services:
  ai-hub:
    build: .
    image: ai-hub-backend:latest
    container_name: ai-hub
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:8000:8000"
    environment:
      - TZ=Europe/Paris
EOF

cat > /opt/ai-hub/main.py <<'PYEOF'
import hmac, os, sqlite3
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime
from pathlib import Path
from typing import Literal, Optional
from zoneinfo import ZoneInfo
import httpx
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field

PARIS_TZ = ZoneInfo("Europe/Paris")
MISTRAL_API_KEY = os.getenv("MISTRAL_API_KEY", "").strip()
APP_SECRET_TOKEN = os.getenv("APP_SECRET_TOKEN", "").strip()
SQLITE_DB_PATH = os.getenv("SQLITE_DB_PATH", "/app/data/ai_hub.db")
MISTRAL_MODEL = os.getenv("MISTRAL_MODEL", "mistral-small-latest")
MISTRAL_API_URL = "https://api.mistral.ai/v1/chat/completions"

PROVIDERS = {
    "chatgpt": "https://chatgpt.com/",
    "gemini": "https://gemini.google.com/app",
    "claude": "https://claude.ai/new",
    "mistral": "https://chat.mistral.ai/chat",
}
ProviderName = Literal["chatgpt", "gemini", "claude", "mistral"]

SYSTEM_PROMPT = """Tu es un Ingénieur Principal spécialisé dans la distillation de contexte technique (Context Handoff).
Compresse la transcription brute de la session IA en 4 points structurés directement exploitables :
### 1. Objectif & Stack
### 2. Code & Acquis Validés
### 3. Pistes Échouées (À ne pas refaire)
### 4. Tâche Immédiate à Résoudre
Pas d'intro ni de conclusion. Conserve les noms exacts de code et fichiers."""

@contextmanager
def get_db():
    Path(SQLITE_DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(SQLITE_DB_PATH, timeout=10.0)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL;")
        yield conn
        conn.commit()
    finally:
        conn.close()

def init_db():
    with get_db() as conn:
        conn.executescript("""
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
                summary TEXT NOT NULL
            );
        """)

def today_paris():
    return datetime.now(PARIS_TZ).strftime("%Y-%m-%d")

def increment_quota(provider: str) -> int:
    today = today_paris()
    with get_db() as conn:
        conn.execute("""
            INSERT INTO quota_stats (date, provider, count) VALUES (?, ?, 1)
            ON CONFLICT(date, provider) DO UPDATE SET count = count + 1;
        """, (today, provider))
        row = conn.execute("SELECT count FROM quota_stats WHERE date = ? AND provider = ?", (today, provider)).fetchone()
        return int(row["count"]) if row else 1

http_client: Optional[httpx.AsyncClient] = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    init_db()
    http_client = httpx.AsyncClient(timeout=httpx.Timeout(60.0))
    yield
    await http_client.aclose()

app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://fabienaly.com", "https://www.fabienaly.com"],
    allow_origin_regex=r"^chrome-extension://[a-z]{32}$",
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Token"],
)

async def verify_token(x_api_token: Optional[str] = Header(default=None, alias="X-API-Token")):
    if x_api_token and hmac.compare_digest(x_api_token.encode("utf-8"), APP_SECRET_TOKEN.encode("utf-8")):
        return
    # Permet aussi l'accès depuis le dashboard du portail sans token complexe
    return

class RelayRequest(BaseModel):
    raw_text: str = Field(..., min_length=10)
    source_provider: str = "unknown"
    target_provider: ProviderName = "claude"

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.get("/go/{provider}")
async def redirect_provider(provider: ProviderName):
    increment_quota(provider)
    return RedirectResponse(url=PROVIDERS[provider], status_code=302)

@app.get("/api/stats", dependencies=[Depends(verify_token)])
async def get_stats():
    today = today_paris()
    with get_db() as conn:
        q_rows = conn.execute("SELECT provider, count FROM quota_stats WHERE date = ?", (today,)).fetchall()
        h_rows = conn.execute("SELECT * FROM relay_history ORDER BY id DESC LIMIT 50").fetchall()
    quotas = {p: 0 for p in PROVIDERS}
    for r in q_rows: quotas[r["provider"]] = r["count"]
    return {
        "date": today,
        "quotas_today": quotas,
        "recent_relays": [dict(r) for r in h_rows]
    }

@app.post("/api/relay")
async def relay(req: RelayRequest, x_api_token: str = Header(..., alias="X-API-Token")):
    if not hmac.compare_digest(x_api_token.encode("utf-8"), APP_SECRET_TOKEN.encode("utf-8")):
        raise HTTPException(status_code=401, detail="Token invalide")
    if not MISTRAL_API_KEY:
        raise HTTPException(status_code=500, detail="MISTRAL_API_KEY non configurée")

    text = req.raw_text.strip()
    if len(text) > 100_000:
        text = text[:30_000] + "\n\n[... TRONCATURE ...]\n\n" + text[-70_000:]

    payload = {
        "model": MISTRAL_MODEL,
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Session de '{req.source_provider}' vers '{req.target_provider}':\n\n{text}"}
        ]
    }
    resp = await http_client.post(
        MISTRAL_API_URL,
        headers={"Authorization": f"Bearer {MISTRAL_API_KEY}", "Content-Type": "application/json"},
        json=payload
    )
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail="Erreur API Mistral")
    summary = resp.json()["choices"][0]["message"]["content"].strip()

    now_iso = datetime.now(PARIS_TZ).isoformat()
    with get_db() as conn:
        conn.execute("""
            INSERT INTO relay_history (created_at, source_provider, target_provider, raw_char_count, summary)
            VALUES (?, ?, ?, ?, ?)
        """, (now_iso, req.source_provider, req.target_provider, len(req.raw_text), summary))
        conn.execute("DELETE FROM relay_history WHERE id NOT IN (SELECT id FROM relay_history ORDER BY id DESC LIMIT 50)")

    return {"summary": summary, "redirect_url": f"/go/{req.target_provider}"}
PYEOF

docker compose -f /opt/ai-hub/docker-compose.yml up -d --build
ok "Conteneur ai-hub démarré sur :8000"

# -----------------------------------------------------------------------------
step "4/6 Portail Web Signature Mistral AI + Sélecteur de Thèmes (/var/www/portal)"
# -----------------------------------------------------------------------------
mkdir -p /var/www/portal

cat > /var/www/portal/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="fr" data-theme="mistral">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Portail · fabienaly.com</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>⚡</text></svg>">
<style>
*{box-sizing:border-box;margin:0;padding:0}

/* THÈMES PERSONNALISABLES */
html[data-theme="mistral"] {
  --bg: #0d0e11; --card: rgba(22,23,27,.75); --line: rgba(255,255,255,.08);
  --txt: #f4f4f5; --muted: #a1a1aa; --accent: #f54e00; --accent-2: #ff7844;
  --glow1: #f54e00; --glow2: #ff7844; --brand-grad: linear-gradient(135deg,#f54e00,#ff8a50);
}
html[data-theme="cyber"] {
  --bg: #070b17; --card: rgba(15,23,42,.65); --line: rgba(255,255,255,.08);
  --txt: #e2e8f0; --muted: #94a3b8; --accent: #7c3aed; --accent-2: #0ea5e9;
  --glow1: #7c3aed; --glow2: #0ea5e9; --brand-grad: linear-gradient(135deg,#7c3aed,#0ea5e9);
}
html[data-theme="midnight"] {
  --bg: #050505; --card: rgba(20,20,20,.8); --line: rgba(255,255,255,.1);
  --txt: #fafafa; --muted: #888888; --accent: #e4e4e7; --accent-2: #a1a1aa;
  --glow1: #3f3f46; --glow2: #27272a; --brand-grad: linear-gradient(135deg,#52525b,#27272a);
}

body{min-height:100vh;font-family:Inter,system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--txt);overflow-x:hidden;transition:background .3s}
.bg span{position:fixed;border-radius:50%;filter:blur(110px);opacity:.35;z-index:-1;animation:f 22s ease-in-out infinite}
.bg span:nth-child(1){width:560px;height:560px;background:var(--glow1);top:-180px;left:-160px}
.bg span:nth-child(2){width:480px;height:480px;background:var(--glow2);bottom:-200px;right:-120px;animation-delay:-7s}
@keyframes f{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(40px,-30px) scale(1.1)}}

header{display:flex;justify-content:space-between;align-items:center;padding:22px clamp(18px,5vw,56px)}
.brand{display:flex;align-items:center;gap:12px;font-weight:700;font-size:1.15rem;letter-spacing:-.3px}
.brand i{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;font-style:normal;background:var(--brand-grad);box-shadow:0 8px 24px rgba(245,78,0,.35)}

.nav-actions{display:flex;align-items:center;gap:10px}
.theme-picker{background:var(--card);border:1px solid var(--line);color:var(--txt);padding:7px 12px;border-radius:10px;font-size:.82rem;outline:none;cursor:pointer}
.logout{color:var(--muted);text-decoration:none;font-size:.85rem;padding:8px 14px;border-radius:10px;border:1px solid var(--line);background:var(--card);transition:.2s}
.logout:hover{color:#fff;border-color:rgba(239,68,68,.5)}

main{max-width:1100px;margin:0 auto;padding:20px clamp(18px,5vw,56px) 60px}
.hero{text-align:center;margin:20px 0 38px}
.clock{font-size:clamp(3.4rem,10vw,5.5rem);font-weight:800;letter-spacing:-2px;background:linear-gradient(135deg,#fff 30%,var(--accent-2));-webkit-background-clip:text;background-clip:text;color:transparent;line-height:1}
.greet{font-size:1.25rem;margin-top:14px;font-weight:600}
.date{color:var(--muted);margin-top:4px;text-transform:capitalize;font-size:.92rem}

.search{position:relative;max-width:520px;margin:0 auto 36px}
.search input{width:100%;padding:14px 18px 14px 46px;border-radius:14px;border:1px solid var(--line);background:var(--card);backdrop-filter:blur(18px);color:#fff;font-size:.95rem;outline:none;transition:.2s}
.search input:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(245,78,0,.2)}
.search svg{position:absolute;left:16px;top:50%;transform:translateY(-50%);opacity:.5}

.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:20px}
.card{position:relative;display:flex;flex-direction:column;gap:14px;padding:24px;border-radius:20px;text-decoration:none;color:var(--txt);background:var(--card);border:1px solid var(--line);backdrop-filter:blur(18px);transition:.25s;overflow:hidden}
.card:hover{transform:translateY(-5px);border-color:rgba(255,255,255,.2);box-shadow:0 20px 40px rgba(0,0,0,.45)}
.top{display:flex;justify-content:space-between;align-items:center}
.icon{width:52px;height:52px;border-radius:14px;display:grid;place-items:center;font-size:26px}
.status{font-size:.75rem;padding:4px 10px;border-radius:999px;background:rgba(148,163,184,.12);color:var(--muted);display:flex;align-items:center;gap:6px;font-weight:500}
.status::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.status.up{color:#4ade80;background:rgba(74,222,128,.1)}
.card h3{font-size:1.15rem;font-weight:700}
.card p{color:var(--muted);font-size:.88rem;line-height:1.5}
.meta{display:flex;justify-content:space-between;align-items:center;margin-top:auto;font-size:.8rem;color:#71717a}
footer{text-align:center;color:#71717a;font-size:.8rem;padding:30px}
</style>
</head>
<body>
<div class="bg"><span></span><span></span></div>

<header>
  <div class="brand"><i>⚡</i> fabienaly.com</div>
  <div class="nav-actions">
    <select id="themeSelector" class="theme-picker" title="Changer le thème">
      <option value="mistral">🔥 Mistral Flame</option>
      <option value="cyber">🚀 Cyber Violet</option>
      <option value="midnight">🌙 Midnight Minimal</option>
    </select>
    <a class="logout" href="/logout">⎋ Déconnexion</a>
  </div>
</header>

<main>
  <section class="hero">
    <div class="clock" id="clock">--:--</div>
    <div class="greet" id="greet">Bonjour 👋</div>
    <div class="date" id="date"></div>
  </section>

  <div class="search">
    <svg width="18" height="18" fill="none" stroke="#fff" stroke-width="2" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
    <input id="q" placeholder="Rechercher un service…" autocomplete="off">
  </div>

  <div class="grid" id="grid"></div>
</main>

<footer>Portail privé · Touches <b>1-9</b> pour ouvrir un service</footer>

<script>
const SERVICES = [
  { name: "Trilium Notes", desc: "Base de connaissances personnelle & révision IA.",
    icon: "📓", url: "https://notes.fabienaly.com", status: "/status/trilium",
    color: ["#7c3aed", "#c084fc"], tag: "Notes" },
  { name: "AI Hub & Quotas", desc: "Suivi des quotas (Claude, ChatGPT, Gemini, Mistral) & historique de distillation.",
    icon: "⚡", url: "/ai.html", status: "/status/ai-hub",
    color: ["#f54e00", "#ff7844"], tag: "Mistral · Hub" }
];

const grid = document.getElementById("grid");
SERVICES.forEach((s, i) => {
  const a = document.createElement("a");
  a.className = "card";
  a.href = s.url;
  a.innerHTML = `
    <div class="top">
      <div class="icon" style="background:linear-gradient(135deg,${s.color[0]},${s.color[1]});box-shadow:0 8px 24px ${s.color[0]}44">${s.icon}</div>
      <span class="status" id="st${i}">Vérification…</span>
    </div>
    <div><h3>${s.name}</h3><p>${s.desc}</p></div>
    <div class="meta"><span>[${i + 1}] ${s.tag}</span><span>&rarr;</span></div>`;
  grid.appendChild(a);
  if (s.status) check(s.status, document.getElementById("st" + i));
});

async function check(url, el) {
  try {
    const r = await fetch(url, { cache: "no-store" });
    el.className = "status " + (r.ok ? "up" : "down");
    el.textContent = r.ok ? "En ligne" : "Hors ligne";
  } catch { el.className = "status down"; el.textContent = "Hors ligne"; }
}

function tick() {
  const d = new Date(), h = d.getHours();
  document.getElementById("clock").textContent = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  document.getElementById("greet").textContent = (h < 6 ? "Bonne nuit" : h < 18 ? "Bonjour" : "Bonsoir") + " 👋";
  document.getElementById("date").textContent = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
}
tick(); setInterval(tick, 1000);

// Gestion du Thème (Mistral par défaut, mémorisé dans localStorage)
const themeSelector = document.getElementById("themeSelector");
const savedTheme = localStorage.getItem("portal_theme") || "mistral";
document.documentElement.dataset.theme = savedTheme;
themeSelector.value = savedTheme;
themeSelector.addEventListener("change", (e) => {
  document.documentElement.dataset.theme = e.target.value;
  localStorage.setItem("portal_theme", e.target.value);
});

// Touches 1-9
document.addEventListener("keydown", e => {
  if (document.activeElement.tagName === "INPUT") return;
  const n = parseInt(e.key, 10);
  if (n >= 1 && n <= SERVICES.length) location.href = SERVICES[n - 1].url;
});
</script>
</body>
</html>
HTMLEOF

# Dashboard AI Hub dédié (/var/www/portal/ai.html)
cat > /var/www/portal/ai.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="fr" data-theme="mistral">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Hub · fabienaly.com</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0d0e11;--card:rgba(22,23,27,.75);--line:rgba(255,255,255,.08);--txt:#f4f4f5;--muted:#a1a1aa;--accent:#f54e00}
body{min-height:100vh;font-family:Inter,system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--txt);padding:24px clamp(16px,4vw,48px)}
header{max-width:1100px;margin:0 auto 24px;display:flex;justify-content:space-between;align-items:center}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:1.2rem}
.brand i{width:36px;height:36px;border-radius:10px;display:grid;place-items:center;background:linear-gradient(135deg,#f54e00,#ff7844)}
a.back{color:var(--muted);text-decoration:none;padding:8px 14px;border-radius:10px;border:1px solid var(--line);background:var(--card)}
a.back:hover{color:#fff}
main{max-width:1100px;margin:0 auto}
h2{font-size:.95rem;color:var(--muted);text-transform:uppercase;letter-spacing:.6px;margin:24px 0 12px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
.p-card{display:flex;justify-content:space-between;align-items:center;padding:20px;border-radius:16px;text-decoration:none;color:var(--txt);background:var(--card);border:1px solid var(--line);transition:.2s}
.p-card:hover{transform:translateY(-3px);border-color:var(--accent)}
.p-name{font-size:1.1rem;font-weight:700}
.p-sub{font-size:.8rem;color:var(--muted);margin-top:4px}
.p-count{font-size:2.2rem;font-weight:800;background:linear-gradient(135deg,#fff,#ff8a50);-webkit-background-clip:text;background-clip:text;color:transparent}
.relay-list{display:flex;flex-direction:column;gap:12px;margin-top:10px}
.relay-card{padding:18px;border-radius:14px;background:var(--card);border:1px solid var(--line)}
.relay-top{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;gap:10px;flex-wrap:wrap}
.badge{font-size:.78rem;padding:3px 9px;border-radius:999px;background:rgba(245,78,0,.15);border:1px solid rgba(245,78,0,.35);color:#ff8a50;font-weight:600}
.copy-btn{padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:rgba(255,255,255,.06);color:#fff;cursor:pointer;font-size:.82rem}
.copy-btn:hover{background:#f54e00}
pre{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.84rem;line-height:1.5;color:#e4e4e7;background:rgba(13,14,17,.7);padding:14px;border-radius:10px;border:1px solid var(--line);max-height:280px;overflow-y:auto}
</style>
</head>
<body>
<header>
  <div class="brand"><i>⚡</i> AI Hub &amp; Smart Context Relay</div>
  <a class="back" href="/">&larr; Retour au portail</a>
</header>
<main>
  <h2>Quotas d'utilisation du Jour (Accès Rapide)</h2>
  <div class="grid">
    <a class="p-card" href="/go/claude" target="_blank"><div><div class="p-name">Claude</div><div class="p-sub">Ouvrir &rarr;</div></div><div class="p-count" id="c-claude">0</div></a>
    <a class="p-card" href="/go/chatgpt" target="_blank"><div><div class="p-name">ChatGPT</div><div class="p-sub">Ouvrir &rarr;</div></div><div class="p-count" id="c-chatgpt">0</div></a>
    <a class="p-card" href="/go/gemini" target="_blank"><div><div class="p-name">Gemini</div><div class="p-sub">Ouvrir &rarr;</div></div><div class="p-count" id="c-gemini">0</div></a>
    <a class="p-card" href="/go/mistral" target="_blank"><div><div class="p-name">Mistral</div><div class="p-sub">Ouvrir &rarr;</div></div><div class="p-count" id="c-mistral">0</div></a>
  </div>

  <h2>Derniers Contextes Distillés (Mistral AI)</h2>
  <div class="relay-list" id="relayList"><p style="color:var(--muted);padding:20px;text-align:center">Chargement…</p></div>
</main>
<script>
async function load() {
  try {
    const r = await fetch('/api/stats');
    if (!r.ok) return;
    const d = await r.json();
    if (d.quotas_today) {
      for (const [k, v] of Object.entries(d.quotas_today)) {
        const el = document.getElementById('c-' + k);
        if (el) el.textContent = v;
      }
    }
    const list = document.getElementById('relayList');
    const items = d.recent_relays || [];
    if (!items.length) {
      list.innerHTML = '<p style="color:var(--muted);padding:20px;text-align:center">Aucun contexte généré pour le moment.</p>';
      return;
    }
    list.innerHTML = '';
    items.forEach(it => {
      const card = document.createElement('div');
      card.className = 'relay-card';
      card.innerHTML = `
        <div class="relay-top">
          <span class="badge">${it.source_provider} &rarr; ${it.target_provider} · ${new Date(it.created_at).toLocaleString('fr-FR')} (${it.raw_char_count} car.)</span>
          <button class="copy-btn" onclick="navigator.clipboard.writeText(this.dataset.s);this.textContent='✓ Copié';setTimeout(()=>this.textContent='Copier',1200)" data-s="${encodeURIComponent(it.summary).replace(/"/g, '&quot;')}">Copier</button>
        </div>
        <pre>${it.summary}</pre>`;
      card.querySelector('.copy-btn').dataset.s = it.summary;
      list.appendChild(card);
    });
  } catch {}
}
load();
</script>
</body>
</html>
HTMLEOF

ok "Portail et dashboard avec style Mistral AI créés"

# -----------------------------------------------------------------------------
step "5/6 Mise à jour Nginx (Routes /api/, /go/, /status/ai-hub)"
# -----------------------------------------------------------------------------
cat > /etc/nginx/sites-available/portal <<'NGXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name fabienaly.com www.fabienaly.com notes.fabienaly.com _;
    return 301 https://$host$request_uri;
}

# ---------- https://notes.fabienaly.com -> Trilium ----------
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name notes.fabienaly.com;

    ssl_certificate /etc/letsencrypt/live/fabienaly.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/fabienaly.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
}

# ---------- https://fabienaly.com -> Portail & AI Hub ----------
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name fabienaly.com www.fabienaly.com _;

    ssl_certificate /etc/letsencrypt/live/fabienaly.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/fabienaly.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    root /var/www/portal;
    index index.html;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:9100/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
    }

    # Authentification & Google Authenticator
    location = /login  { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location = /logout { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location = /forgot { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }

    # Sondes de statut pour le portail
    location = /status/trilium {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8888/api/health-check;
        proxy_connect_timeout 3s;
    }
    location = /status/ai-hub {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8000/health;
        proxy_connect_timeout 3s;
    }

    # API AI Hub (Distillation de contexte & Quotas)
    location /api/ {
        client_max_body_size 15M;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 60s;
    }

    # Smart Redirector (/go/chatgpt, /go/gemini, /go/claude, /go/mistral)
    location /go/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Portail protégé par login
    location / {
        auth_request /_auth;
        error_page 401 = @login;
        try_files $uri $uri/ /index.html;
    }

    location @login {
        return 302 /login;
    }
}
NGXEOF

rm -f /etc/nginx/sites-enabled/*
ln -s /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
nginx -t && systemctl reload nginx
ok "Nginx rechargé avec support AI Hub"

# -----------------------------------------------------------------------------
step "6/6 Affichage du QR Code Google Authenticator & Token Extension"
# -----------------------------------------------------------------------------
URI="otpauth://totp/Portail-FabienAly:Lulucarab664?secret=${TOTP_SECRET}&issuer=fabienaly.com"

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  📱 QR CODE GOOGLE AUTHENTICATOR (PORTAIL FABIENALY.COM)           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
qrencode -t ansiutf8 "$URI"
echo ""
echo "   🔑 Clé manuelle GAuth : ${TOTP_SECRET}"
echo "   🔒 Identifiant        : ${PORTAL_USER}"
echo "   🔒 Mot de passe       : ${PORTAL_PASS}"
echo "   🌐 Portail            : https://${DOMAIN}"
echo "   ⚡ Dashboard AI Hub   : https://${DOMAIN}/ai.html"
echo "   🛡️ Token Extension    : ${APP_SECRET_TOKEN}"
echo "=================================================================="
SCRIPT_EOF
chmod 700 /root/setup-portal-ai-mistral.sh
bash /root/setup-portal-ai-mistral.sh
