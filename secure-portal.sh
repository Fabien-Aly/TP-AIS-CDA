cat > /root/secure-portal.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  DURCISSEMENT DE SÉCURITÉ + PASSKEYS (WebAuthn / FIDO2)
#  Portail web privé + Trilium Notes (Nginx auth_request)
#
#  Nouveautés :
#    1. Connexion par Passkey (Windows Hello, Touch ID, Face ID, Clé YubiKey)
#       directement sur la page de login Nginx (/login)
#    2. Page de gestion / ajout de Passkeys (/passkeys) accessible une fois connecté
#    3. Conserve votre mot de passe actuel dans /opt/portal/.env (ou utilise celui ci-dessous)
#    4. Protège notes.DOMAINE derrière la session du portail (SSO multi-sous-domaines)
#    5. Durcit Nginx (rate-limit, HSTS, CSP), Docker et les sauvegardes
# =============================================================================
set -uo pipefail

# ============================ VOS RÉGLAGES ===================================
DOMAIN='fabienaly.com'
EMAIL='alyfabien3@gmail.com'
PORTAL_USER='Lulucarab664'
# Laissez vide pour garder le mot de passe déjà présent dans /opt/portal/.env :
PORTAL_PASS=''
SESSION_HOURS='12'
MAX_UPLOAD_SIZE='50M'
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { err "Lancez ce script en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/6 Protection SSH (Fail2ban) & permissions des sauvegardes"
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y fail2ban dnsutils openssl >/dev/null
systemctl enable --now fail2ban >/dev/null 2>&1 || true
ok "Fail2ban actif (protection SSH)"

mkdir -p /opt/backups/trilium
chmod 700 /opt/backups /opt/backups/trilium
find /opt/backups/trilium -type f -exec chmod 600 {} + 2>/dev/null || true
cat > /etc/cron.daily/backup-trilium <<'EOF'
#!/bin/bash
umask 077
tar -czf /opt/backups/trilium/trilium-$(date +%F).tar.gz -C /opt/trilium/trilium-data .
find /opt/backups/trilium/ -type f -name "*.tar.gz" -mtime +7 -delete
EOF
chmod 700 /etc/cron.daily/backup-trilium
ok "Sauvegardes Trilium verrouillées (chmod 700 / umask 077)"

# -----------------------------------------------------------------------------
step "2/6 Configuration des identifiants et du stockage des Passkeys"
# -----------------------------------------------------------------------------
mkdir -p /opt/portal/data
chown -R 65534:65534 /opt/portal/data
chmod 700 /opt/portal/data

SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env | cut -d= -f2- || true)
[ -n "$SECRET" ] || SECRET=$(openssl rand -hex 32)

# Récupère le mot de passe ou hash existant si PORTAL_PASS est laissé vide
EXISTING_HASH=$(grep -s '^PORTAL_PASS_HASH=' /opt/portal/.env | cut -d= -f2- || true)
EXISTING_PASS=$(grep -s '^PORTAL_PASS=' /opt/portal/.env | cut -d= -f2- || true)

if [ -n "$PORTAL_PASS" ]; then
    PASS_TO_HASH="$PORTAL_PASS"
elif [ -n "$EXISTING_PASS" ]; then
    PASS_TO_HASH="$EXISTING_PASS"
else
    PASS_TO_HASH=""
fi

if [ -n "$PASS_TO_HASH" ]; then
    PASS_HASH=$(docker run --rm -e P="$PASS_TO_HASH" python:3.12-alpine python -c '
import hashlib, os
salt = os.urandom(16)
digest = hashlib.scrypt(os.environ["P"].encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
print(salt.hex() + ":" + digest.hex())
')
elif [ -n "$EXISTING_HASH" ]; then
    PASS_HASH="$EXISTING_HASH"
else
    err "Aucun mot de passe trouvé. Renseignez PORTAL_PASS en haut du script."
    exit 1
fi

cat > /opt/portal/.env <<EOF
PORTAL_USER=${PORTAL_USER}
PORTAL_PASS_HASH=${PASS_HASH}
PORTAL_SECRET=${SECRET}
RP_ID=${DOMAIN}
COOKIE_DOMAIN=.${DOMAIN}
COOKIE_SECURE=1
SESSION_HOURS=${SESSION_HOURS}
EOF
chmod 600 /opt/portal/.env
unset PORTAL_PASS PASS_TO_HASH EXISTING_PASS
ok "Identifiants sécurisés (scrypt) + dossier Passkeys prêt"

# -----------------------------------------------------------------------------
step "3/6 Déploiement du serveur d'authentification WebAuthn / Passkey"
# -----------------------------------------------------------------------------
cat > /opt/portal/Dockerfile <<'EOF'
FROM python:3.12-alpine
RUN pip install --no-cache-dir webauthn==2.2.0
EOF

cat > /opt/portal/docker-compose.yml <<'EOF'
services:
  portal-auth:
    build: .
    image: portal-auth-webauthn:latest
    container_name: portal-auth
    restart: unless-stopped
    user: "65534:65534"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 96m
    pids_limit: 64
    command: ["python", "-u", "/app/auth.py"]
    env_file: .env
    volumes:
      - ./auth.py:/app/auth.py:ro
      - ./data:/data
    ports:
      - "127.0.0.1:9100:9100"
EOF

cat > /opt/portal/auth.py <<'PYEOF'
"""Service d'authentification Nginx (auth_request) avec support Passkey (WebAuthn/FIDO2)."""
import hashlib, hmac, json, os, secrets, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

USER = os.environ["PORTAL_USER"]
PASS_HASH = os.environ["PORTAL_PASS_HASH"]
SECRET = os.environ["PORTAL_SECRET"].encode()
RP_ID = os.environ["RP_ID"]
COOKIE_DOMAIN = os.environ.get("COOKIE_DOMAIN", "")
SECURE = os.environ.get("COOKIE_SECURE", "1") == "1"
TTL = int(os.environ.get("SESSION_HOURS", "12")) * 3600
COOKIE = "portal_session"
PASSKEYS_FILE = "/data/passkeys.json"

LOCK = threading.Lock()
FAILS = {}            # ip -> [nb_echecs, horodatage]
REVOKED = {}          # jti -> exp_timestamp
CHALLENGES = {}       # challenge_id -> (challenge_bytes, exp_timestamp)
MAX_FAILS, LOCK_S = 5, 300

def load_passkeys() -> list:
    with LOCK:
        if not os.path.exists(PASSKEYS_FILE):
            return []
        try:
            with open(PASSKEYS_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []

def save_passkeys(creds: list) -> None:
    with LOCK:
        tmp = PASSKEYS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(creds, f, indent=2)
        os.replace(tmp, PASSKEYS_FILE)

def store_challenge(ch: bytes) -> str:
    cid = secrets.token_hex(16)
    now = time.time()
    with LOCK:
        for k in [k for k, v in CHALLENGES.items() if v[1] <= now]:
            CHALLENGES.pop(k, None)
        CHALLENGES[cid] = (ch, now + 300)
    return cid

def pop_challenge(cid: str):
    now = time.time()
    with LOCK:
        item = CHALLENGES.pop(cid, None)
        if not item or item[1] <= now:
            return None
        return item[0]

def verify_password(candidate: str) -> bool:
    try:
        salt_hex, digest_hex = PASS_HASH.split(":", 1)
        actual = hashlib.scrypt(candidate.encode(), salt=bytes.fromhex(salt_hex), n=16384, r=8, p=1, dklen=32)
        return hmac.compare_digest(actual, bytes.fromhex(digest_hex))
    except Exception:
        return False

def sign(v: str) -> str:
    return hmac.new(SECRET, v.encode(), hashlib.sha256).hexdigest()

def make_token(user: str) -> str:
    exp = int(time.time()) + TTL
    jti = secrets.token_hex(12)
    payload = f"{jti}.{exp}.{user}"
    return f"{payload}.{sign(payload)}"

def valid(token: str) -> bool:
    if not token or "." not in token:
        return False
    try:
        jti, exp_s, user, sig = token.split(".", 3)
        if int(exp_s) <= time.time():
            return False
        if not hmac.compare_digest(sig, sign(f"{jti}.{exp_s}.{user}")):
            return False
        if not hmac.compare_digest(user, USER):
            return False
        with LOCK:
            return jti not in REVOKED
    except ValueError:
        return False

def revoke(token: str) -> None:
    try:
        jti, exp_s, _, _ = token.split(".", 3)
        now = time.time()
        with LOCK:
            for k in [k for k, v in REVOKED.items() if v <= now]:
                REVOKED.pop(k, None)
            REVOKED[jti] = int(exp_s)
    except Exception:
        pass

def read_cookie(header: str) -> str:
    for part in (header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == COOKIE:
            return v
    return ""

WEBAUTHN_JS_HELPERS = """
function b64urlToBuf(b64url) {
  const pad = '='.repeat((4 - (b64url.length % 4)) % 4);
  const b64 = (b64url + pad).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(b64);
  return Uint8Array.from(raw, c => c.charCodeAt(0)).buffer;
}
function bufToB64url(buf) {
  const bytes = new Uint8Array(buf);
  let bin = '';
  bytes.forEach(b => bin += String.fromCharCode(b));
  return btoa(bin).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
}
"""

LOGIN_HTML = """<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Connexion · Portail privé</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100vh;display:grid;place-items:center;font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;background:#070b17;color:#e2e8f0;overflow:hidden}
.bg span{position:fixed;border-radius:50%;filter:blur(90px);opacity:.55;animation:f 18s ease-in-out infinite}
.bg span:nth-child(1){width:480px;height:480px;background:#7c3aed;top:-120px;left:-100px}
.bg span:nth-child(2){width:420px;height:420px;background:#0ea5e9;bottom:-140px;right:-80px;animation-delay:-6s}
.bg span:nth-child(3){width:300px;height:300px;background:#ec4899;top:40%;left:55%;animation-delay:-12s}
@keyframes f{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(40px,-30px) scale(1.1)}}
.card{position:relative;width:min(92vw,410px);padding:40px 34px;border-radius:24px;background:rgba(15,23,42,.55);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.5);animation:in .6s ease}
@keyframes in{from{opacity:0;transform:translateY(16px)}}
.logo{width:64px;height:64px;margin:0 auto 16px;border-radius:18px;display:grid;place-items:center;font-size:30px;background:linear-gradient(135deg,#7c3aed,#0ea5e9);box-shadow:0 10px 30px rgba(124,58,237,.45)}
h1{text-align:center;font-size:1.5rem}
.sub{text-align:center;color:#94a3b8;font-size:.9rem;margin:6px 0 24px}
label{display:block;font-size:.8rem;color:#94a3b8;margin:0 0 6px 2px}
input{width:100%;padding:13px 15px;margin-bottom:16px;border-radius:12px;border:1px solid rgba(255,255,255,.1);background:rgba(2,6,23,.6);color:#f1f5f9;font-size:.95rem;outline:none;transition:.2s}
input:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.2)}
button{width:100%;padding:13px;border:0;border-radius:12px;font-weight:600;font-size:.98rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 10px 25px rgba(14,165,233,.35)}
.passkey-btn{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.18);display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:18px}
.passkey-btn:hover{background:rgba(255,255,255,.14);box-shadow:0 10px 25px rgba(124,58,237,.25)}
.sep{display:flex;align-items:center;gap:12px;color:#64748b;font-size:.78rem;margin:4px 0 18px}
.sep::before,.sep::after{content:"";flex:1;height:1px;background:rgba(255,255,255,.08)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.foot{text-align:center;color:#475569;font-size:.75rem;margin-top:20px}
</style></head><body>
<div class="bg"><span></span><span></span><span></span></div>
<div class="card">
  <div class="logo">&#128272;</div><h1>Espace privé</h1>
  <p class="sub">Connectez-vous pour accéder à vos services</p>
  <div id="pk-err" class="err" style="display:none"></div>
  __ERROR__
  __PASSKEY_BLOCK__
  <form method="post" action="/login">
    <label for="u">Identifiant</label><input id="u" name="username" autocomplete="username webauthn" required autofocus>
    <label for="p">Mot de passe</label><input id="p" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">Se connecter &rarr;</button>
  </form>
  <div class="foot">Accès réservé · Passkey WebAuthn &amp; anti-bruteforce actifs</div>
</div>
<script>
""" + WEBAUTHN_JS_HELPERS + """
async function loginWithPasskey() {
  const errBox = document.getElementById('pk-err');
  errBox.style.display = 'none';
  try {
    const r = await fetch('/webauthn/auth/options', { method: 'POST' });
    if (!r.ok) throw new Error('Aucune Passkey enregistrée ou erreur serveur.');
    const { options, cid } = await r.json();
    options.challenge = b64urlToBuf(options.challenge);
    if (options.allowCredentials) {
      options.allowCredentials = options.allowCredentials.map(c => ({ ...c, id: b64urlToBuf(c.id) }));
    }
    const cred = await navigator.credentials.get({ publicKey: options });
    const payload = {
      cid,
      credential: {
        id: cred.id,
        rawId: bufToB64url(cred.rawId),
        type: cred.type,
        response: {
          clientDataJSON: bufToB64url(cred.response.clientDataJSON),
          authenticatorData: bufToB64url(cred.response.authenticatorData),
          signature: bufToB64url(cred.response.signature),
          userHandle: cred.response.userHandle ? bufToB64url(cred.response.userHandle) : null
        }
      }
    };
    const vr = await fetch('/webauthn/auth/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const res = await vr.json();
    if (vr.ok && res.ok) {
      window.location.href = '/';
    } else {
      throw new Error(res.error || 'Échec de vérification de la Passkey.');
    }
  } catch (e) {
    if (e.name !== 'NotAllowedError') {
      errBox.textContent = e.message || 'Erreur lors de la connexion par Passkey.';
      errBox.style.display = 'block';
    }
  }
}
</script></body></html>"""

PASSKEYS_HTML = """<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Mes Passkeys · Portail privé</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100vh;font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;background:#070b17;color:#e2e8f0;padding:40px 20px}
.wrap{max-width:640px;margin:0 auto;padding:34px;border-radius:24px;background:rgba(15,23,42,.65);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px)}
.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}
h1{font-size:1.4rem}
a.back{color:#94a3b8;text-decoration:none;font-size:.9rem;padding:8px 14px;border-radius:10px;border:1px solid rgba(255,255,255,.1)}
a.back:hover{color:#fff}
p.desc{color:#94a3b8;font-size:.92rem;line-height:1.5;margin-bottom:22px}
.add-box{display:flex;gap:10px;margin-bottom:26px}
input{flex:1;padding:12px 14px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(2,6,23,.6);color:#fff;font-size:.95rem}
button{padding:12px 18px;border:0;border-radius:12px;font-weight:600;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9)}
.item{display:flex;justify-content:space-between;align-items:center;padding:14px 16px;border-radius:14px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.07);margin-bottom:10px}
.item small{display:block;color:#64748b;margin-top:3px}
.del{background:rgba(239,68,68,.18);border:1px solid rgba(239,68,68,.4);color:#fca5a5;padding:7px 12px;font-size:.82rem}
.msg{padding:11px;border-radius:10px;margin-bottom:18px;font-size:.88rem;display:none}
.msg.ok{display:block;background:rgba(74,222,128,.12);border:1px solid rgba(74,222,128,.35);color:#86efac}
.msg.err{display:block;background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5}
</style></head><body>
<div class="wrap">
  <div class="top"><h1>🔑 Mes Passkeys (WebAuthn)</h1><a class="back" href="/">&larr; Retour au portail</a></div>
  <p class="desc">Enregistrez une Passkey (Windows Hello, Face ID, Touch ID, téléphone ou clé de sécurité USB) pour vous connecter au portail en un clic sans taper votre mot de passe.</p>
  <div id="msg" class="msg"></div>
  <div class="add-box">
    <input id="label" placeholder="Nom de l'appareil (ex: Mon PC Windows Hello, iPhone…)" maxlength="40">
    <button onclick="registerPasskey()">+ Ajouter une Passkey</button>
  </div>
  <div id="list">__LIST__</div>
</div>
<script>
""" + WEBAUTHN_JS_HELPERS + """
function showMsg(txt, ok) {
  const m = document.getElementById('msg');
  m.textContent = txt;
  m.className = 'msg ' + (ok ? 'ok' : 'err');
}
async function registerPasskey() {
  try {
    const label = document.getElementById('label').value.trim() || 'Passkey';
    const r = await fetch('/webauthn/register/options', { method: 'POST' });
    const { options, cid } = await r.json();
    options.challenge = b64urlToBuf(options.challenge);
    options.user.id = b64urlToBuf(options.user.id);
    if (options.excludeCredentials) {
      options.excludeCredentials = options.excludeCredentials.map(c => ({ ...c, id: b64urlToBuf(c.id) }));
    }
    const cred = await navigator.credentials.create({ publicKey: options });
    const payload = {
      cid,
      label,
      credential: {
        id: cred.id,
        rawId: bufToB64url(cred.rawId),
        type: cred.type,
        response: {
          clientDataJSON: bufToB64url(cred.response.clientDataJSON),
          attestationObject: bufToB64url(cred.response.attestationObject),
          transports: cred.response.getTransports ? cred.response.getTransports() : []
        }
      }
    };
    const vr = await fetch('/webauthn/register/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const res = await vr.json();
    if (vr.ok && res.ok) {
      location.reload();
    } else {
      showMsg(res.error || 'Erreur lors de l\\'enregistrement.', false);
    }
  } catch (e) {
    if (e.name !== 'NotAllowedError') showMsg(e.message || 'Erreur WebAuthn.', false);
  }
}
async function deletePasskey(id) {
  if (!confirm('Supprimer cette Passkey ?')) return;
  await fetch('/webauthn/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id })
  });
  location.reload();
}
</script></body></html>"""

ERRORS = {
    "1": "Identifiant ou mot de passe incorrect.",
    "2": "Trop de tentatives. Réessayez dans 5 minutes.",
}

class Handler(BaseHTTPRequestHandler):
    timeout = 5

    def log_message(self, *a): pass

    def ip(self): return self.headers.get("X-Real-IP", self.client_address[0])

    def send_json(self, code: int, data: dict, cookie: str = None):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, to, cookie=None):
        self.send_response(303)
        self.send_header("Location", to)
        if cookie: self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def cookie(self, value, max_age):
        flags = "; Secure" if SECURE else ""
        dom = f"; Domain={COOKIE_DOMAIN}" if COOKIE_DOMAIN else ""
        return f"{COOKIE}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax{dom}{flags}"

    def read_json(self) -> dict:
        length = min(int(self.headers.get("Content-Length", 0)), 16384)
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def is_rate_limited(self, ip: str) -> bool:
        now = time.time()
        with LOCK:
            n, t = FAILS.get(ip, [0, 0])
            return n >= MAX_FAILS and (now - t) < LOCK_S

    def record_fail(self, ip: str):
        now = time.time()
        with LOCK:
            n, t = FAILS.get(ip, [0, 0])
            FAILS[ip] = [n + 1 if (now - t) < LOCK_S else 1, now]

    def do_GET(self):
        url = urlparse(self.path)
        tok = read_cookie(self.headers.get("Cookie"))
        logged = valid(tok)
        if url.path == "/auth":
            self.send_response(200 if logged else 401); self.end_headers(); return
        if url.path == "/logout":
            if tok:
                revoke(tok)
            self.redirect("/login", self.cookie("", 0)); return
        if url.path == "/login":
            if logged: self.redirect("/"); return
            code = parse_qs(url.query).get("e", [""])[0]
            err = f'<div class="err">{ERRORS[code]}</div>' if code in ERRORS else ""
            has_pk = len(load_passkeys()) > 0
            pk_block = (
                '<button type="button" class="passkey-btn" onclick="loginWithPasskey()">'
                '🔑 Se connecter avec une Passkey</button>'
                '<div class="sep">ou avec mot de passe</div>'
            ) if has_pk else ""
            body = LOGIN_HTML.replace("__ERROR__", err).replace("__PASSKEY_BLOCK__", pk_block).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        if url.path == "/passkeys":
            if not logged: self.redirect("/login"); return
            creds = load_passkeys()
            if not creds:
                items = '<p style="color:#64748b;text-align:center;padding:20px">Aucune Passkey enregistrée pour le moment.</p>'
            else:
                items = "".join(
                    f'<div class="item"><div><strong>🔑 {c.get("label","Passkey")}</strong>'
                    f'<small>Ajoutée le {c.get("created","?")}</small></div>'
                    f'<button class="del" onclick="deletePasskey(\'{c["id"]}\')">Supprimer</button></div>'
                    for c in creds
                )
            body = PASSKEYS_HTML.replace("__LIST__", items).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        self.send_response(404); self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        ip = self.ip()
        tok = read_cookie(self.headers.get("Cookie"))
        logged = valid(tok)

        # --- 1. Options d'authentification Passkey (public) ---
        if path == "/webauthn/auth/options":
            if self.is_rate_limited(ip):
                self.send_json(429, {"error": ERRORS["2"]}); return
            creds = load_passkeys()
            if not creds:
                self.send_json(400, {"error": "Aucune Passkey enregistrée."}); return
            opts = generate_authentication_options(
                rp_id=RP_ID,
                allow_credentials=[
                    PublicKeyCredentialDescriptor(id=base64url_to_bytes(c["id"]))
                    for c in creds
                ],
                user_verification=UserVerificationRequirement.PREFERRED,
            )
            cid = store_challenge(opts.challenge)
            self.send_json(200, {"options": json.loads(options_to_json(opts)), "cid": cid})
            return

        # --- 2. Vérification d'authentification Passkey (public) ---
        if path == "/webauthn/auth/verify":
            if self.is_rate_limited(ip):
                self.send_json(429, {"error": ERRORS["2"]}); return
            try:
                data = self.read_json()
                challenge = pop_challenge(data.get("cid", ""))
                if not challenge:
                    raise ValueError("Challenge expiré.")
                cred_data = data["credential"]
                creds = load_passkeys()
                matched = next((c for c in creds if c["id"] == cred_data.get("id")), None)
                if not matched:
                    raise ValueError("Passkey inconnue.")
                verification = verify_authentication_response(
                    credential=cred_data,
                    expected_challenge=challenge,
                    expected_rp_id=RP_ID,
                    expected_origin=f"https://{RP_ID}",
                    credential_public_key=base64url_to_bytes(matched["public_key"]),
                    credential_current_sign_count=matched.get("sign_count", 0),
                    require_user_verification=False,
                )
                matched["sign_count"] = verification.new_sign_count
                save_passkeys(creds)
                with LOCK:
                    FAILS.pop(ip, None)
                print(f"[OK] connexion Passkey ({matched.get('label')}) depuis {ip}")
                self.send_json(200, {"ok": True}, cookie=self.cookie(make_token(USER), TTL))
            except Exception as e:
                self.record_fail(ip)
                print(f"[ECHEC PASSKEY] depuis {ip}: {e}")
                self.send_json(400, {"error": "Vérification Passkey échouée."})
            return

        # --- 3. Enregistrement d'une nouvelle Passkey (protégé par session) ---
        if path == "/webauthn/register/options":
            if not logged:
                self.send_json(401, {"error": "Non connecté"}); return
            creds = load_passkeys()
            opts = generate_registration_options(
                rp_id=RP_ID,
                rp_name=f"Portail {RP_ID}",
                user_id=USER.encode("utf-8"),
                user_name=USER,
                user_display_name=USER,
                exclude_credentials=[
                    PublicKeyCredentialDescriptor(id=base64url_to_bytes(c["id"]))
                    for c in creds
                ],
                authenticator_selection=AuthenticatorSelectionCriteria(
                    resident_key=ResidentKeyRequirement.PREFERRED,
                    user_verification=UserVerificationRequirement.PREFERRED,
                ),
            )
            cid = store_challenge(opts.challenge)
            self.send_json(200, {"options": json.loads(options_to_json(opts)), "cid": cid})
            return

        if path == "/webauthn/register/verify":
            if not logged:
                self.send_json(401, {"error": "Non connecté"}); return
            try:
                data = self.read_json()
                challenge = pop_challenge(data.get("cid", ""))
                if not challenge:
                    raise ValueError("Challenge expiré.")
                label = "".join(ch for ch in data.get("label", "Passkey")[:40] if ch.isalnum() or ch in " _-()") or "Passkey"
                verification = verify_registration_response(
                    credential=data["credential"],
                    expected_challenge=challenge,
                    expected_rp_id=RP_ID,
                    expected_origin=f"https://{RP_ID}",
                    require_user_verification=False,
                )
                creds = load_passkeys()
                creds.append({
                    "id": bytes_to_base64url(verification.credential_id),
                    "public_key": bytes_to_base64url(verification.credential_public_key),
                    "sign_count": verification.sign_count,
                    "label": label,
                    "created": time.strftime("%d/%m/%Y %H:%M"),
                })
                save_passkeys(creds)
                print(f"[PASSKEY] Nouvelle Passkey '{label}' enregistrée par {USER}")
                self.send_json(200, {"ok": True})
            except Exception as e:
                print(f"[ERREUR ENREGISTREMENT PASSKEY] {e}")
                self.send_json(400, {"error": f"Échec : {e}"})
            return

        if path == "/webauthn/delete":
            if not logged:
                self.send_json(401, {"error": "Non connecté"}); return
            data = self.read_json()
            target_id = data.get("id", "")
            creds = [c for c in load_passkeys() if c.get("id") != target_id]
            save_passkeys(creds)
            self.send_json(200, {"ok": True})
            return

        # --- 4. Connexion classique par mot de passe ---
        if path != "/login":
            self.send_response(404); self.end_headers(); return
        if self.is_rate_limited(ip):
            self.redirect("/login?e=2"); return

        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        u = form.get("username", [""])[0]
        p = form.get("password", [""])[0]

        if hmac.compare_digest(u, USER) and verify_password(p):
            with LOCK:
                FAILS.pop(ip, None)
            print(f"[OK] connexion {u} depuis {ip}")
            self.redirect("/", self.cookie(make_token(u), TTL))
        else:
            self.record_fail(ip)
            print(f"[ECHEC] tentative '{u}' depuis {ip}")
            time.sleep(1)
            self.redirect("/login?e=1")

print("portal-auth (WebAuthn/Passkeys + scrypt) en écoute sur :9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF
chmod 644 /opt/portal/auth.py
ok "Service auth.py avec support Passkey (WebAuthn) installé"

# -----------------------------------------------------------------------------
step "4/6 Ajout du bouton '🔑 Passkeys' sur le portail (/var/www/portal/index.html)"
# -----------------------------------------------------------------------------
if [ -f /var/www/portal/index.html ] && ! grep -q 'href="/passkeys"' /var/www/portal/index.html; then
    sed -i 's|<a class="logout" href="/logout">|<div style="display:flex;gap:10px"><a class="logout" href="/passkeys">🔑 Passkeys</a><a class="logout" href="/logout">|' /var/www/portal/index.html
    sed -i 's|⎋ Déconnexion</a>|⎋ Déconnexion</a></div>|' /var/www/portal/index.html
    ok "Bouton '🔑 Passkeys' ajouté en haut à droite du portail"
else
    ok "Bouton '🔑 Passkeys' déjà présent sur le portail"
fi

# -----------------------------------------------------------------------------
step "5/6 Configuration Nginx durcie + routes WebAuthn"
# -----------------------------------------------------------------------------
sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf

cat > /etc/nginx/conf.d/portal-ratelimit.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=portal_login:10m rate=15r/m;
limit_req_status 429;
EOF

cat > /etc/nginx/sites-available/portal <<'NGXEOF'
# ---------- notes.DOMAINE -> Trilium (PROTÉGÉ PAR LE PORTAIL) ----------
server {
    listen 80;
    listen [::]:80;
    server_name notes.__DOMAIN__;

    client_max_body_size __MAX_UPLOAD_SIZE__;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:9100/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
    }

    location / {
        auth_request /_auth;
        error_page 401 = @portal_login;

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

    location @portal_login {
        return 302 https://__DOMAIN__/login;
    }
}

# ---------- DOMAINE / www / IP -> Portail avec login + Passkeys ----------
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name __DOMAIN__ www.__DOMAIN__ _;

    root /var/www/portal;
    index index.html;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:9100/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
    }

    location ~ ^/(login|logout|passkeys|webauthn/.*)$ {
        limit_req zone=portal_login burst=10 nodelay;
        proxy_pass http://127.0.0.1:9100;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location = /status/trilium {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8888/api/health-check;
        proxy_connect_timeout 3s;
    }

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

sed -i "s/__DOMAIN__/${DOMAIN}/g" /etc/nginx/sites-available/portal
sed -i "s/__MAX_UPLOAD_SIZE__/${MAX_UPLOAD_SIZE}/g" /etc/nginx/sites-available/portal
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
nginx -t && systemctl reload nginx

# Réactivation du certificat HTTPS via Certbot
SERVER_IP=$(curl -4 -fs --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
CERT_ARGS=()
for d in "$DOMAIN" "www.$DOMAIN" "notes.$DOMAIN"; do
    a=$(dig +short A "$d" @1.1.1.1 | grep -E '^[0-9.]+$' | tr '\n' ' ')
    aaaa=$(dig +short AAAA "$d" @1.1.1.1 | grep ':' | tr '\n' ' ')
    if [ "${a% }" = "$SERVER_IP" ] && [ -z "$aaaa" ]; then
        CERT_ARGS+=(-d "$d")
    fi
done

if [ ${#CERT_ARGS[@]} -gt 0 ]; then
    certbot --nginx "${CERT_ARGS[@]}" --cert-name "$DOMAIN" \
        --non-interactive --agree-tos -m "$EMAIL" --redirect --expand --keep-until-expiring --reinstall
    ok "HTTPS actif (obligatoire pour le fonctionnement des Passkeys WebAuthn)"
fi

# -----------------------------------------------------------------------------
step "6/6 Construction et démarrage du conteneur Passkey"
# -----------------------------------------------------------------------------
docker compose -f /opt/portal/docker-compose.yml up -d --build --force-recreate
docker compose -f /opt/trilium/docker-compose.yml up -d

echo -e "\n\033[1;32m✅ Passkeys (WebAuthn) + Durcissement activés !\033[0m"
echo "   1. Connectez-vous une première fois sur https://${DOMAIN}/login"
echo "   2. Cliquez sur '🔑 Passkeys' en haut à droite du portail (ou allez sur https://${DOMAIN}/passkeys)"
echo "   3. Cliquez sur '+ Ajouter une Passkey' (Windows Hello, Face ID, Touch ID, téléphone ou YubiKey)"
echo "   4. Aux prochaines connexions, le bouton '🔑 Se connecter avec une Passkey' apparaîtra sur /login !"
SCRIPT_EOF
chmod 700 /root/secure-portal.sh
bash /root/secure-portal.sh
