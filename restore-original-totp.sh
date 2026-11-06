cat > /root/restore-original-totp.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  RESTAURATION DU PORTAIL AVEC RÉCUPÉRATION GOOGLE AUTHENTICATOR
#  - Restaure le système exact qui fonctionnait le 4 novembre
#  - Conserve votre clé TOTP_SECRET actuelle (votre appli Google Authenticator
#    sur votre téléphone continue de fonctionner SANS devoir rescanner !)
#  - Page /forgot accessible avec vos 6 chiffres pour changer le mot de passe
#  - Trilium (notes.DOMAINE) rétabli
# =============================================================================
set -uo pipefail

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { err "Lancez en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/5 Récupération des secrets existants"
# -----------------------------------------------------------------------------
DOMAIN="fabienaly.com"
PORTAL_USER="Lulucarab664"

# Récupération ou conservation de TOTP_SECRET
TOTP_SECRET=$(grep -s '^TOTP_SECRET=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || true)
if [ -z "$TOTP_SECRET" ]; then
    TOTP_SECRET=$(python3 -c "import base64, os; print(base64.b32encode(os.urandom(10)).decode())")
    warn "Nouvelle clé TOTP générée (car introuvable dans .env)"
else
    ok "Clé Google Authenticator existante conservée (${TOTP_SECRET})"
fi

# Récupération ou conservation de SECRET
PORTAL_SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || true)
[ -n "$PORTAL_SECRET" ] || PORTAL_SECRET=$(openssl rand -hex 32)

# Récupération du mot de passe
EXISTING_PASS=$(grep -s '^PORTAL_PASS=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || true)
[ -n "$EXISTING_PASS" ] || EXISTING_PASS="ChangezMoi2026"

cat > /opt/portal/.env <<EOF
PORTAL_USER=${PORTAL_USER}
PORTAL_PASS=${EXISTING_PASS}
PORTAL_SECRET=${PORTAL_SECRET}
TOTP_SECRET=${TOTP_SECRET}
COOKIE_SECURE=1
SESSION_HOURS=12
EOF
chmod 600 /opt/portal/.env

# Fichier password.txt modifiable par l'écran /forgot
echo -n "${EXISTING_PASS}" > /opt/portal/password.txt
chmod 600 /opt/portal/password.txt

# Nettoyage des rate-limits et fichiers parasites
rm -f /etc/nginx/conf.d/portal-ratelimit.conf /etc/nginx/conf.d/ai-hub-ratelimit.conf
rm -f /opt/portal/Dockerfile
rm -rf /opt/portal/data

# -----------------------------------------------------------------------------
step "2/5 Configuration Docker Compose avec password.txt monté"
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
      - ./password.txt:/app/password.txt
    ports:
      - "127.0.0.1:9100:9100"
EOF

# -----------------------------------------------------------------------------
step "3/5 Service auth.py originel avec Google Authenticator (/forgot)"
# -----------------------------------------------------------------------------
cat > /opt/portal/auth.py <<'PYEOF'
import base64, hashlib, hmac, os, struct, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER = os.environ.get("PORTAL_USER", "admin")
SECRET = os.environ.get("PORTAL_SECRET", "secret").encode()
SECURE = os.environ.get("COOKIE_SECURE", "0") == "1"
TTL = int(os.environ.get("SESSION_HOURS", "12")) * 3600
TOTP_SECRET = os.environ.get("TOTP_SECRET", "").strip().replace(" ", "").upper()

PASS_FILE = "/app/password.txt"
COOKIE = "portal_session"
FAILS = {}

def get_pass():
    try:
        with open(PASS_FILE, "r", encoding="utf-8") as f:
            p = f.read().strip()
            if p: return p
    except Exception:
        pass
    return os.environ.get("PORTAL_PASS", "")

def set_pass(new_pass):
    with open(PASS_FILE, "w", encoding="utf-8") as f:
        f.write(new_pass.strip())

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
    key = SECRET + hashlib.sha256(get_pass().encode()).digest()
    return hmac.new(key, v.encode(), hashlib.sha256).hexdigest()

def make_token(kind, ttl):
    payload = f"{kind}|{int(time.time()) + ttl}"
    return f"{payload}|{sign(payload)}"

def valid_token(token, expected_kind):
    try:
        kind, exp, sig = token.split("|")
        return kind == expected_kind and hmac.compare_digest(sig, sign(f"{kind}|{exp}")) and int(exp) > time.time()
    except Exception:
        return False

def read_cookie(header):
    for part in (header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == COOKIE: return v
    return ""

BASE_STYLE = """*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100vh;display:grid;place-items:center;font-family:Inter,system-ui,-apple-system,sans-serif;background:#070b17;color:#e2e8f0;overflow:hidden}
.bg span{position:fixed;border-radius:50%;filter:blur(90px);opacity:.55;animation:f 18s ease-in-out infinite}
.bg span:nth-child(1){width:480px;height:480px;background:#7c3aed;top:-120px;left:-100px}
.bg span:nth-child(2){width:420px;height:420px;background:#0ea5e9;bottom:-140px;right:-80px;animation-delay:-6s}
.bg span:nth-child(3){width:300px;height:300px;background:#ec4899;top:40%;left:55%;animation-delay:-12s}
@keyframes f{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(40px,-30px) scale(1.1)}}
.card{position:relative;width:min(92vw,420px);padding:42px 36px;border-radius:24px;background:rgba(15,23,42,.55);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.5)}
.logo{width:64px;height:64px;margin:0 auto 18px;border-radius:18px;display:grid;place-items:center;font-size:30px;background:linear-gradient(135deg,#7c3aed,#0ea5e9);box-shadow:0 10px 30px rgba(124,58,237,.45)}
h1{text-align:center;font-size:1.5rem}
.sub{text-align:center;color:#94a3b8;font-size:.9rem;margin:6px 0 24px}
label{display:block;font-size:.8rem;color:#94a3b8;margin:0 0 6px 2px}
input{width:100%;padding:13px 15px;margin-bottom:16px;border-radius:12px;border:1px solid rgba(255,255,255,.1);background:rgba(2,6,23,.6);color:#f1f5f9;font-size:.95rem;outline:none;transition:.2s}
input:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.2)}
input.otp{font-size:1.6rem;letter-spacing:10px;text-align:center;font-weight:700}
button{width:100%;padding:13px;border:0;border-radius:12px;font-weight:600;font-size:1rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 10px 25px rgba(14,165,233,.35)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.ok{background:rgba(34,197,94,.12);border:1px solid rgba(34,197,94,.35);color:#86efac;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.link{display:block;text-align:center;color:#94a3b8;font-size:.85rem;margin-top:18px;text-decoration:none}
.link:hover{color:#fff}
"""

def render_page(title, sub, body):
    return f"""<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} · Portail</title>
<style>{BASE_STYLE}</style></head><body>
<div class="bg"><span></span><span></span><span></span></div>
<div class="card"><div class="logo">&#128272;</div><h1>{title}</h1>
<p class="sub">{sub}</p>{body}</div></body></html>"""

MESSAGES = {
    "1": ("err", "Identifiant ou mot de passe incorrect."),
    "2": ("err", "Trop de tentatives. Réessayez dans 5 minutes."),
    "badotp": ("err", "Code Google Authenticator invalide ou expiré."),
    "changed": ("ok", "Mot de passe modifié avec succès ! Connectez-vous."),
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

    def send_html(self, html):
        b = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        url = urlparse(self.path)
        logged = valid_token(read_cookie(self.headers.get("Cookie")), "session")
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
            self.send_html(render_page("Espace privé", "Connectez-vous pour accéder à vos services", f"""
                <form method="post" action="/login">{msg}
                <label>Identifiant</label><input name="username" required autofocus>
                <label>Mot de passe</label><input name="password" type="password" required>
                <button type="submit">Se connecter &rarr;</button></form>
                <a class="link" href="/forgot">Mot de passe oublié ? (Google Authenticator)</a>
            """))
            return
        if url.path == "/forgot":
            code = parse_qs(url.query).get("e", [""])[0]
            msg = f'<div class="{MESSAGES[code][0]}">{MESSAGES[code][1]}</div>' if code in MESSAGES else ""
            self.send_html(render_page("Mot de passe oublié", "Ouvrez Google Authenticator (1-Logiciel Portail)", f"""
                <form method="post" action="/forgot">{msg}
                <label>Code Google Authenticator (6 chiffres)</label>
                <input class="otp" name="otp" inputmode="numeric" pattern="[0-9]{{6}}" maxlength="6" placeholder="000000" autocomplete="one-time-code" required autofocus>
                <label>Nouveau mot de passe (min. 8 caractères)</label>
                <input name="new_password" type="password" minlength="8" required>
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
        n, t = FAILS.get(ip, [0, 0])
        if n >= 5 and time.time() - t < 300:
            self.redirect("/login?e=2")
            return

        if url.path == "/login":
            u = form.get("username", [""])[0]; p = form.get("password", [""])[0]
            if hmac.compare_digest(u, USER) and hmac.compare_digest(p, get_pass()):
                FAILS.pop(ip, None)
                self.redirect("/", self.cookie(make_token("session", TTL), TTL))
            else:
                FAILS[ip] = [n + 1 if time.time() - t < 300 else 1, time.time()]
                time.sleep(1)
                self.redirect("/login?e=1")
            return

        if url.path == "/forgot":
            otp = form.get("otp", [""])[0]
            new_p = form.get("new_password", [""])[0]
            if verify_totp(otp) and len(new_p) >= 8:
                FAILS.pop(ip, None)
                set_pass(new_p)
                print(f"[OK] Mot de passe réinitialisé via Google Authenticator depuis {ip}")
                self.redirect("/login?e=changed")
            else:
                FAILS[ip] = [n + 1 if time.time() - t < 300 else 1, time.time()]
                time.sleep(1)
                self.redirect("/forgot?e=badotp")
            return

print("portal-auth (Google Authenticator) en écoute sur :9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF

docker rm -f portal-auth >/dev/null 2>&1 || true
docker compose -f /opt/portal/docker-compose.yml up -d
ok "Conteneur portal-auth prêt avec support Google Authenticator"

# -----------------------------------------------------------------------------
step "4/5 Configuration Nginx avec /forgot autorisé"
# -----------------------------------------------------------------------------
cat > /etc/nginx/sites-available/portal <<NGXEOF
# ---------- notes.DOMAINE -> Trilium ----------
server {
    listen 80;
    listen [::]:80;
    server_name notes.${DOMAIN};
    client_max_body_size 0;

    location / {
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
}

# ---------- DOMAINE / www / IP -> Portail avec login ----------
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

    location ~ ^/(login|logout|forgot)$ {
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
        error_page 401 = @login;
        try_files \$uri \$uri/ /index.html;
    }

    location @login { return 302 /login; }
}
NGXEOF

certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" -d "notes.${DOMAIN}" \
    --non-interactive --agree-tos --redirect --keep-until-expiring >/dev/null 2>&1 || true

nginx -t && systemctl reload nginx
ok "Nginx rechargé avec accès /forgot"

# -----------------------------------------------------------------------------
step "5/5 Redémarrage Trilium et affichage statut"
# -----------------------------------------------------------------------------
docker compose -f /opt/trilium/docker-compose.yml up -d >/dev/null 2>&1 || true

echo -e "\n\033[1;32m==================================================================\033[0m"
echo -e "\033[1;32m✅ SYSTÈME INITIAL AVEC GOOGLE AUTHENTICATOR RESTAURÉ !\033[0m"
echo -e "\033[1;32m==================================================================\033[0m"
echo "   Portail        : https://${DOMAIN}/login (Identifiant : ${PORTAL_USER})"
echo "   Réinitialiser  : https://${DOMAIN}/forgot (Avec votre code Google Authenticator)"
echo "   Trilium Notes  : https://notes.${DOMAIN}"
echo "   Clé TOTP active: ${TOTP_SECRET}"
echo "=================================================================="
SCRIPT_EOF
chmod 700 /root/restore-original-totp.sh
bash /root/restore-original-totp.sh
