cat > /root/reset-portal-gauth-mdp.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  PORTAIL PRIVÉ v3 — MOT DE PASSE SEUL + NOUVEAU GOOGLE AUTHENTICATOR (3 ÉCRANS)
#  - /login  : Uniquement le champ "Mot de passe" (zéro champ Identifiant)
#  - /forgot : Étape 1 -> Code Google Authenticator à 6 chiffres
#  - /reset  : Étape 2 -> Saisie et confirmation du nouveau mot de passe
#  - SSO .fabienaly.com : Protège aussi notes.fabienaly.com contre le contournement
#  - Génère un NOUVEAU QR Code Google Authenticator propre
# =============================================================================
set -uo pipefail

# Mot de passe initial par défaut (modifiable ensuite via Google Authenticator sur /forgot)
INITIAL_PASS="Lulucarab664"
DOMAIN="fabienaly.com"

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/6 Synchronisation de l'horloge NTP & outils QR Code"
# -----------------------------------------------------------------------------
timedatectl set-ntp true 2>/dev/null || true
apt-get install -y qrencode >/dev/null 2>&1 || true
ok "Horloge synchronisée : $(date)"

# -----------------------------------------------------------------------------
step "2/6 Génération d'un NOUVEAU code secret Google Authenticator & .env"
# -----------------------------------------------------------------------------
mkdir -p /opt/portal
rm -f /etc/nginx/conf.d/portal-ratelimit.conf /opt/portal/Dockerfile
rm -rf /opt/portal/data

NEW_TOTP_SECRET=$(python3 -c "import base64, os; print(base64.b32encode(os.urandom(10)).decode())")
NEW_PORTAL_SECRET=$(openssl rand -hex 32)

cat > /opt/portal/.env <<EOF
PORTAL_PASS=${INITIAL_PASS}
PORTAL_SECRET=${NEW_PORTAL_SECRET}
TOTP_SECRET=${NEW_TOTP_SECRET}
COOKIE_DOMAIN=.${DOMAIN}
COOKIE_SECURE=1
SESSION_HOURS=24
EOF
chmod 600 /opt/portal/.env

printf '%s' "${INITIAL_PASS}" > /opt/portal/password.txt
chmod 666 /opt/portal/password.txt
ok "Nouveau secret Google Authenticator généré : ${NEW_TOTP_SECRET}"
ok "Mot de passe initial défini sur : ${INITIAL_PASS}"

# -----------------------------------------------------------------------------
step "3/6 Écriture de /opt/portal/auth.py (Sans login, juste MDP + Reset GAuth 2 étapes)"
# -----------------------------------------------------------------------------
docker rm -f portal-auth >/dev/null 2>&1 || true

cat > /opt/portal/auth.py <<'PYEOF'
import base64, hashlib, hmac, os, struct, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

SECRET = os.environ.get("PORTAL_SECRET", "secret").encode()
SECURE = os.environ.get("COOKIE_SECURE", "1") == "1"
COOKIE_DOMAIN = os.environ.get("COOKIE_DOMAIN", ".fabienaly.com").strip()
TTL = int(os.environ.get("SESSION_HOURS", "24")) * 3600
TOTP_SECRET = os.environ.get("TOTP_SECRET", "").strip().replace(" ", "").upper()

PASS_FILE = "/app/password.txt"
# Nouveau nom de cookie pour éviter tout conflit avec les anciens cookies en cache dans le navigateur
COOKIE = "portal_sso_v3"
FAILS = {}

def get_pass():
    try:
        with open(PASS_FILE, "r", encoding="utf-8") as f:
            p = f.read().strip().strip("\r\n")
            if p:
                return p
    except Exception:
        pass
    return os.environ.get("PORTAL_PASS", "").strip()

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
    # Tolérance de +/- 1 créneau de 30s contre le léger décalage téléphone/serveur
    return any(hmac.compare_digest(user_code, totp_code(TOTP_SECRET, off)) for off in (-1, 0, 1))

def sign(v):
    key = SECRET + hashlib.sha256(get_pass().encode()).digest()
    return hmac.new(key, v.encode(), hashlib.sha256).hexdigest()

def make_token(kind, ttl):
    payload = f"{kind}|{int(time.time()) + ttl}"
    return f"{payload}|{sign(payload)}"

def valid_token(token, expected_kind):
    if not token or "|" not in token:
        return False
    try:
        kind, exp, sig = token.split("|")
        return kind == expected_kind and hmac.compare_digest(sig, sign(f"{kind}|{exp}")) and int(exp) > time.time()
    except Exception:
        return False

def has_valid_session(cookie_header):
    """Vérifie tous les cookies présents pour ne jamais être bloqué par un ancien cookie."""
    for part in (cookie_header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == COOKIE and valid_token(v.strip(), "session"):
            return True
    return False

BASE_STYLE = """*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100vh;display:grid;place-items:center;font-family:Inter,system-ui,-apple-system,sans-serif;background:#070b17;color:#e2e8f0;overflow:hidden}
.bg span{position:fixed;border-radius:50%;filter:blur(90px);opacity:.55;animation:f 18s ease-in-out infinite}
.bg span:nth-child(1){width:480px;height:480px;background:#7c3aed;top:-120px;left:-100px}
.bg span:nth-child(2){width:420px;height:420px;background:#0ea5e9;bottom:-140px;right:-80px;animation-delay:-6s}
.bg span:nth-child(3){width:300px;height:300px;background:#ec4899;top:40%;left:55%;animation-delay:-12s}
@keyframes f{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(40px,-30px) scale(1.1)}}
.card{position:relative;width:min(92vw,420px);padding:42px 36px;border-radius:24px;background:rgba(15,23,42,.65);border:1px solid rgba(255,255,255,.08);backdrop-filter:blur(24px);box-shadow:0 30px 80px rgba(0,0,0,.5)}
.logo{width:64px;height:64px;margin:0 auto 18px;border-radius:18px;display:grid;place-items:center;font-size:30px;background:linear-gradient(135deg,#7c3aed,#0ea5e9);box-shadow:0 10px 30px rgba(124,58,237,.45)}
h1{text-align:center;font-size:1.5rem}
.sub{text-align:center;color:#94a3b8;font-size:.9rem;margin:6px 0 24px}
label{display:block;font-size:.8rem;color:#94a3b8;margin:0 0 6px 2px}
input{width:100%;padding:13px 15px;margin-bottom:16px;border-radius:12px;border:1px solid rgba(255,255,255,.1);background:rgba(2,6,23,.6);color:#f1f5f9;font-size:.95rem;outline:none}
input:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.2)}
input.otp{letter-spacing:10px;text-align:center;font-size:1.5rem;font-weight:700}
button{width:100%;padding:13px;border:0;border-radius:12px;font-weight:600;font-size:1rem;color:#fff;cursor:pointer;background:linear-gradient(135deg,#7c3aed,#0ea5e9);transition:.2s}
button:hover{transform:translateY(-1px);box-shadow:0 10px 25px rgba(14,165,233,.35)}
.err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.ok{background:rgba(34,197,94,.12);border:1px solid rgba(34,197,94,.35);color:#86efac;padding:10px;border-radius:10px;font-size:.85rem;margin-bottom:18px;text-align:center}
.link{display:block;text-align:center;color:#94a3b8;font-size:.85rem;margin-top:16px;text-decoration:none}
.link:hover{color:#38bdf8}"""

def render_page(title, subtitle, body_html):
    return f"""<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title>
<style>{BASE_STYLE}</style></head><body>
<div class="bg"><span></span><span></span><span></span></div>
<div class="card"><div class="logo">&#128272;</div><h1>{title}</h1><p class="sub">{subtitle}</p>
{body_html}</div></body></html>""".encode("utf-8")

MESSAGES = {
    "1": ("err", "Mot de passe incorrect."),
    "2": ("err", "Trop de tentatives. Réessayez dans 2 minutes."),
    "changed": ("ok", "✅ Nouveau mot de passe enregistré ! Connectez-vous."),
    "badotp": ("err", "❌ Code Google Authenticator (6 chiffres) incorrect."),
    "nomatch": ("err", "❌ Les deux mots de passe ne correspondent pas (min. 4 caractères)."),
    "expired": ("err", "Session expirée, veuillez ressaisir le code Google Authenticator."),
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ip(self): return self.headers.get("X-Real-IP", self.client_address[0])

    def redirect(self, to, cookie=None):
        self.send_response(303)
        self.send_header("Location", to)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def send_html(self, content):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.end_headers()
        self.wfile.write(content)

    def cookie(self, value, max_age):
        flags = "; Secure" if SECURE else ""
        dom = f"; Domain={COOKIE_DOMAIN}" if COOKIE_DOMAIN else ""
        return f"{COOKIE}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax{dom}{flags}"

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

        # ÉCRAN 1 : Connexion (Uniquement le mot de passe, sans champ Identifiant)
        if url.path == "/login":
            q = parse_qs(url.query)
            next_url = q.get("next", [""])[0]
            if logged:
                self.redirect(next_url if next_url.startswith("https://") else "/")
                return
            code = q.get("e", [""])[0]
            msg = f'<div class="{MESSAGES[code][0]}">{MESSAGES[code][1]}</div>' if code in MESSAGES else ""
            self.send_html(render_page("Espace privé", "Entrez votre mot de passe pour accéder au portail", f"""
                <form method="post" action="/login">{msg}
                <input type="hidden" name="next" value="{next_url}">
                <label>Mot de passe</label>
                <input name="password" type="password" placeholder="••••••••••••" autocomplete="current-password" required autofocus>
                <button type="submit">Se connecter &rarr;</button></form>
                <a class="link" href="/forgot">Mot de passe oublié ? (Google Authenticator)</a>
            """))
            return

        # ÉCRAN 2 : Étape 1 -> Vérification Google Authenticator (uniquement les 6 chiffres)
        if url.path == "/forgot":
            code = parse_qs(url.query).get("e", [""])[0]
            msg = f'<div class="{MESSAGES[code][0]}">{MESSAGES[code][1]}</div>' if code in MESSAGES else ""
            self.send_html(render_page("Vérification 2FA", "Entrez le code à 6 chiffres de Google Authenticator", f"""
                <form method="post" action="/forgot">{msg}
                <label>Code Google Authenticator (6 chiffres)</label>
                <input class="otp" name="otp" inputmode="numeric" pattern="[0-9]{{6}}" maxlength="6" placeholder="000000" autocomplete="one-time-code" required autofocus>
                <button type="submit">Vérifier le code &rarr;</button></form>
                <a class="link" href="/login">&larr; Retour à la connexion</a>
            """))
            return

        # ÉCRAN 3 : Étape 2 -> Choisir le nouveau mot de passe (après validation GAuth)
        if url.path == "/reset":
            q = parse_qs(url.query)
            tok = q.get("t", [""])[0]
            code = q.get("e", [""])[0]
            if not valid_token(tok, "reset"):
                self.redirect("/forgot?e=expired")
                return
            msg = f'<div class="{MESSAGES[code][0]}">{MESSAGES[code][1]}</div>' if code in MESSAGES else ""
            self.send_html(render_page("Nouveau mot de passe", "Code validé ✓ Choisissez votre nouveau mot de passe", f"""
                <form method="post" action="/reset">{msg}
                <input type="hidden" name="t" value="{tok}">
                <label>Nouveau mot de passe</label>
                <input name="new_password" type="password" minlength="4" required autofocus>
                <label>Confirmer le nouveau mot de passe</label>
                <input name="confirm_password" type="password" minlength="4" required>
                <button type="submit">🔑 Enregistrer le mot de passe</button></form>
            """))
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        url = urlparse(self.path)
        length = min(int(self.headers.get("Content-Length", 0)), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="ignore"))
        ip = self.ip()
        n, t = FAILS.get(ip, [0, 0])
        if n >= 10 and time.time() - t < 120:
            self.redirect("/login?e=2")
            return

        # POST /login : vérifie uniquement le mot de passe
        if url.path == "/login":
            p = form.get("password", [""])[0].strip()
            next_url = form.get("next", [""])[0]
            if hmac.compare_digest(p, get_pass()):
                FAILS.pop(ip, None)
                dest = next_url if next_url.startswith("https://") else "/"
                self.redirect(dest, self.cookie(make_token("session", TTL), TTL))
            else:
                FAILS[ip] = [n + 1 if time.time() - t < 120 else 1, time.time()]
                time.sleep(0.5)
                err_url = "/login?e=1" + (f"&next={quote(next_url)}" if next_url else "")
                self.redirect(err_url)
            return

        # POST /forgot : vérifie le code GAuth -> redirige vers /reset
        if url.path == "/forgot":
            otp = form.get("otp", [""])[0]
            if verify_totp(otp):
                FAILS.pop(ip, None)
                tok = make_token("reset", 300)
                self.redirect(f"/reset?t={tok}")
            else:
                FAILS[ip] = [n + 1 if time.time() - t < 120 else 1, time.time()]
                time.sleep(0.5)
                self.redirect("/forgot?e=badotp")
            return

        # POST /reset : enregistre le nouveau mot de passe
        if url.path == "/reset":
            tok = form.get("t", [""])[0]
            new_p = form.get("new_password", [""])[0].strip()
            conf_p = form.get("confirm_password", [""])[0].strip()
            if not valid_token(tok, "reset"):
                self.redirect("/forgot?e=expired")
                return
            if new_p != conf_p or len(new_p) < 4:
                self.redirect(f"/reset?t={tok}&e=nomatch")
                return
            set_pass(new_p)
            FAILS.pop(ip, None)
            print(f"[OK] Mot de passe modifié via Google Authenticator depuis {ip}")
            self.redirect("/login?e=changed")
            return

print("portal-auth v3 (Mot de passe seul + Reset GAuth en 2 étapes + SSO) sur :9100")
ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
PYEOF

# -----------------------------------------------------------------------------
step "4/6 Démarrage du conteneur portal-auth"
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
      - /opt/portal/password.txt:/app/password.txt
    ports:
      - "127.0.0.1:9100:9100"
EOF

docker compose -f /opt/portal/docker-compose.yml up -d --force-recreate
ok "Conteneur portal-auth v3 démarré"

# -----------------------------------------------------------------------------
step "5/6 Configuration Nginx 1.28 (HTTPS + /login, /logout, /forgot, /reset + Protection Notes)"
# -----------------------------------------------------------------------------
cat > /etc/nginx/sites-available/portal <<'NGXEOF'
# Redirection HTTP -> HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name fabienaly.com www.fabienaly.com notes.fabienaly.com _;
    return 301 https://$host$request_uri;
}

# ---------- https://notes.fabienaly.com -> Trilium (Protégé par le SSO Portail) ----------
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

    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:9100/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
    }

    location / {
        auth_request /_auth;
        error_page 401 = @notes_login;

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

    location @notes_login {
        return 302 https://fabienaly.com/login?next=https://$host$request_uri;
    }
}

# ---------- https://fabienaly.com -> Portail avec Mot de passe seul + Reset GAuth ----------
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

    location = /login  { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location = /logout { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location = /forgot { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location = /reset  { proxy_pass http://127.0.0.1:9100; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }

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

rm -f /etc/nginx/sites-enabled/*
ln -s /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
nginx -t && systemctl restart nginx
ok "Nginx 1.28 validé et redémarré"

# -----------------------------------------------------------------------------
step "6/6 Test automatique & Affichage du NOUVEAU QR Code Google Authenticator"
# -----------------------------------------------------------------------------
sleep 2
TEST_COOKIE=$(curl -i -s -X POST -d "password=${INITIAL_PASS}" http://127.0.0.1:9100/login | grep -i "Set-Cookie" | awk '{print $2}' | tr -d '\r\n')
AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: ${TEST_COOKIE}" http://127.0.0.1:9100/auth)
ok "Auto-test de connexion par mot de passe : HTTP ${AUTH_CODE} (attendu: 200)"

WEB_URI="otpauth://totp/Portail-FabienAly?secret=${NEW_TOTP_SECRET}&issuer=fabienaly.com"

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  📱 NOUVEAU QR CODE GOOGLE AUTHENTICATOR (PORTAIL FABIENALY.COM)   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
qrencode -t ansiutf8 "$WEB_URI"
echo ""
echo "   🔑 Clé manuelle Google Authenticator : ${NEW_TOTP_SECRET}"
echo "   🔒 Mot de passe actuel du portail    : ${INITIAL_PASS}"
echo "   🌐 Lien connexion (MDP seul)         : https://fabienaly.com/login"
echo "   🔄 Lien MDP oublié (6 chiffres GAuth): https://fabienaly.com/forgot"
echo "══════════════════════════════════════════════════════════════════════"
SCRIPT_EOF
chmod 700 /root/reset-portal-gauth-mdp.sh
bash /root/reset-portal-gauth-mdp.sh
