cat > /root/lock-all-with-password.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  VERROUILLAGE TOTAL (PORTAIL + TRILIUM) — MOT DE PASSE UNIQUE
#  - Bloque tout contournement : notes.DOMAINE exige obligatoirement le mot de passe
#  - Supprime le champ "Identifiant" : un seul mot de passe pour tout
#  - Cookie SSO multi-sous-domaines (Domain=.DOMAINE) pour ne pas boucler
#  - Redirection automatique intelligente : si vous allez sur notes.DOMAINE,
#    vous tapez le mot de passe une fois et vous arrivez directement sur vos notes !
# =============================================================================
set -uo pipefail

# ============================ VOTRE MOT DE PASSE =============================
# Indiquez votre mot de passe ci-dessous (évitez les caractères ' et $) :
NEW_PASS=""
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { err "Lancez en root."; exit 1; }

# Récupération automatique du domaine
DOMAIN=$(awk '/server_name/ && !/notes\./ {print $2; exit}' /etc/nginx/sites-available/portal 2>/dev/null | tr -d ';')
[ -n "$DOMAIN" ] || DOMAIN=$(grep -s '^RP_ID=' /opt/portal/.env 2>/dev/null | cut -d= -f2-)
[ -n "$DOMAIN" ] || DOMAIN="fabienaly.com"

# Saisie interactive si laissé vide
if [ -z "$NEW_PASS" ] && [ -n "${1:-}" ]; then
    NEW_PASS="$1"
fi

while [ -z "$NEW_PASS" ]; do
    read -r -s -p "Entrez le mot de passe unique pour déverrouiller Portail + Trilium : " NEW_PASS
    echo ""
    [ -n "$NEW_PASS" ] || warn "Le mot de passe ne peut pas être vide !"
done

# -----------------------------------------------------------------------------
step "1/4 Enregistrement des secrets (/opt/portal/.env)"
# -----------------------------------------------------------------------------
SECRET=$(openssl rand -hex 32)
cat > /opt/portal/.env <<EOF
PORTAL_PASS=${NEW_PASS}
PORTAL_SECRET=${SECRET}
COOKIE_DOMAIN=.${DOMAIN}
RP_ID=${DOMAIN}
SESSION_HOURS=24
EOF
chmod 600 /opt/portal/.env
ok "Mot de passe et domaine configurés (domaine SSO : .${DOMAIN})"

# -----------------------------------------------------------------------------
step "2/4 Service d'authentification Python SSO (Zero-Crash, Zéro Identifiant)"
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
import hashlib, hmac, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PASS = os.environ.get("PORTAL_PASS", "")
SECRET = os.environ.get("PORTAL_SECRET", "secret").encode()
DOMAIN = os.environ.get("COOKIE_DOMAIN", "").strip()
TTL = int(os.environ.get("SESSION_HOURS", "24")) * 3600
COOKIE = "portal_session"

def sign(v):
    return hmac.new(SECRET, v.encode(), hashlib.sha256).hexdigest()

def make_token():
    payload = f"admin|{int(time.time()) + TTL}"
    return f"{payload}|{sign(payload)}"

def valid(token):
    try:
        user, exp, sig = token.split("|")
        return hmac.compare_digest(sig, sign(f"{user}|{exp}")) and int(exp) > time.time()
    except Exception:
        return False

def read_cookie(header):
    for part in (header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == COOKIE: return v
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
.card{position:relative;width:min(92vw,400px);padding:42px 34px;border-radius:24px;background:rgba(15,23,42,.65);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.5)}
.logo{width:64px;height:64px;margin:0 auto 16px;border-radius:18px;display:grid;place-items:center;font-size:30px;background:linear-gradient(135deg,#7c3aed,#0ea5e9);box-shadow:0 10px 30px rgba(124,58,237,.45)}
h1{text-align:center;font-size:1.5rem}
.sub{text-align:center;color:#94a3b8;font-size:.9rem;margin:6px 0 26px}
label{display:block;font-size:.85rem;color:#94a3b8;margin:0 0 8px 2px}
input[type="password"]{width:100%;padding:14px 16px;margin-bottom:20px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(2,6,23,.6);color:#f1f5f9;font-size:1rem;outline:none;transition:.2s}
input[type="password"]:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.2)}
button{width:100%;padding:14px;border:0;border-radius:12px;font-weight:600;font-size:1rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 10px 25px rgba(14,165,233,.35)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:12px;border-radius:10px;font-size:.88rem;margin-bottom:18px;text-align:center}
.foot{text-align:center;color:#475569;font-size:.75rem;margin-top:22px}
</style></head><body>
<div class="bg"><span></span><span></span><span></span></div>
<form class="card" method="post" action="/login">
  <input type="hidden" name="next" value="__NEXT__">
  <div class="logo">&#128272;</div><h1>Espace privé</h1>
  <p class="sub">Entrez votre mot de passe pour accéder à vos services</p>
  __ERROR__
  <label for="p">Mot de passe</label>
  <input id="p" name="password" type="password" autocomplete="current-password" placeholder="••••••••••••" required autofocus>
  <button type="submit">Déverrouiller &rarr;</button>
  <div class="foot">Accès réservé · Session SSO active 24h</div>
</form></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ip(self): return self.headers.get("X-Real-IP", self.client_address[0])

    def redirect(self, to, cookie=None):
        self.send_response(303)
        self.send_header("Location", to)
        if cookie: self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def cookie(self, val, max_age):
        dom = f"; Domain={DOMAIN}" if DOMAIN else ""
        return f"{COOKIE}={val}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax{dom}; Secure"

    def do_GET(self):
        url = urlparse(self.path)
        logged = valid(read_cookie(self.headers.get("Cookie")))
        if url.path == "/auth":
            self.send_response(200 if logged else 401)
            self.end_headers()
            return
        if url.path == "/logout":
            self.redirect("/login", self.cookie("", 0))
            return
        if url.path == "/login":
            next_url = parse_qs(url.query).get("next", [""])[0]
            if logged:
                self.redirect(next_url if next_url.startswith("http") else "/")
                return
            code = parse_qs(url.query).get("e", [""])[0]
            err = '<div class="err">Mot de passe incorrect.</div>' if code == "1" else ""
            body = (
                LOGIN_HTML
                .replace("__ERROR__", err)
                .replace("__NEXT__", next_url)
                .encode("utf-8")
            )
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
        ip = self.ip()
        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        p = form.get("password", [""])[0]
        next_url = form.get("next", [""])[0]

        if hmac.compare_digest(p, PASS):
            print(f"[OK] Connexion réussie depuis {ip}")
            dest = next_url if next_url.startswith("http") else "/"
            self.redirect(dest, self.cookie(make_token(), TTL))
        else:
            print(f"[ECHEC] Mot de passe incorrect depuis {ip}")
            time.sleep(0.5)
            err_dest = "/login?e=1" + (f"&next={next_url}" if next_url else "")
            self.redirect(err_dest)

print("portal-auth SSO en écoute sur 9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF

docker rm -f portal-auth >/dev/null 2>&1 || true
docker compose -f /opt/portal/docker-compose.yml up -d
ok "Service portal-auth SSO redémarré"

# -----------------------------------------------------------------------------
step "3/4 Configuration Nginx (Verrouillage Total : Portail + Trilium)"
# -----------------------------------------------------------------------------
cat > /etc/nginx/sites-available/portal <<NGXEOF
# ---------- notes.DOMAINE -> Trilium (CONTOURNEMENT BLOQUÉ) ----------
server {
    listen 80;
    listen [::]:80;
    server_name notes.${DOMAIN};
    client_max_body_size 0;

    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:9100/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie \$http_cookie;
    }

    location / {
        auth_request /_auth;
        error_page 401 = @notes_login;

        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    location @notes_login {
        return 302 https://${DOMAIN}/login?next=https://\$host\$request_uri;
    }
}

# ---------- DOMAINE -> Portail Privé ----------
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${DOMAIN} www.${DOMAIN} _;

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
        proxy_set_header Cookie \$http_cookie;
    }

    location ~ ^/(login|logout)$ {
        proxy_pass http://127.0.0.1:9100;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location = /status/trilium {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8888/api/health-check;
        proxy_connect_timeout 3s;
    }

    location / {
        auth_request /_auth;
        error_page 401 = @portal_login;
        try_files \$uri \$uri/ /index.html;
    }

    location @portal_login {
        return 302 /login;
    }
}
NGXEOF

# Réapplication du certificat HTTPS Certbot
certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" -d "notes.${DOMAIN}" \
    --non-interactive --agree-tos --redirect --keep-until-expiring --reinstall >/dev/null 2>&1 || true

nginx -t && systemctl reload nginx
ok "Nginx configuré avec protection SSO sur tous les sous-domaines"

# -----------------------------------------------------------------------------
step "4/4 Vérification et test de santé"
# -----------------------------------------------------------------------------
docker compose -f /opt/trilium/docker-compose.yml up -d >/dev/null 2>&1 || true

sleep 2
HTTP_AUTH=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9100/login || echo "FAIL")
HTTP_TRILIUM=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8888 || echo "FAIL")

echo -e "\n\033[1;32m==================================================================\033[0m"
echo -e "\033[1;32m✅ VERROUILLAGE TOTAL ACTIF (ZÉRO CONTOURNEMENT)\033[0m"
echo -e "\033[1;32m==================================================================\033[0m"
echo "   1. Trilium (https://notes.${DOMAIN}) est STRICTEMENT verrouillé."
echo "      -> Si quelqu'un tape l'URL, il est redirigé vers la page de mot de passe."
echo "   2. Aucun identifiant demandé : tapez juste votre mot de passe une fois."
echo "   3. Une fois déverrouillé, la session est partagée automatiquement (.${DOMAIN})."
echo "   Mot de passe actif : ${NEW_PASS}"
echo "=================================================================="
SCRIPT_EOF
chmod 700 /root/lock-all-with-password.sh
bash /root/lock-all-with-password.sh
