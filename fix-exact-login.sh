cat > /root/fix-exact-login.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  RÉPARATION EXACTE DU PORTAIL — IDENTIFIANT & MOT DE PASSE : Lulucarab664
#  Restaure le code original d'origine en béton armé (zéro dépendance externe)
# =============================================================================
set -uo pipefail

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lancez en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/4 Fichier .env avec identifiants exacts"
# -----------------------------------------------------------------------------
mkdir -p /opt/portal
SECRET=$(openssl rand -hex 32)
cat > /opt/portal/.env <<EOF
PORTAL_USER=Lulucarab664
PORTAL_PASS=Lulucarab664
PORTAL_SECRET=${SECRET}
COOKIE_SECURE=1
SESSION_HOURS=24
EOF
chmod 600 /opt/portal/.env
ok "Identifiant: Lulucarab664 / Mot de passe: Lulucarab664 configurés"

# -----------------------------------------------------------------------------
step "2/4 Docker Compose officiel (sans montage password.txt bancal)"
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
      - ./auth.py:/app/auth.py:ro
    ports:
      - "127.0.0.1:9100:9100"
EOF

# -----------------------------------------------------------------------------
step "3/4 Code auth.py original (validation HMAC directe, zéro crash)"
# -----------------------------------------------------------------------------
cat > /opt/portal/auth.py <<'PYEOF'
import hashlib, hmac, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER = os.environ.get("PORTAL_USER", "").strip()
PASS = os.environ.get("PORTAL_PASS", "").strip()
SECRET = os.environ.get("PORTAL_SECRET", "secret").encode()
SECURE = os.environ.get("COOKIE_SECURE", "0") == "1"
TTL = int(os.environ.get("SESSION_HOURS", "24")) * 3600
COOKIE = "portal_session"

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

def read_cookie(header):
    for part in (header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == COOKIE:
            return v
    return ""

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
.card{position:relative;width:min(92vw,400px);padding:42px 36px;border-radius:24px;background:rgba(15,23,42,.65);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.5)}
.logo{width:64px;height:64px;margin:0 auto 18px;border-radius:18px;display:grid;place-items:center;font-size:30px;background:linear-gradient(135deg,#7c3aed,#0ea5e9);box-shadow:0 10px 30px rgba(124,58,237,.45)}
h1{text-align:center;font-size:1.5rem}
.sub{text-align:center;color:#94a3b8;font-size:.9rem;margin:6px 0 28px}
label{display:block;font-size:.8rem;color:#94a3b8;margin:0 0 6px 2px}
input{width:100%;padding:13px 15px;margin-bottom:16px;border-radius:12px;border:1px solid rgba(255,255,255,.1);background:rgba(2,6,23,.6);color:#f1f5f9;font-size:.95rem;outline:none;transition:.2s}
input:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.2)}
button{width:100%;padding:13px;border:0;border-radius:12px;font-weight:600;font-size:1rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 10px 25px rgba(14,165,233,.35)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.foot{text-align:center;color:#475569;font-size:.75rem;margin-top:22px}
</style></head><body>
<div class="bg"><span></span><span></span><span></span></div>
<form class="card" method="post" action="/login">
<div class="logo">&#128272;</div><h1>Espace privé</h1>
<p class="sub">Connectez-vous pour accéder à vos services</p>
__ERROR__
<label for="u">Identifiant</label><input id="u" name="username" autocomplete="username" required autofocus>
<label for="p">Mot de passe</label><input id="p" name="password" type="password" autocomplete="current-password" required>
<button type="submit">Se connecter &rarr;</button>
<div class="foot">Accès réservé · Session active 24h</div>
</form></body></html>"""

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

    def do_GET(self):
        url = urlparse(self.path)
        tok = read_cookie(self.headers.get("Cookie"))
        logged = valid(tok)

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
            err = '<div class="err">Identifiant ou mot de passe incorrect.</div>' if code == "1" else ""
            body = LOGIN_HTML.replace("__ERROR__", err).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404); self.end_headers()

    def do_POST(self):
        if urlparse(self.path).path != "/login":
            self.send_response(404); self.end_headers(); return

        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        u = form.get("username", [""])[0].strip()
        p = form.get("password", [""])[0].strip()

        if hmac.compare_digest(u, USER) and hmac.compare_digest(p, PASS):
            print(f"[OK] Connexion reussie pour {u}")
            self.redirect("/", self.cookie(make_token(u), TTL))
        else:
            print(f"[ECHEC] Tentative echouee pour '{u}'")
            time.sleep(0.5)
            self.redirect("/login?e=1")

print("portal-auth en écoute sur :9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF

docker rm -f portal-auth >/dev/null 2>&1 || true
docker compose -f /opt/portal/docker-compose.yml up -d
ok "Conteneur portal-auth prêt"

# -----------------------------------------------------------------------------
step "4/4 Test de validation en local"
# -----------------------------------------------------------------------------
sleep 2
TEST_RESP=$(curl -i -s -X POST -d "username=Lulucarab664&password=Lulucarab664" http://127.0.0.1:9100/login)
COOKIE_VAL=$(echo "$TEST_RESP" | grep -i "Set-Cookie" | awk '{print $2}' | tr -d '\r\n')

echo "Cookie généré : ${COOKIE_VAL}"
AUTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: ${COOKIE_VAL}" http://127.0.0.1:9100/auth)

if [ "$AUTH_CHECK" = "200" ]; then
    echo -e "\n\033[1;32m==================================================================\033[0m"
    echo -e "\033[1;32m✅ VALIDATION 100% RÉUSSIE : Lulucarab664 / Lulucarab664 DÉVERROUILLE TOUT !\033[0m"
    echo -e "\033[1;32m==================================================================\033[0m"
    echo "   Portail : https://fabienaly.com/login"
    echo "   Identifiant  : Lulucarab664"
    echo "   Mot de passe : Lulucarab664"
    echo "=================================================================="
else
    echo -e "\033[1;31m[!] Test local: code HTTP ${AUTH_CHECK}\033[0m"
fi
SCRIPT_EOF
chmod 700 /root/fix-exact-login.sh
bash /root/fix-exact-login.sh
