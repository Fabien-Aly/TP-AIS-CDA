#!/usr/bin/env bash
# =============================================================================
#  INSTALLATION COMPLÈTE — Portail web privé (avec login) + Trilium Notes
#  VPS Ubuntu / Debian (IONOS) — Nginx (port 80/443) + Docker
#
#  Résultat :
#    http(s)://VOTREDOMAINE        -> Page de connexion -> Portail de services
#    http(s)://notes.VOTREDOMAINE  -> Trilium Notes (IP et port cachés)
#
#  Prérequis DNS chez IONOS (enregistrements de type A) :
#    @      -> IP_DU_VPS
#    notes  -> IP_DU_VPS
# =============================================================================
set -euo pipefail

# ----------------------------- À PERSONNALISER -------------------------------
#  Le plus propre : mettez vos valeurs dans /root/portal.conf (mêmes noms de
#  variables). Ce fichier est prioritaire, vous pouvez donc remplacer ce script
#  par une nouvelle version sans perdre votre configuration.
DOMAIN="votredomaine.fr"          # Votre domaine IONOS (sans http, sans www)
EMAIL="vous@votredomaine.fr"      # Pour le certificat SSL Let's Encrypt
PORTAL_USER="admin"               # Identifiant du portail
PORTAL_PASS="ChangezMoi2026"      # Mot de passe du portail (évitez le caractère $)
ENABLE_SSL="oui"                  # "oui" = HTTPS gratuit (DNS doit déjà pointer sur le VPS)
SESSION_HOURS="12"                # Durée de la session après connexion
SSH_PORT="22"                     # Port SSH (ne pas se bloquer dehors !)
# -----------------------------------------------------------------------------
# shellcheck disable=SC1091
[ -f /root/portal.conf ] && . /root/portal.conf

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script en root."; exit 1; }
[ "$DOMAIN" != "votredomaine.fr" ] || { echo "Créez /root/portal.conf (ou modifiez DOMAIN en haut du script)."; exit 1; }

# -----------------------------------------------------------------------------
log "1/7 Installation des paquets (Nginx, Certbot, UFW, Docker)"
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
# Supprime un éventuel dépôt Docker "debian" ajouté par erreur sur Ubuntu (provoque une erreur 404)
grep -rl "download.docker.com/linux/debian" /etc/apt/sources.list.d/ 2>/dev/null | xargs -r rm -f
apt-get update -y
apt-get install -y nginx ufw curl openssl dnsutils certbot python3-certbot-nginx
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker nginx

# -----------------------------------------------------------------------------
log "2/7 Pare-feu (SSH, 80, 443 uniquement)"
# -----------------------------------------------------------------------------
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw delete allow 8888/tcp >/dev/null 2>&1 || true
ufw --force enable

# -----------------------------------------------------------------------------
log "3/7 Trilium Notes (Docker, accessible uniquement via Nginx)"
# -----------------------------------------------------------------------------
mkdir -p /opt/trilium/trilium-data
cat > /opt/trilium/docker-compose.yml <<'EOF'
services:
  trilium:
    image: triliumnext/trilium:latest
    container_name: trilium
    restart: unless-stopped
    ports:
      - "127.0.0.1:8888:8080"   # écoute en local seulement : port invisible depuis Internet
    volumes:
      - /opt/trilium/trilium-data:/home/node/trilium-data
    environment:
      - TZ=Europe/Paris
EOF
chown -R 1000:1000 /opt/trilium/trilium-data
docker rm -f trilium >/dev/null 2>&1 || true
docker compose -f /opt/trilium/docker-compose.yml up -d

# Activation des scripts backend (nécessaire pour le module IA)
CFG=/opt/trilium/trilium-data/config.ini
for _ in $(seq 1 30); do [ -f "$CFG" ] && break; sleep 1; done
if [ -f "$CFG" ]; then
    if grep -q '^backendScriptingEnabled' "$CFG"; then
        sed -i 's/^backendScriptingEnabled.*/backendScriptingEnabled=true/' "$CFG"
    elif grep -q '^\[Security\]' "$CFG"; then
        sed -i '/^\[Security\]/a backendScriptingEnabled=true' "$CFG"
    else
        printf '\n[Security]\nbackendScriptingEnabled=true\n' >> "$CFG"
    fi
    chown 1000:1000 "$CFG"
    docker restart trilium >/dev/null
else
    warn "config.ini introuvable : ajoutez [Security] backendScriptingEnabled=true plus tard."
fi

# -----------------------------------------------------------------------------
log "4/7 Service d'authentification du portail"
# -----------------------------------------------------------------------------
mkdir -p /opt/portal
# On garde la clé de session existante (pas de déconnexion forcée à chaque relance)
SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env | cut -d= -f2- || true)
[ -n "$SECRET" ] || SECRET=$(openssl rand -hex 32)
cat > /opt/portal/.env <<EOF
PORTAL_USER=${PORTAL_USER}
PORTAL_PASS=${PORTAL_PASS}
PORTAL_SECRET=${SECRET}
COOKIE_SECURE=0
SESSION_HOURS=${SESSION_HOURS}
EOF
chmod 600 /opt/portal/.env

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

# -----------------------------------------------------------------------------
log "5/7 Site web du portail"
# -----------------------------------------------------------------------------
mkdir -p /var/www/portal
cat > /var/www/portal/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Portail · __DOMAIN__</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🚀</text></svg>">
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--txt:#e2e8f0;--muted:#94a3b8;--glass:rgba(15,23,42,.55);--line:rgba(255,255,255,.08)}
body{min-height:100vh;font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;background:#070b17;color:var(--txt);overflow-x:hidden}
.bg span{position:fixed;border-radius:50%;filter:blur(110px);opacity:.45;z-index:-1;animation:f 22s ease-in-out infinite}
.bg span:nth-child(1){width:560px;height:560px;background:#7c3aed;top:-180px;left:-160px}
.bg span:nth-child(2){width:480px;height:480px;background:#0ea5e9;bottom:-200px;right:-120px;animation-delay:-7s}
.bg span:nth-child(3){width:340px;height:340px;background:#ec4899;top:45%;left:50%;animation-delay:-14s}
@keyframes f{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(50px,-40px) scale(1.12)}}
.grain{position:fixed;inset:0;z-index:-1;background-image:radial-gradient(rgba(255,255,255,.04) 1px,transparent 1px);background-size:3px 3px}

header{display:flex;justify-content:space-between;align-items:center;padding:22px clamp(18px,5vw,56px)}
.brand{display:flex;align-items:center;gap:12px;font-weight:700;letter-spacing:.3px}
.brand i{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;font-style:normal;background:linear-gradient(135deg,#7c3aed,#0ea5e9);box-shadow:0 8px 24px rgba(124,58,237,.4)}
.logout{color:var(--muted);text-decoration:none;font-size:.88rem;padding:9px 16px;border-radius:10px;border:1px solid var(--line);background:var(--glass);backdrop-filter:blur(14px);transition:.2s}
.logout:hover{color:#fff;border-color:rgba(239,68,68,.5)}

main{max-width:1100px;margin:0 auto;padding:30px clamp(18px,5vw,56px) 60px}
.hero{text-align:center;margin:30px 0 44px;animation:in .7s ease}
.clock{font-size:clamp(3.4rem,10vw,6rem);font-weight:800;letter-spacing:-2px;background:linear-gradient(135deg,#fff 30%,#a5b4fc);-webkit-background-clip:text;background-clip:text;color:transparent;line-height:1}
.greet{font-size:1.25rem;margin-top:14px}
.date{color:var(--muted);margin-top:4px;text-transform:capitalize}
@keyframes in{from{opacity:0;transform:translateY(18px)}}

.search{position:relative;max-width:520px;margin:0 auto 38px}
.search input{width:100%;padding:15px 18px 15px 48px;border-radius:14px;border:1px solid var(--line);background:var(--glass);backdrop-filter:blur(18px);color:#fff;font-size:1rem;outline:none;transition:.2s}
.search input:focus{border-color:#8b5cf6;box-shadow:0 0 0 4px rgba(139,92,246,.18)}
.search svg{position:absolute;left:17px;top:50%;transform:translateY(-50%);opacity:.5}
.search kbd{position:absolute;right:14px;top:50%;transform:translateY(-50%);font-size:.75rem;color:var(--muted);border:1px solid var(--line);padding:2px 7px;border-radius:6px}

.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:20px}
.card{position:relative;display:flex;flex-direction:column;gap:14px;padding:24px;border-radius:20px;text-decoration:none;color:var(--txt);background:var(--glass);border:1px solid var(--line);backdrop-filter:blur(18px);transition:transform .25s,border-color .25s,box-shadow .25s;animation:in .6s ease both;overflow:hidden}
.card::before{content:"";position:absolute;inset:0;background:radial-gradient(400px circle at var(--x,50%) var(--y,0%),rgba(255,255,255,.07),transparent 40%);opacity:0;transition:.3s}
.card:hover{transform:translateY(-6px);border-color:rgba(255,255,255,.18);box-shadow:0 24px 50px rgba(0,0,0,.45)}
.card:hover::before{opacity:1}
.top{display:flex;justify-content:space-between;align-items:center}
.icon{width:54px;height:54px;border-radius:15px;display:grid;place-items:center;font-size:26px}
.status{font-size:.75rem;padding:5px 10px;border-radius:999px;background:rgba(148,163,184,.12);color:var(--muted);display:flex;align-items:center;gap:6px}
.status::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.status.up{color:#4ade80;background:rgba(74,222,128,.1)}
.status.up::before{box-shadow:0 0 10px #4ade80;animation:p 2s infinite}
.status.down{color:#f87171;background:rgba(248,113,113,.1)}
@keyframes p{50%{opacity:.4}}
.card h3{font-size:1.15rem}
.card p{color:var(--muted);font-size:.9rem;line-height:1.5}
.meta{display:flex;justify-content:space-between;align-items:center;margin-top:auto;font-size:.8rem;color:#64748b}
.arrow{transition:transform .25s}
.card:hover .arrow{transform:translateX(5px);color:#fff}
.card.soon{opacity:.6;border-style:dashed}
.empty{text-align:center;color:var(--muted);padding:40px;display:none}
footer{text-align:center;color:#475569;font-size:.8rem;padding:30px}
</style>
</head>
<body>
<div class="bg"><span></span><span></span><span></span></div><div class="grain"></div>

<header>
  <div class="brand"><i>🚀</i> __DOMAIN__</div>
  <a class="logout" href="/logout">⎋ Déconnexion</a>
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
    <kbd>/</kbd>
  </div>

  <div class="grid" id="grid"></div>
  <div class="empty" id="empty">Aucun service trouvé 🔍</div>
</main>

<footer>Portail privé · <span id="year"></span> · Touches <b>1-9</b> pour ouvrir un service</footer>

<script>
/* ====================================================================
   VOS SERVICES — ajoutez simplement un bloc { ... } pour chaque service
   url    : adresse du service (sous-domaine conseillé)
   status : (optionnel) URL de test protégée par le portail (voir Nginx)
   ==================================================================== */
const SERVICES = [
  { name: "Trilium Notes", desc: "Base de connaissances personnelle & assistant IA de correction.",
    icon: "📓", url: "//notes.__DOMAIN__", status: "/status/trilium",
    color: ["#7c3aed", "#c084fc"], tag: "Notes · IA" },
  { name: "Nouveau service", desc: "Emplacement libre : Nextcloud, Portainer, Uptime Kuma…",
    icon: "➕", url: "#", color: ["#334155", "#64748b"], tag: "Bientôt", soon: true }
];

const grid = document.getElementById("grid");
SERVICES.forEach((s, i) => {
  const a = document.createElement("a");
  a.className = "card" + (s.soon ? " soon" : "");
  a.href = s.url; a.dataset.search = (s.name + " " + s.desc + " " + s.tag).toLowerCase();
  a.style.animationDelay = (i * 0.07) + "s";
  a.innerHTML = `
    <div class="top">
      <div class="icon" style="background:linear-gradient(135deg,${s.color[0]},${s.color[1]});box-shadow:0 10px 26px ${s.color[0]}66">${s.icon}</div>
      <span class="status" id="st${i}">${s.status ? "Vérification…" : (s.soon ? "À venir" : "Lien")}</span>
    </div>
    <div><h3>${s.name}</h3><p>${s.desc}</p></div>
    <div class="meta"><span>${i < 9 ? "[" + (i + 1) + "] " : ""}${s.tag}</span><span class="arrow">→</span></div>`;
  a.addEventListener("mousemove", e => {
    const r = a.getBoundingClientRect();
    a.style.setProperty("--x", (e.clientX - r.left) + "px");
    a.style.setProperty("--y", (e.clientY - r.top) + "px");
  });
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

// Horloge, salutation, date
function tick() {
  const d = new Date(), h = d.getHours();
  document.getElementById("clock").textContent = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  document.getElementById("greet").textContent = (h < 6 ? "Bonne nuit" : h < 18 ? "Bonjour" : "Bonsoir") + " 👋";
  document.getElementById("date").textContent = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
}
tick(); setInterval(tick, 1000);
document.getElementById("year").textContent = new Date().getFullYear();

// Recherche + raccourcis clavier
const q = document.getElementById("q");
q.addEventListener("input", () => {
  const v = q.value.toLowerCase().trim(); let n = 0;
  document.querySelectorAll(".card").forEach(c => {
    const ok = c.dataset.search.includes(v); c.style.display = ok ? "" : "none"; n += ok;
  });
  document.getElementById("empty").style.display = n ? "none" : "block";
});
q.addEventListener("keydown", e => {
  if (e.key === "Enter") { const c = [...document.querySelectorAll(".card")].find(c => c.style.display !== "none"); if (c) location.href = c.href; }
  if (e.key === "Escape") { q.value = ""; q.dispatchEvent(new Event("input")); q.blur(); }
});
document.addEventListener("keydown", e => {
  if (document.activeElement === q) return;
  if (e.key === "/") { e.preventDefault(); q.focus(); }
  const n = parseInt(e.key, 10);
  if (n >= 1 && n <= 9 && SERVICES[n - 1] && !SERVICES[n - 1].soon) location.href = SERVICES[n - 1].url;
});
</script>
</body>
</html>
HTMLEOF
sed -i "s/__DOMAIN__/${DOMAIN}/g" /var/www/portal/index.html

# -----------------------------------------------------------------------------
log "6/7 Configuration Nginx"
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
        proxy_read_timeout 300s;      # laisse le temps aux appels IA
    }
}

# ---------- DOMAINE (ou IP) -> Portail avec login ----------
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name __DOMAIN__ www.__DOMAIN__ _;

    root /var/www/portal;
    index index.html;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Vérification de session (interne)
    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:9100/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
    }

    # Page de connexion / déconnexion
    location ~ ^/(login|logout)$ {
        proxy_pass http://127.0.0.1:9100;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Indicateur "En ligne" de Trilium sur le portail
    location = /status/trilium {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:8888/api/health-check;
        proxy_connect_timeout 3s;
    }

    # Portail protégé
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
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
nginx -t
systemctl reload nginx

# -----------------------------------------------------------------------------
log "7/7 HTTPS + sauvegardes automatiques"
# -----------------------------------------------------------------------------
if [ "$ENABLE_SSL" = "oui" ]; then
    # Vérifie le DNS AVANT de demander le certificat (via un résolveur public)
    SERVER_IP=$(curl -4 -fs --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
    echo "IP publique du VPS : $SERVER_IP"
    CERT_ARGS=(); PORTAL_SSL=0
    for d in "$DOMAIN" "www.$DOMAIN" "notes.$DOMAIN"; do
        a=$(dig +short A "$d" @1.1.1.1 | grep -E '^[0-9.]+$' | tr '\n' ' ' || true)
        aaaa=$(dig +short AAAA "$d" @1.1.1.1 | grep ':' | tr '\n' ' ' || true)
        if [ "${a% }" != "$SERVER_IP" ]; then
            warn "$d : enregistrement A = '${a:-aucun}' (attendu : $SERVER_IP) -> ignoré"
        elif [ -n "$aaaa" ]; then
            warn "$d : enregistrement AAAA parasite ($aaaa) -> supprimez-le chez IONOS -> ignoré"
        else
            ok "$d -> $SERVER_IP"
            CERT_ARGS+=(-d "$d")
            [ "$d" = "notes.$DOMAIN" ] || PORTAL_SSL=1
        fi
    done

    if [ ${#CERT_ARGS[@]} -gt 0 ] && certbot --nginx "${CERT_ARGS[@]}" --cert-name "$DOMAIN" \
            --non-interactive --agree-tos -m "$EMAIL" --redirect --expand --keep-until-expiring; then
        ok "Certificat HTTPS installé"
        if [ "$PORTAL_SSL" = 1 ]; then
            sed -i 's/^COOKIE_SECURE=.*/COOKIE_SECURE=1/' /opt/portal/.env
            docker compose -f /opt/portal/docker-compose.yml up -d --force-recreate
        fi
    else
        PORTAL_SSL=0
        warn "HTTPS pas encore actif. Corrigez le DNS, attendez 5-10 min, puis relancez ce script."
    fi
fi

mkdir -p /opt/backups/trilium
cat > /etc/cron.daily/backup-trilium <<'EOF'
#!/bin/bash
tar -czf /opt/backups/trilium/trilium-$(date +%F).tar.gz -C /opt/trilium/trilium-data .
find /opt/backups/trilium/ -type f -name "*.tar.gz" -mtime +7 -delete
EOF
chmod +x /etc/cron.daily/backup-trilium

PROTO=$([ "${PORTAL_SSL:-0}" = 1 ] && echo https || echo http)
echo -e "\n\033[1;32m✅ Installation terminée !\033[0m"
echo "   Portail : ${PROTO}://${DOMAIN}   (identifiant : ${PORTAL_USER})"
echo "   Trilium : ${PROTO}://notes.${DOMAIN}"
echo "   Sauvegardes quotidiennes : /opt/backups/trilium (7 jours)"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
