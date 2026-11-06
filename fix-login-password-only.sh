cat > /root/fix-login-password-only.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  RÉPARATION D'URGENCE DU PORTAIL — ACCÈS UNIQUEMENT PAR MOT DE PASSE
#  - Supprime le champ "Identifiant" (ne demande plus QUE le mot de passe)
#  - Réinitialise le mot de passe immédiatement
#  - Débloque les IP (remise à zéro des compteurs anti-bruteforce)
#  - Conserve la compatibilité Passkeys WebAuthn et Nginx
# =============================================================================
set -uo pipefail

# ============================ VOS RÉGLAGES ===================================
# Indiquez votre nouveau mot de passe ci-dessous (évitez les caractères ' et $) :
NEW_PASS='ChangezMoi2026!'
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { err "Lancez ce script en root."; exit 1; }

# Si le mot de passe par défaut n'a pas été changé et qu'un argument est fourni
if [ "$NEW_PASS" = 'ChangezMoi2026!' ] && [ -n "${1:-}" ]; then
    NEW_PASS="$1"
fi

if [ -z "$NEW_PASS" ]; then
    read -r -s -p "Entrez le nouveau mot de passe du portail : " NEW_PASS
    echo ""
fi

[ -n "$NEW_PASS" ] || { err "Le mot de passe ne peut pas être vide."; exit 1; }

# -----------------------------------------------------------------------------
step "1/4 Calcul du nouveau hash sécurisé (scrypt)"
# -----------------------------------------------------------------------------
PASS_HASH=$(docker run --rm -e P="$NEW_PASS" python:3.12-alpine python -c '
import hashlib, os
salt = os.urandom(16)
digest = hashlib.scrypt(os.environ["P"].encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
print(salt.hex() + ":" + digest.hex())
')

SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env | cut -d= -f2- || true)
[ -n "$SECRET" ] || SECRET=$(openssl rand -hex 32)

RP_ID=$(grep -s '^RP_ID=' /opt/portal/.env | cut -d= -f2- || true)
COOKIE_DOMAIN=$(grep -s '^COOKIE_DOMAIN=' /opt/portal/.env | cut -d= -f2- || true)
SESSION_HOURS=$(grep -s '^SESSION_HOURS=' /opt/portal/.env | cut -d= -f2- || echo "12")

cat > /opt/portal/.env <<EOF
PORTAL_USER=admin
PORTAL_PASS_HASH=${PASS_HASH}
PORTAL_SECRET=${SECRET}
RP_ID=${RP_ID}
COOKIE_DOMAIN=${COOKIE_DOMAIN}
COOKIE_SECURE=1
SESSION_HOURS=${SESSION_HOURS}
EOF
chmod 600 /opt/portal/.env
ok "Nouveau hash de mot de passe enregistré dans /opt/portal/.env"

# -----------------------------------------------------------------------------
step "2/4 Mise à jour de /opt/portal/auth.py (Suppression du champ Identifiant)"
# -----------------------------------------------------------------------------
cat > /opt/portal/auth.py <<'PYEOF'
"""Service d'authentification Nginx (auth_request) — Mode Mot de Passe Unique + Passkey."""
import hashlib, hmac, json, os, secrets, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
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
    HAS_WEBAUTHN = True
except ImportError:
    HAS_WEBAUTHN = False

PASS_HASH = os.environ["PORTAL_PASS_HASH"]
SECRET = os.environ["PORTAL_SECRET"].encode()
RP_ID = os.environ.get("RP_ID", "")
COOKIE_DOMAIN = os.environ.get("COOKIE_DOMAIN", "")
SECURE = os.environ.get("COOKIE_SECURE", "1") == "1"
TTL = int(os.environ.get("SESSION_HOURS", "12")) * 3600
COOKIE = "portal_session"
PASSKEYS_FILE = "/data/passkeys.json"

LOCK = threading.Lock()
FAILS = {}            # ip -> [nb_echecs, horodatage]
REVOKED = {}          # jti -> exp_timestamp
CHALLENGES = {}       # challenge_id -> (challenge_bytes, exp_timestamp)
MAX_FAILS, LOCK_S = 10, 180

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

def make_token(user: str = "admin") -> str:
    exp = int(time.time()) + TTL
    jti = secrets.token_hex(12)
    payload = f"{jti}.{exp}.{user}"
    return f"{payload}.{sign(payload)}"

def valid(token: str) -> bool:
    if not token:
        return False
    try:
        # Format WebAuthn: jti.exp.user.sig
        if "." in token:
            jti, exp_s, user, sig = token.split(".", 3)
            if int(exp_s) <= time.time():
                return False
            if not hmac.compare_digest(sig, sign(f"{jti}.{exp_s}.{user}")):
                return False
            with LOCK:
                return jti not in REVOKED
        # Format historique: user|exp|sig
        elif "|" in token:
            user, exp_s, sig = token.split("|", 2)
            if int(exp_s) <= time.time():
                return False
            return hmac.compare_digest(sig, sign(f"{user}|{exp_s}"))
    except Exception:
        return False
    return False

def revoke(token: str) -> None:
    try:
        if "." in token:
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
label{display:block;font-size:.85rem;color:#94a3b8;margin:0 0 8px 2px}
input{width:100%;padding:14px 16px;margin-bottom:20px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(2,6,23,.6);color:#f1f5f9;font-size:1rem;outline:none;transition:.2s}
input:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.2)}
button{width:100%;padding:14px;border:0;border-radius:12px;font-weight:600;font-size:1rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 10px 25px rgba(14,165,233,.35)}
.passkey-btn{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.18);display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:18px}
.passkey-btn:hover{background:rgba(255,255,255,.14);box-shadow:0 10px 25px rgba(124,58,237,.25)}
.sep{display:flex;align-items:center;gap:12px;color:#64748b;font-size:.78rem;margin:4px 0 18px}
.sep::before,.sep::after{content:"";flex:1;height:1px;background:rgba(255,255,255,.08)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:12px;border-radius:10px;font-size:.88rem;margin-bottom:18px;text-align:center}
.foot{text-align:center;color:#475569;font-size:.75rem;margin-top:22px}
</style></head><body>
<div class="bg"><span></span><span></span><span></span></div>
<div class="card">
  <div class="logo">&#128272;</div><h1>Espace privé</h1>
  <p class="sub">Entrez votre mot de passe pour accéder à vos services</p>
  <div id="pk-err" class="err" style="display:none"></div>
  __ERROR__
  __PASSKEY_BLOCK__
  <form method="post" action="/login">
    <label for="p">Mot de passe du portail</label>
    <input id="p" name="password" type="password" autocomplete="current-password" placeholder="••••••••••••" required autofocus>
    <button type="submit">Déverrouiller &rarr;</button>
  </form>
  <div class="foot">Accès sécurisé · Session active 12h</div>
</div>
<script>
""" + WEBAUTHN_JS_HELPERS + """
async function loginWithPasskey() {
  const errBox = document.getElementById('pk-err');
  errBox.style.display = 'none';
  try {
    const r = await fetch('/webauthn/auth/options', { method: 'POST' });
    if (!r.ok) throw new Error('Aucune Passkey ou erreur serveur.');
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
      throw new Error(res.error || 'Échec de vérification.');
    }
  } catch (e) {
    if (e.name !== 'NotAllowedError') {
      errBox.textContent = e.message || 'Erreur Passkey.';
      errBox.style.display = 'block';
    }
  }
}
</script></body></html>"""

ERRORS = {
    "1": "Mot de passe incorrect.",
    "2": "Trop de tentatives. Réessayez dans 3 minutes.",
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
        if cookie: self.send_header("Set-Cookie", cookie)
        self.end_headers(); self.wfile.write(body)

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
            if tok: revoke(tok)
            self.redirect("/login", self.cookie("", 0)); return
        if url.path == "/login":
            if logged: self.redirect("/"); return
            code = parse_qs(url.query).get("e", [""])[0]
            err = f'<div class="err">{ERRORS[code]}</div>' if code in ERRORS else ""
            has_pk = HAS_WEBAUTHN and len(load_passkeys()) > 0
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
        self.send_response(404); self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        ip = self.ip()

        # WebAuthn options
        if path == "/webauthn/auth/options" and HAS_WEBAUTHN:
            if self.is_rate_limited(ip):
                self.send_json(429, {"error": ERRORS["2"]}); return
            creds = load_passkeys()
            if not creds:
                self.send_json(400, {"error": "Aucune Passkey"}); return
            opts = generate_authentication_options(
                rp_id=RP_ID,
                allow_credentials=[PublicKeyCredentialDescriptor(id=base64url_to_bytes(c["id"])) for c in creds],
                user_verification=UserVerificationRequirement.PREFERRED,
            )
            cid = store_challenge(opts.challenge)
            self.send_json(200, {"options": json.loads(options_to_json(opts)), "cid": cid})
            return

        # WebAuthn verify
        if path == "/webauthn/auth/verify" and HAS_WEBAUTHN:
            if self.is_rate_limited(ip):
                self.send_json(429, {"error": ERRORS["2"]}); return
            try:
                data = self.read_json()
                challenge = pop_challenge(data.get("cid", ""))
                if not challenge: raise ValueError("Expiré")
                cred_data = data["credential"]
                creds = load_passkeys()
                matched = next((c for c in creds if c["id"] == cred_data.get("id")), None)
                if not matched: raise ValueError("Inconnu")
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
                with LOCK: FAILS.pop(ip, None)
                self.send_json(200, {"ok": True}, cookie=self.cookie(make_token("admin"), TTL))
            except Exception as e:
                self.record_fail(ip)
                self.send_json(400, {"error": "Échec Passkey"})
            return

        # Connexion classique par Mot de Passe UNIQUE
        if path != "/login":
            self.send_response(404); self.end_headers(); return

        if self.is_rate_limited(ip):
            self.redirect("/login?e=2"); return

        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        p = form.get("password", [""])[0]

        if verify_password(p):
            with LOCK:
                FAILS.pop(ip, None)
            print(f"[OK] Connexion réussie par mot de passe depuis {ip}")
            self.redirect("/", self.cookie(make_token("admin"), TTL))
        else:
            self.record_fail(ip)
            print(f"[ECHEC] Mauvais mot de passe depuis {ip}")
            time.sleep(1)
            self.redirect("/login?e=1")

print("portal-auth en écoute sur :9100 (Mode Mot de passe Unique)")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF
chmod 644 /opt/portal/auth.py
ok "Fichier /opt/portal/auth.py mis à jour"

# -----------------------------------------------------------------------------
step "3/4 Redémarrage du conteneur portal-auth et déblocage IP"
# -----------------------------------------------------------------------------
docker compose -f /opt/portal/docker-compose.yml up -d --force-recreate
ok "Conteneur portal-auth redémarré (compteurs de blocage réinitialisés)"

# -----------------------------------------------------------------------------
step "4/4 Vérification Nginx"
# -----------------------------------------------------------------------------
nginx -t && systemctl reload nginx
ok "Nginx rechargé"

echo -e "\n\033[1;32m==================================================================\033[0m"
echo -e "\033[1;32m✅ ACCÈS RESTAURÉ EN MODE MOT DE PASSE UNIQUE !\033[0m"
echo -e "\033[1;32m==================================================================\033[0m"
echo "   Page de connexion : /login ne demande PLUS d'identifiant, uniquement le mot de passe."
echo "   Mot de passe configuré : ${NEW_PASS}"
echo "=================================================================="
SCRIPT_EOF
chmod 700 /root/fix-login-password-only.sh
bash /root/fix-login-password-only.sh
