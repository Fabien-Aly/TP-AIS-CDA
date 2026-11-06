cat > /root/fix-portal.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  Corrige le domaine du portail + active le HTTPS.
#  Relançable autant de fois que nécessaire : bash /root/fix-portal.sh
# =============================================================================
set -uo pipefail

# ============================ VOS RÉGLAGES ===================================
DOMAIN='fabienaly.com'
EMAIL='alyfabien3@gmail.com'
PORTAL_USER='Lulucarab664'
PORTAL_PASS='NouveauMotDePasse'      # pas de ' ni de $
SESSION_HOURS='12'
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lancez en root."; exit 1; }
command -v dig >/dev/null || apt-get install -y dnsutils >/dev/null

# -----------------------------------------------------------------------------
step "1/5 Identifiants du portail"
# -----------------------------------------------------------------------------
SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env | cut -d= -f2-)
[ -n "$SECRET" ] || SECRET=$(openssl rand -hex 32)
cat > /opt/portal/.env <<EOF
PORTAL_USER=${PORTAL_USER}
PORTAL_PASS=${PORTAL_PASS}
PORTAL_SECRET=${SECRET}
COOKIE_SECURE=0
SESSION_HOURS=${SESSION_HOURS}
EOF
chmod 600 /opt/portal/.env
ok "Identifiants enregistrés"

# -----------------------------------------------------------------------------
step "2/5 Domaine du site web"
# -----------------------------------------------------------------------------
OLD=$(grep -oP 'Portail · \K[^<]+' /var/www/portal/index.html | head -1)
if [ -n "$OLD" ] && [ "$OLD" != "$DOMAIN" ]; then
    sed -i "s/${OLD//./\\.}/${DOMAIN}/g" /var/www/portal/index.html
    ok "Site : $OLD -> $DOMAIN"
else
    ok "Site déjà sur $DOMAIN"
fi

# -----------------------------------------------------------------------------
step "3/5 Configuration Nginx"
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
if nginx -t 2>/dev/null; then systemctl reload nginx; ok "Nginx rechargé"; else nginx -t; exit 1; fi

# -----------------------------------------------------------------------------
step "4/5 Vérification DNS + certificat HTTPS"
# -----------------------------------------------------------------------------
SERVER_IP=$(curl -4 -fs --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
echo "IP publique du VPS : $SERVER_IP"
CERT_ARGS=(); PORTAL_SSL=0
for d in "$DOMAIN" "www.$DOMAIN" "notes.$DOMAIN"; do
    a=$(dig +short A "$d" @1.1.1.1 | grep -E '^[0-9.]+$' | tr '\n' ' ')
    aaaa=$(dig +short AAAA "$d" @1.1.1.1 | grep ':' | tr '\n' ' ')
    if [ "${a% }" != "$SERVER_IP" ]; then
        warn "$d : A = '${a:-aucun}' (attendu $SERVER_IP) -> ajoutez/corrigez l'enregistrement A chez IONOS"
    elif [ -n "$aaaa" ]; then
        warn "$d : AAAA parasite ($aaaa) -> supprimez cet enregistrement AAAA chez IONOS"
    else
        ok "$d -> $SERVER_IP"
        CERT_ARGS+=(-d "$d")
        [ "$d" = "notes.$DOMAIN" ] || PORTAL_SSL=1
    fi
done

if [ ${#CERT_ARGS[@]} -gt 0 ] && certbot --nginx "${CERT_ARGS[@]}" --cert-name "$DOMAIN" \
        --non-interactive --agree-tos -m "$EMAIL" --redirect --expand --keep-until-expiring; then
    ok "Certificat HTTPS installé"
    [ "$PORTAL_SSL" = 1 ] && sed -i 's/^COOKIE_SECURE=.*/COOKIE_SECURE=1/' /opt/portal/.env
else
    PORTAL_SSL=0
    warn "HTTPS pas encore actif : corrigez le DNS, attendez 10 min et relancez : bash /root/fix-portal.sh"
fi

# -----------------------------------------------------------------------------
step "5/5 Redémarrage du service de connexion"
# -----------------------------------------------------------------------------
docker compose -f /opt/portal/docker-compose.yml up -d --force-recreate >/dev/null 2>&1
docker compose -f /opt/trilium/docker-compose.yml up -d >/dev/null 2>&1

P=$([ "$PORTAL_SSL" = 1 ] && echo https || echo http)
echo -e "\n\033[1;32m✅ Terminé\033[0m"
echo "   Portail : $P://$DOMAIN   (identifiant : $PORTAL_USER)"
echo "   Trilium : $P://notes.$DOMAIN"
docker ps --format "table {{.Names}}\t{{.Status}}"
SCRIPT_EOF
chmod 700 /root/fix-portal.sh
bash /root/fix-portal.sh
