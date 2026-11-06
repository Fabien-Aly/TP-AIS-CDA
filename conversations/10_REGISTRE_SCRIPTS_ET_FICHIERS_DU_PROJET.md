# 10. Registre et Guide Technique des Scripts et Composants du Projet

[← 09. Sous-agents Browser](09_CONV_2026-11-06_SOUS_AGENTS_TESTS_NAVIGATEUR.md) | [00. Index du Projet →](00_INDEX_ET_CHRONOLOGIE.md)

> [!NOTE]
> **Référence Technique :** Inventaire exhaustif des 12 scripts bash, du conteneur Docker FastAPI, de l'extension Chrome Manifest V3 et de la configuration Nginx.

## 🎯 Rôle de ce Document
Ce registre sert de fiche mémo technique absolue : il recense l'intégralité du code et des outils créés tout au long du cycle de vie du projet Greta, leur utilité, leurs paramètres et leur manière d'interagir.

---

## 🛠️ Vue d'Ensemble des 12 Scripts Shell (.sh)

Chaque script a été conçu pour répondre à une étape précise du déploiement, du durcissement ou de la résolution d'incident sur le VPS Ubuntu.

| Script | Date | Taille | Rôle & Fonction principale |
| :--- | :---: | :---: | :--- |
| [`install-portal.sh`](../install-portal.sh) | 04/11 | 27.1 Ko | **Script Fondateur** : Installe Docker, Nginx, Certbot SSL, configure Trilium Notes et déploie le portail d'accueil web sécurisé avec dashboard Glassmorphism. |
| [`fix-portal.sh`](../fix-portal.sh) | 04/11 | 6.3 Ko | **Correctif Rapide** : Corrige la configuration de domaine, force le HTTPS Let's Encrypt et rétablit les liaisons de reverse-proxy. |
| [`secure-portal.sh`](../secure-portal.sh) | 05/11 | 36.2 Ko | **Durcissement de Sécurité** : En-têtes HTTP stricts (CSP, HSTS), pare-feu UFW, Fail2ban anti-bruteforce, rate limiting et ébauche WebAuthn. |
| [`install-ai-hub.sh`](../install-ai-hub.sh) | 06/11 | 29.9 Ko | **Déploiement AI Hub** : Installe et configure le backend FastAPI Dockerisé, connecte l'API Mistral et prépare l'accès pour l'extension Chrome. |
| [`rollback-portal.sh`](../rollback-portal.sh) | 06/11 | 13.9 Ko | **Rollback d'Urgence** : Nettoie les règles restrictives de `secure-portal.sh`, supprime les rate-limits bloquants et revient à la configuration stable. |
| [`lock-all-with-password.sh`](../lock-all-with-password.sh) | 06/11 | 13.8 Ko | **Verrouillage Global** : Protège à la fois la racine et le sous-domaine `notes.fabienaly.com` derrière une authentification unifiée par mot de passe. |
| [`fix-login-password-only.sh`](../fix-login-password-only.sh) | 06/11 | 20.5 Ko | **Bypass Identifiant** : Simplifie la page de connexion `/login` pour ne requérir que le mot de passe, contournant les désynchronisations d'utilisateurs. |
| [`restore-original-totp.sh`](../restore-original-totp.sh) | 06/11 | 16.8 Ko | **Restauration TOTP** : Rétablit l'état fonctionnel du 4 novembre avec double facteur Google Authenticator et émission d'un nouveau QR Code. |
| [`unlock-now.sh`](../unlock-now.sh) | 06/11 | 4.3 Ko | **Déblocage Express** : Réinitialise instantanément le compteur de tentatives Nginx et retire l'adresse IP de la liste des bannis. |
| [`fix-exact-login.sh`](../fix-exact-login.sh) | 06/11 | 9.7 Ko | **Réparation Robuste** : Recrée un validateur en Python/Lua pur sans dépendance externe pour l'identifiant et mot de passe `Lulucarab664`. |
| [`reset-portal-gauth-mdp.sh`](../reset-portal-gauth-mdp.sh) | 06/11 | 22.2 Ko | **Portail v3 en 3 Écrans** : Authentification en étapes (Écran 1 : mot de passe seul → Écran 2 : saisie code TOTP Google Authenticator → Écran 3 : Dashboard). |
| [`setup-portal-ai-mistral.sh`](../setup-portal-ai-mistral.sh) | 06/11 | 41.4 Ko | **Portail Unifié Ultime** : Design signature Mistral AI (Zinc & Glow), intégration complète du hub IA, relai vers Trilium et switch de thèmes. |

---

## 📦 Fichiers du Backend Docker (`backend-docker/`)

Le backend a été conçu pour faire le pont entre l'extension de navigateur et le modèle d'intelligence artificielle :

* **[`main.py`](../backend-docker/main.py)** (17.3 Ko) :
  - Framework **FastAPI** avec documentation Swagger automatique sur `/docs`.
  - Middleware CORS configuré pour accepter les requêtes de l'extension Chrome (`chrome-extension://*`) et du domaine `fabienaly.com`.
  - Intégration du client officiel Mistral (`mistralai`) et fallback vers Ollama/vLLM.
  - Endpoints exposés :
    - `POST /v1/analyze` : analyse sémantique approfondie du texte extrait.
    - `POST /v1/summarize` : génération de synthèses concises ou détaillées.
    - `POST /v1/actions/flashcards` : transformation d'une note de cours en fiches de révision Q/A.
    - `POST /v1/chat` : session de discussion interactive avec contexte de note injecté.
* **[`docker-compose.yml`](../backend-docker/docker-compose.yml)** :
  - Définition du service `ai-backend` sur le réseau Docker interne.
  - Mapping du port `8000` vers l'hôte ou bridge interne Nginx.
  - Injection des variables d'environnement (`MISTRAL_API_KEY`, `MODEL_NAME`).
* **[`Dockerfile`](../backend-docker/Dockerfile)** :
  - Image légère basée sur `python:3.11-slim`.
  - Installation sécurisée sans cache et utilisateur non-root.
* **[`requirements.txt`](../backend-docker/requirements.txt)** :
  - `fastapi`, `uvicorn`, `pydantic`, `mistralai`, `python-dotenv`.
* **[`.env.example`](../backend-docker/.env.example)** :
  - Modèle de configuration des clés secrètes et options de l'API.

---

## 🧩 Fichiers de l'Extension Chrome (`chrome-extension/`)

L'extension permet de déclencher l'IA en un clic directement depuis l'interface web de Trilium Notes :

* **[`manifest.json`](../chrome-extension/manifest.json)** :
  - Spécification **Manifest V3**.
  - Permissions déclarées : `activeTab`, `storage`, `scripting`.
  - Configuration de l'icône, du popup et du script de fond en tant que Service Worker.
* **[`content.js`](../chrome-extension/content.js)** (4.9 Ko) :
  - Détecte automatiquement si la page active est Trilium Notes (`notes.fabienaly.com`).
  - Extrait intelligemment le contenu textuel nettoyé de la note en cours de lecture dans l'éditeur (évite les barres d'outils et menus).
  - Transmet le texte capturé à l'interface de l'extension.
* **[`background.js`](../chrome-extension/background.js)** (3.5 Ko) :
  - Service Worker assurant le relai sécurisé des messages entre le script de contenu, l'interface utilisateur et le serveur backend distant.
* **[`popup.html`](../chrome-extension/popup.html)** (9.1 Ko) & **[`popup.js`](../chrome-extension/popup.js)** (8.5 Ko) :
  - Interface graphique moderne en mode sombre avec effets visuels soignés.
  - Sélecteur de modes rapides (*Résumer*, *Expliquer*, *Corriger l'orthographe*, *Créer un QCM*).
  - Zone de chat libre permettant de poser des questions contextuelles sur la note active.
  - Rendu instantané des réponses en Markdown.

---

## 🌐 Configuration Serveur Nginx (`nginx/nginx.conf`)

* **[`nginx.conf`](../nginx/nginx.conf)** (1.9 Ko) :
  - Définition des blocs serveurs HTTP (redirection 301 vers HTTPS) et HTTPS (SSL Let's Encrypt).
  - Gestion du sous-domaine `notes.fabienaly.com` redirigé en proxy_pass vers le port Docker `8080` de Trilium Notes.
  - Gestion de la racine `fabienaly.com` servant le portail d'accueil web et les requêtes API `/api/v1/`.
  - Configuration des sessions sécurisées, en-têtes HTTP HSTS et protection contre le framing.


---

[← 09. Sous-agents Browser](09_CONV_2026-11-06_SOUS_AGENTS_TESTS_NAVIGATEUR.md) | [00. Index du Projet →](00_INDEX_ET_CHRONOLOGIE.md)
