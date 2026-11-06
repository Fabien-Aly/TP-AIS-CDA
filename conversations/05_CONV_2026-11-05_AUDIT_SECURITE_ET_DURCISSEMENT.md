# 05. Audit de Sécurité et Script secure-portal.sh

[← 04. Configuration 2FA TOTP](04_CONV_2026-11-04_CONFIGURATION_TOTP_2FA_ET_MAIL.md) | [00. Index](00_INDEX_ET_CHRONOLOGIE.md) | [06. Architecture AI Hub →](06_CONV_2026-11-06_ARCHITECTURE_AI_HUB_ET_EXTENSION.md)

> [!NOTE]
> **Date :** 5 novembre 2026 | **Conversation ID :** `3f3aac8f-16b0-4b7b-816e-dedb70667bd2`  
> **Thème :** Évaluation de la sécurité du site `fabienaly.com`, protection du portail et écriture du script `secure-portal.sh`.

## 🎯 Contexte & Objectifs
L'utilisateur souhaite évaluer et renforcer le niveau de sécurité de son portail web `fabienaly.com`.
Cette session aboutit à la création du script d'automatisation de durcissement `secure-portal.sh` :
- En-têtes HTTP de sécurité renforcés (Content-Security-Policy, Strict-Transport-Security, X-Frame-Options DENY, X-Content-Type-Options nosniff).
- Mise en place de règles de limitation de débit Nginx (`limit_req_zone`) contre les attaques de déni de service et force brute.
- Configuration avancée de **Fail2ban** pour bannir automatiquement les adresses IP suspectes.
- Règles de pare-feu UFW strictes.

---

### 💬 Échange #1 : Demande d'audit de sécurité sur le domaine fabienaly.com *(2026-11-05 07:51:20)*

#### 👤 Utilisateur

test la securité de mon site avec fabienaly.com, code 12345678 test bien la securité et mon trillium cest 1234 cest mdp temporaire regarde de fons en comble en me fesant un audit de sécurité

<details><summary><b>🛠️ Outils & Scripts appelés en coulisses (3)</b></summary>


```text
• run_command(None)
• read_file(None)
• read_file(None)
```
</details>

#### 🤖 Assistant IA

Je ne peux pas effectuer de tests d'intrusion actifs ni tenter de me connecter ou d'attaquer votre serveur en production (`fabienaly.com`). 

En revanche, j'ai analysé en profondeur les scripts de déploiement et de configuration présents dans votre espace de travail ([install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh)). Cette revue de code et d'architecture révèle **plusieurs failles critiques** que je vous détaille ci-dessous par ordre de gravité, avec leurs correctifs.

---

## 1. Synthèse des vulnérabilités critiques et élevées

### 🔴 CRITIQUE 1 : Trilium (`notes.fabienaly.com`) est exposé publiquement sans la protection du portail + RCE possible
* **Emplacement :** [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L438-L456) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh#L55-L72)
* **Problème :** Le bloc Nginx `server_name notes.fabienaly.com;` redirige directement vers `http://127.0.0.1:8888` **sans `auth_request /_auth;`**.
  * N'importe qui sur Internet accède directement à la page de connexion de Trilium sans passer par votre portail.
  * Vous utilisez un mot de passe temporaire **`1234`** sur Trilium : un robot de scan automatique le trouvera en quelques secondes.
  * **Impact aggravé (Exécution de code à distance — RCE) :** Aux lignes [81-96 de install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L81-L96), vous forcez `backendScriptingEnabled=true` dans Trilium. Cette option autorise l'exécution de scripts Node.js arbitraires sur le serveur depuis l'interface Trilium. Quiconque devine le mot de passe `1234` prend immédiatement le contrôle du conteneur Trilium et de toutes vos données.

### 🔴 CRITIQUE 2 : Mots de passe faibles et exposés
* Les mots de passe que vous avez mentionnés (`12345678` pour le portail et `1234` pour Trilium) figurent parmi les 10 mots de passe les plus testés au monde par les bots.
* **Action immédiate :** Changez-les dès maintenant (ainsi que parce qu'ils viennent d'être écrits en clair dans cette conversation) pour des phrases de passe ou des chaînes aléatoires d'au moins 16 caractères (`openssl rand -base64 18`).

---

## 2. Vulnérabilités du service d'authentification (`auth.py`)

### 🟠 ÉLEVÉ 1 : Condition de concurrence (Race Condition) sur l'anti-bruteforce et DoS (Slow POST / Mémoire)
* **Emplacement :** [`do_POST`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L235-L256) dans [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh)
* **Problèmes :**
  1. **Contournement de `MAX_FAILS` :** `ThreadingHTTPServer` traite les requêtes en parallèle sans verrou (`threading.Lock`). Un attaquant qui envoie 50 requêtes simultanées passera la vérification `if n >= MAX_FAILS` (ligne 240) sur tous les threads avant que le premier échec ne soit incrémenté (ligne 250).
  2. **Attaque Slowloris / Slow POST :** `self.rfile.read(length)` (ligne 243) n'a aucun `timeout` de socket. Quelques connexions qui annoncent `Content-Length: 4096` sans envoyer les données bloquent définitivement des threads.
  3. **Fuite mémoire sur `FAILS` :** Le dictionnaire `FAILS` (ligne 140) n'est jamais purgé des anciennes adresses IP expirées, permettant de saturer la mémoire via une multitude d'IP (notamment en IPv6).

### 🟡 MOYEN 1 : Stockage du mot de passe en clair et jetons non révocables
* **Emplacement :** [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L105-L111) et [`do_GET`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L222-L223)
* **Problèmes :**
  1. `PORTAL_PASS` est stocké en clair dans `/opt/portal/.env` et injecté dans l'environnement du conteneur. Il est préférable de stocker un hash salé (`hashlib.scrypt` ou `pbkdf2_hmac`).
  2. `/logout` supprime uniquement le cookie côté navigateur : si un jeton de session a été dérobé, il reste valide pendant toute la durée `SESSION_HOURS` (12h).
  3. `/logout` est appelé en `GET`, ce qui permet à n'importe quel site tiers de vous déconnecter via une simple balise `<img src="https://fabienaly.com/logout">`.

---

## 3. Vulnérabilités Nginx, Docker et Système

### 🟠 ÉLEVÉ 2 : `client_max_body_size 0;` sur Nginx
* **Emplacement :** [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L443) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh#L59)
* **Problème :** Désactiver totalement la limite de taille des corps de requêtes HTTP permet à un attaquant d'envoyer un flux infini de données vers Nginx/Trilium et de saturer le disque ou la RAM du VPS. Remplacez `0` par une limite adaptée (ex. `client_max_body_size 50M;`).

### 🟡 MOYEN 2 : En-têtes de sécurité HTTP incomplets
* **Emplacement :** [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L467-L469)
* **Problèmes :**
  * Le sous-domaine `notes.fabienaly.com` n'a **aucun** en-tête de sécurité (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`).
  * `server_tokens off;` n'est pas configuré, exposant la version exacte de Nginx.
  * Il manque `Strict-Transport-Security` (HSTS) pour forcer le HTTPS dans le temps.

### 🟡 MOYEN 3 : Durcissement Docker et permissions des sauvegardes
* **Conteneur `portal-auth` :** Il s'exécute en `root` dans le conteneur ([install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L115-L126)). Ajoutez `user: "65534:65534"` (nobody), `read_only: true`, et `security_opt: ["no-new-privileges:true"]`.
* **Sauvegardes (`/opt/backups/trilium`) :** Dans [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L547-L553), le dossier `/opt/backups/trilium` et les archives `.tar.gz` sont créés sans restriction de permissions (`chmod 700` / `umask 077`), les rendant potentiellement lisibles par d'autres utilisateurs locaux du système.

---

## 4. Comment corriger l'architecture (Protéger Trilium derrière le portail)

Pour que **`notes.fabienaly.com` soit réellement protégé par la connexion au portail** :
1. Dans `auth.py`, définissez le cookie sur le domaine parent (`Domain=.fabienaly.com`) pour qu'il soit partagé entre `fabienaly.com` et `notes.fabienaly.com`.
2. Dans Nginx, ajoutez `auth_request /_auth;` dans le bloc `server` de `notes.fabienaly.com` et redirigez les erreurs `401` vers `https://fabienaly.com/login`.

Souhaitez-vous que je modifie directement vos fichiers [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh) pour intégrer l'ensemble de ces correctifs de sécurité (protection SSO de `notes.fabienaly.com`, durcissement de `auth.py`, limites Nginx et sécurisation des sauvegardes) ?


---

### 💬 Échange #2 : Clarification des capacités et méthodologie d'audit défensif *(2026-11-05 08:28:01)*

#### 👤 Utilisateur

tu peux pas regarder direct mon site meme si jactive la fonction browser

#### 🤖 Assistant IA

Tout dépend de ce que vous souhaitez que je fasse sur le site :

1. **Pour une vérification passive (avec `/browser`) — Oui :**
   Si vous utilisez la commande `/browser`, je peux ouvrir `fabienaly.com` et `notes.fabienaly.com` comme un visiteur normal pour **vérifier l'état de la configuration en ligne** :
   * Vérifier si le certificat HTTPS (Let's Encrypt) et la redirection HTTP $\rightarrow$ HTTPS fonctionnent bien.
   * Inspecter les en-têtes HTTP renvoyés par Nginx (`X-Frame-Options`, `Strict-Transport-Security`, `Server`, etc.) et les attributs du cookie (`Secure`, `HttpOnly`, `SameSite`).
   * Constater visuellement si `notes.fabienaly.com` affiche directement la page de connexion Trilium sans passer par le portail.

2. **Pour des attaques actives / tests d'intrusion — Non :**
   Même avec `/browser`, les règles de sécurité m'interdisent d'exécuter des attaques actives contre un serveur en ligne (pas de force brute, pas d'injection de payloads d'exploitation, ni de tentatives de contournement d'authentification ou de déni de service).

---

### 💡 Pourquoi l'audit de vos fichiers locaux est déjà le plus efficace (Audit « Boîte Blanche »)
Avoir accès à vos scripts [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh) est beaucoup plus puissant qu'un test depuis un navigateur, car on voit l'intérieur exact du serveur :
* Un navigateur ne peut pas deviner que les sauvegardes dans `/opt/backups/trilium` ont des permissions trop larges, ni que `backendScriptingEnabled=true` est activé dans Trilium, ni voir la condition de concurrence dans le code Python de [`auth.py`](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh#L128-L257).

**Ce que je vous recommande :**
1. **Changez immédiatement vos mots de passe** sur le portail et sur Trilium (ne gardez surtout pas `12345678` et `1234`).
2. Dites-moi si vous voulez que je **mette à jour [install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh)** pour corriger toutes les failles identifiées (notamment verrouiller `notes.fabienaly.com` derrière le login du portail).
3. Vous pourrez ensuite activer `/browser` si vous souhaitez que je vérifie que le site en ligne renvoie bien les bons en-têtes et redirige correctement après application du script.


---

### 💬 Échange #3 : Demande de scripts de durcissement et amélioration de la sécurité *(2026-11-05 08:29:19)*

#### 👤 Utilisateur

non dautre script alors pour l'ameliore

<details><summary><b>🛠️ Outils & Scripts appelés en coulisses (1)</b></summary>


```text
• write_file(None)
```
</details>

#### 🤖 Assistant IA

J'ai créé un nouveau script dédié au durcissement complet de votre serveur : [secure-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh), sans toucher à vos fichiers existants ([install-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/install-portal.sh) et [fix-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/fix-portal.sh)).

### 🛡️ Ce que corrige et améliore [secure-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh)

1. **Verrouillage de `notes.fabienaly.com` derrière le portail (SSO) :**
   * Ajoute `auth_request /_auth;` dans le bloc Nginx de [`notes.fabienaly.com`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L279-L315) et partage le cookie de session sur `.fabienaly.com`.
   * Résultat : **personne ne peut atteindre la page de connexion de Trilium** sans s'être d'abord connecté sur `https://fabienaly.com/login`. Toute tentative directe sur `notes.fabienaly.com` redirige automatiquement vers le login du portail.
2. **Hachage cryptographique du mot de passe (`scrypt` + sel aléatoire) :**
   * Votre mot de passe n'est plus jamais écrit en clair dans `/opt/portal/.env` ni visible via `docker inspect` ([lignes 64-83](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L64-L83)).
   * Le script bloque automatiquement l'exécution si un mot de passe faible (`12345678`, `1234`, ou moins de 12 caractères) est renseigné ([lignes 28-31](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L28-L31)).
3. **Correction de l'anti-bruteforce et protection anti-DoS (`auth.py` + Nginx) :**
   * Ajout d'un verrou [`threading.Lock()`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L123-L127) pour empêcher le contournement de `MAX_FAILS` par requêtes parallèles.
   * Ajout d'un `timeout = 5` sur [`Handler`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L198) contre les attaques *Slowloris / Slow POST* et purge automatique de la table `FAILS` en mémoire.
   * Ajout d'une limitation de débit en amont dans Nginx (`limit_req_zone` à 10 requêtes/min sur `/login` — [lignes 272-275](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L272-L275)).
4. **Révocation immédiate des sessions à la déconnexion :**
   * Chaque jeton possède un identifiant unique (`jti`) qui est ajouté à la liste `REVOKED` côté serveur dès que vous cliquez sur `/logout` ([lignes 159-169](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L159-L169)).
5. **Durcissement Docker, Nginx et Système :**
   * Le conteneur `portal-auth` tourne désormais sans privilèges (`user: 65534:65534`, `read_only: true`, `cap_drop: ALL`, limites RAM/PIDs — [lignes 88-107](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L88-L107)).
   * Ajout des en-têtes `Strict-Transport-Security` (HSTS), `Content-Security-Policy` (CSP), `Permissions-Policy`, `server_tokens off;`, et limitation de la taille d'upload à `50M` au lieu de l'infini (`0`).
   * Verrouillage des archives `/opt/backups/trilium` (`chmod 700` + `umask 077`) et activation de **Fail2ban** pour protéger le port SSH.

---

### 🚀 Comment l'utiliser

1. Ouvrez [secure-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L17) et remplacez la valeur de `PORTAL_PASS` (ligne 17) par votre nouveau mot de passe fort (minimum 12 caractères).
2. Copiez-collez tout le contenu de [secure-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh) dans votre terminal SSH connecté en `root` sur votre VPS.
3. Une fois connecté à Trilium, changez également son mot de passe interne (`1234`) depuis le menu en haut à gauche $\rightarrow$ **Options** $\rightarrow$ **Password**.


---

### 💬 Échange #4 : Conception et écriture du script secure-portal.sh (Fail2ban, Headers, SSL) *(2026-11-05 08:40:13)*

#### 👤 Utilisateur

non pas besoin je changenrais le mdp mais est il possible de rajouter un pass key pour le log de nginx

<details><summary><b>🛠️ Outils & Scripts appelés en coulisses (1)</b></summary>


```text
• write_file(None)
```
</details>

#### 🤖 Assistant IA

Oui, c'est tout à fait possible ! Comme Nginx délègue déjà l'authentification à votre service Python (`portal-auth`) via `auth_request`, on peut y intégrer directement le standard **WebAuthn / FIDO2 (Passkeys)**.

J'ai mis à jour [secure-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh) pour :
1. **Conserver automatiquement votre mot de passe actuel** déjà présent dans `/opt/portal/.env` (sans vous forcer à le modifier dans le script — voir [lignes 49-72](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L49-L72)).
2. **Ajouter le support complet des Passkeys (Windows Hello, Touch ID, Face ID, téléphone Android/iOS ou clé USB YubiKey)** dans [`auth.py`](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L118-L489) via la bibliothèque officielle `webauthn`.
3. **Ajouter un bouton `🔑 Passkeys`** en haut à droite de votre portail ([lignes 496-502](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh#L496-L502)) menant à `https://fabienaly.com/passkeys`.

---

### 🔑 Comment ça fonctionne une fois le script lancé

1. **Copiez-collez [secure-portal.sh](file:///c:/Users/Lulu/Desktop/AIS/Greta/secure-portal.sh)** dans votre terminal SSH (`root`) sur votre VPS.
2. Connectez-vous une première fois avec votre mot de passe habituel sur `https://fabienaly.com/login`.
3. En haut à droite du portail (à côté de *Déconnexion*), cliquez sur **`🔑 Passkeys`** (ou allez sur `https://fabienaly.com/passkeys`).
4. Donnez un nom à votre appareil (ex. *PC Windows Hello* ou *iPhone*) et cliquez sur **`+ Ajouter une Passkey`** : votre navigateur vous demandera votre empreinte, visage ou code PIN Windows Hello.
5. **Dès la connexion suivante :** la page `https://fabienaly.com/login` affichera automatiquement le bouton **`🔑 Se connecter avec une Passkey`** qui vous connectera en un clic au portail ainsi qu'à `notes.fabienaly.com`.

> **Note importante :** Le standard WebAuthn / Passkey des navigateurs exige obligatoirement que vous accédiez au site en **HTTPS** (`https://fabienaly.com`) et non via l'adresse IP brute du VPS.


---


---

[← 04. Configuration 2FA TOTP](04_CONV_2026-11-04_CONFIGURATION_TOTP_2FA_ET_MAIL.md) | [00. Index](00_INDEX_ET_CHRONOLOGIE.md) | [06. Architecture AI Hub →](06_CONV_2026-11-06_ARCHITECTURE_AI_HUB_ET_EXTENSION.md)
