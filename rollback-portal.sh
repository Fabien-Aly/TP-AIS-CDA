cat > /root/rollback-portal.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  RETOUR EN ARRIÈRE COMPLET — ÉTAT EXACT INITIAL (AVANT SECURE-PORTAL.SH)
#  - Supprime tous les résidus de secure-portal (webauthn, passkeys, rate-limits)
#  - Restaure le service d'authentification originel (rapide, sans crash)
#  - Restaure Nginx et Trilium exactement comme dans fix-portal.sh
#  - Réactive le certificat HTTPS Certbot
# =============================================================================
set -uo pipefail

# ============================ VOS RÉGLAGES ===================================
DOMAIN='fabienaly.com'
EMAIL='alyfabien3@gmail.com'
PORTAL_USER='Lulucarab664'
PORTAL_PASS='ChangezMoi2026'          # Votre mot de passe (sans ' ni $)
SESSION_HOURS='12'
# =============================================================================

# Si /root/portal.conf existe, il est prioritaire
# shellcheck disable=SC1091
[ -f /root/portal.conf ] && . /root/portal.conf

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { err "Lancez ce script en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/6 Nettoyage des modifications de secure-portal.sh"
# -----------------------------------------------------------------------------
# Suppression des rate-limits Nginx ajoutés par secure-portal
rm -f /etc/nginx/conf.d/portal-ratelimit.conf
rm -f /etc/nginx/conf.d/ai-hub-ratelimit.conf

# Nettoyage des fichiers temporaires / builds Docker WebAuthn
rm -f /opt/portal/Dockerfile
rm -rf /opt/portal/data

# Nettoyage du bouton 'Passkeys' dans index.html s'il avait été injecté
if [ -f /var/www/portal/index.html ]; then
    sed -i 's|<div style="display:flex;gap:10px"><a class="logout" href="/passkeys">🔑 Passkeys</a>||g' /var/www/portal/index.html
    sed -i 's|⎋ Déconnexion</a></div>|⎋ Déconnexion</a>|g' /var/www/portal/index.html
fi
ok "Résidus de secure-portal supprimés"

# -----------------------------------------------------------------------------
step "2/6 Configuration /opt/portal/.env"
# -----------------------------------------------------------------------------
mkdir -p /opt/portal
SECRET=$(openssl rand -hex 32)
cat > /opt/portal/.env <<EOF
PORTAL_USER=${PORTAL_USER}
PORTAL_PASS=${PORTAL_PASS}
PORTAL_SECRET=${SECRET}
COOKIE_SECURE=1
SESSION_HOURS=${SESSION_HOURS}
EOF
chmod 600 /opt/portal/.env
ok "Fichier .env initial restauré"

# -----------------------------------------------------------------------------
step "3/6 Restauration de portal-auth (Code initial pur Python)"
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

cat > /opt/portal/auth.py <<'PYEOF'
"""Mini service d'authentification pour Nginx (auth_request). Aucune dépendance."""
import hashlib, hmac, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER = os.environ["PORTAL_USER"]
PASS = os.environ["PORTAL_PASS"]
SECRET = os.environ["PORTAL_SECRET"].encode()
SECURE = os.environ.get("COOKIE_SECURE", "0") == "1"
TTL = int(os.environ.get("SESSION_HOURS", "12")) * 3600
COOKIE = "portal_session"
FAILS = {}            # ip -> [nb_echecs, horodatage]
MAX_FAILS, LOCK_S = 5, 300

def sign(v): return hmac.new(SECRET, v.encode(), hashlib.sha256).hexdigest()

def make_token(user):
    payload = f"{user}|{int(time.time()) + TTL}"
    return f"{payload}|{sign(payload)}"

def valid(token):
    try:
        user, exp, sig = token.split("|")
        return hmac.compare_digest(sig, sign(f"{user}|{exp}")) and int(exp) > time.time()
    except ValueError:
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
.card{position:relative;width:min(92vw,400px);padding:42px 36px;border-radius:24px;background:rgba(15,23,42,.55);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.5);animation:in .6s ease}
@keyframes in{from{opacity:0;transform:translateY(16px)}}
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
<div class="foot">Accès réservé · toutes les tentatives sont journalisées</div>
</form></body></html>"""

ERRORS = {
    "1": "Identifiant ou mot de passe incorrect.",
    "2": "Trop de tentatives. Réessayez dans 5 minutes.",
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

    def do_GET(self):
        url = urlparse(self.path)
        logged = valid(read_cookie(self.headers.get("Cookie")))
        if url.path == "/auth":
            self.send_response(200 if logged else 401); self.end_headers(); return
        if url.path == "/logout":
            self.redirect("/login", self.cookie("", 0)); return
        if url.path == "/login":
            if logged: self.redirect("/"); return
            code = parse_qs(url.query).get("e", [""])[0]
            err = f'<div class="err">{ERRORS[code]}</div>' if code in ERRORS else ""
            body = LOGIN_HTML.replace("__ERROR__", err).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        self.send_response(404); self.end_headers()

    def do_POST(self):
        if urlparse(self.path).path != "/login":
            self.send_response(404); self.end_headers(); return
        ip = self.ip()
        n, t = FAILS.get(ip, [0, 0])
        if n >= MAX_FAILS and time.time() - t < LOCK_S:
            self.redirect("/login?e=2"); return
        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        u = form.get("username", [""])[0]; p = form.get("password", [""])[0]
        if hmac.compare_digest(u, USER) and hmac.compare_digest(p, PASS):
            FAILS.pop(ip, None)
            print(f"[OK] connexion {u} depuis {ip}")
            self.redirect("/", self.cookie(make_token(u), TTL))
        else:
            FAILS[ip] = [n + 1 if time.time() - t < LOCK_S else 1, time.time()]
            print(f"[ECHEC] tentative '{u}' depuis {ip}")
            time.sleep(1)
            self.redirect("/login?e=1")

print("portal-auth en écoute sur :9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF

docker rm -f portal-auth >/dev/null 2>&1 || true
docker compose -f /opt/portal/docker-compose.yml up -d
ok "Conteneur portal-auth initial démarré"

# -----------------------------------------------------------------------------
step "4/6 Restauration de la configuration Nginx (identique fix-portal.sh)"
# -----------------------------------------------------------------------------
cat > /etc/nginx/sites-available/portal <<'NGXEOF'
# ---------- notes.DOMAINE -> Trilium ----------
server {
    listen 80;
    listen [::]:80;
    server_name notes.__DOMAIN__;
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

# ---------- DOMAINE / www / IP -> Portail avec login ----------
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name __DOMAIN__ www.__DOMAIN__ _;

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

    location ~ ^/(login|logout)$ {
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

    location @login { return 302 /login; }
}
NGXEOF

sed -i "s/__DOMAIN__/${DOMAIN}/g" /etc/nginx/sites-available/portal
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
nginx -t
ok "Configuration Nginx validée"

# -----------------------------------------------------------------------------
step "5/6 Réactivation HTTPS Certbot"
# -----------------------------------------------------------------------------
certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" -d "notes.${DOMAIN}" \
    --non-interactive --agree-tos -m "${EMAIL}" --redirect --expand --keep-until-expiring >/dev/null 2>&1 || true

systemctl reload nginx
ok "Nginx rechargé avec HTTPS"

# -----------------------------------------------------------------------------
step "6/6 Vérification Trilium et Portail"
# -----------------------------------------------------------------------------
docker compose -f /opt/trilium/docker-compose.yml up -d >/dev/null 2>&1 || true

sleep 2
echo -e "\n\033[1;32m==================================================================\033[0m"
echo -e "\033[1;32m✅ RETOUR À L'ÉTAT INITIAL TERMINÉ AVEC SUCCÈS !\033[0m"
echo -e "\033[1;32m==================================================================\033[0m"
echo "   Portail      : https://${DOMAIN} (Identifiant : ${PORTAL_USER} | Mot de passe : ${PORTAL_PASS})"
echo "   Trilium Notes: https://notes.${DOMAIN} (Accès direct comme au départ)"
echo "=================================================================="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
SCRIPT_EOF
chmod 700 /root/rollback-portal.sh
bash /root/rollback-portal.sh
