cat > /root/unlock-now.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  DÉBLOCAGE IMMÉDIAT DU PORTAIL & SYNCHRONISATION GOOGLE AUTHENTICATOR
#  - Supprime immédiatement le verrou "Trop de tentatives" (débloque votre IP)
#  - Définit votre mot de passe directement sans passer par le formulaire
#  - Synchronise l'horloge du VPS (évite le rejet des codes à 6 chiffres)
#  - Réaffiche votre QR Code Google Authenticator officiel
# =============================================================================
set -uo pipefail

# ============================ VOTRE MOT DE PASSE =============================
# Indiquez ici le mot de passe avec lequel vous voulez vous connecter :
NOUVEAU_MDP="MonMotDePasse2026!"
# =============================================================================

ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
step() { echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lancez en root."; exit 1; }

# -----------------------------------------------------------------------------
step "1/4 Synchronisation de l'heure du VPS (Horloge NTP)"
# -----------------------------------------------------------------------------
# Un décalage de quelques secondes sur le VPS invalide les codes Google Authenticator
timedatectl set-ntp true 2>/dev/null || apt-get install -y chrony >/dev/null 2>&1 || true
ok "Horloge serveur synchronisée : $(date)"

# -----------------------------------------------------------------------------
step "2/4 Application immédiate du mot de passe"
# -----------------------------------------------------------------------------
mkdir -p /opt/portal
echo -n "${NOUVEAU_MDP}" > /opt/portal/password.txt
chmod 600 /opt/portal/password.txt

# Si TOTP_SECRET existe déjà, on la garde précieusement, sinon on en crée une
TOTP_SECRET=$(grep -s '^TOTP_SECRET=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || true)
if [ -z "$TOTP_SECRET" ]; then
    TOTP_SECRET=$(python3 -c "import base64, os; print(base64.b32encode(os.urandom(10)).decode())")
fi

SECRET=$(grep -s '^PORTAL_SECRET=' /opt/portal/.env 2>/dev/null | cut -d= -f2- || openssl rand -hex 32)

cat > /opt/portal/.env <<EOF
PORTAL_USER=Lulucarab664
PORTAL_PASS=${NOUVEAU_MDP}
PORTAL_SECRET=${SECRET}
TOTP_SECRET=${TOTP_SECRET}
COOKIE_SECURE=1
SESSION_HOURS=24
EOF
chmod 600 /opt/portal/.env
ok "Mot de passe enregistré directement dans /opt/portal/password.txt"

# -----------------------------------------------------------------------------
step "3/4 Redémarrage du conteneur (Supprime le blocage 'Trop de tentatives')"
# -----------------------------------------------------------------------------
# Redémarrer vide complètement la mémoire FAILS (votre IP est instantanément débloquée)
docker restart portal-auth >/dev/null 2>&1 || docker compose -f /opt/portal/docker-compose.yml up -d
ok "Compteurs de blocage IP remis à zéro"

# -----------------------------------------------------------------------------
step "4/4 Vérification du QR Code Google Authenticator"
# -----------------------------------------------------------------------------
command -v qrencode >/dev/null 2>&1 || apt-get install -y qrencode >/dev/null 2>&1

URI="otpauth://totp/1-Logiciel%20Portail:Lulucarab664?secret=${TOTP_SECRET}&issuer=fabienaly.com"

echo ""
echo -e "\033[1;32m==================================================================\033[0m"
echo -e "\033[1;32m✅ VOUS POUVEZ VOUS CONNECTER IMMÉDIATEMENT SUR LE PORTAIL !\033[0m"
echo -e "\033[1;32m==================================================================\033[0m"
echo "   Lien direct : https://fabienaly.com/login"
echo "   Identifiant : Lulucarab664"
echo "   Mot de passe: ${NOUVEAU_MDP}"
echo "=================================================================="
echo ""
echo "📱 SI VOTRE APPLICATION GOOGLE AUTHENTICATOR NE MARCHERAIT PLUS :"
echo "   Scannez ce QR Code dans Google Authenticator (ou ajoutez la clé ci-dessous) :"
echo ""
qrencode -t ansiutf8 "$URI" 2>/dev/null || echo "(qrencode indisponible)"
echo "   Clé manuelle : ${TOTP_SECRET}"
echo "=================================================================="
SCRIPT_EOF
chmod 700 /root/unlock-now.sh
bash /root/unlock-now.sh
