# 01. Analyse et Intégration IA dans Trilium Notes

[← 00. Index du Projet](00_INDEX_ET_CHRONOLOGIE.md) | [02. Migration VPS Docker →](02_CONV_2026-11-04_MIGRATION_VPS_DOCKER_TRILIUM.md)

> [!NOTE]
> **Date :** 4 novembre 2026 | **Conversation ID :** `8d995186-a671-4569-8bcf-c4b2aced75da`  
> **Thème :** Analyse technique préliminaire pour connecter Trilium Notes (actuellement en local sur PC) à un modèle de langage (IA locale ou hébergée) pour analyser, corriger et résumer les notes.

## 🎯 Contexte & Objectifs
L'utilisateur dispose d'une instance **Trilium Notes** sur son PC local et souhaite exploiter l'intelligence artificielle pour enrichir ses prises de notes (correction, reformulation, génération de résumés, analyse de contenu).

Cet échange initial pose les bases techniques de la solution :
- Évaluation des approches : modèle local (Ollama / vLLM / Mistral 7B) vs API distante.
- Intégration via l'API REST de Trilium Notes ou via des scripts front-end Trilium.
- Élaboration de la stratégie de migration de la base de données SQLite de Trilium vers un serveur VPS distant sécurisé.

---

### 💬 Échange #1 : Cadrage : intégration d'IA locale dans Trilium Notes *(2026-11-04 09:52:05)*

#### 👤 Utilisateur

jai un trillium notes et jaimerais utiliser de l'ia pour pouvoir anlayser corriger mes notes

#### 🤖 Assistant IA

C'est tout à fait faisable et particulièrement adapté à **Trilium Notes**, car l'application dispose d'un **moteur de scripts JavaScript natif très puissant** et d'une **API REST (ETAPI)**.

Voici un tour d'horizon des solutions possibles, du choix du modèle à la mise en place concrète.

---

### 1. Le choix de l'IA : Local vs Cloud

Puisque Trilium sert souvent de "second cerveau" avec des notes personnelles, la question de la confidentialité est cruciale :

* **Option 100% Locale & Privée (Recommandée) : [Ollama](https://ollama.ai/)**
  * Vous faites tourner un modèle (ex. *Mistral*, *Llama 3*, *Qwen 2.5*) directement sur votre machine.
  * Vos notes ne quittent jamais votre ordinateur, c'est gratuit et illimité.
  * Ollama expose une API REST locale sur `http://localhost:11434/api/generate`.
* **Option Cloud (Puissance & Rapidité) : API Gemini, OpenAI ou Claude**
  * Modèles plus puissants, aucun besoin de carte graphique dédiée.
  * Nécessite une clé d'API et l'envoi de vos notes sur les serveurs du fournisseur.

---

### 2. Deux façons d'intégrer l'IA dans Trilium

#### Approche A : Le bouton interactif dans Trilium (Script JS natif)
C'est la méthode la plus fluide au quotidien :
1. Vous êtes sur une note.
2. Vous cliquez sur un bouton dans la barre d'outils (ou tapez un raccourci clavier).
3. Une fenêtre modale ou un panneau latéral vous propose les choix : *« Corriger l'orthographe »*, *« Résumer »*, *« Extraire les actions à faire »*, ou *« Améliorer le style »*.
4. Le résultat s'affiche ou est inséré soit dans la note courante, soit dans une sous-note dédiée (ex. `Analyse IA`).

#### Approche B : L'agent de traitement de fond (Script Python externe via ETAPI)
Trilium propose une API externe appelée **ETAPI** :
1. Vous ajoutez un label `#a-analyser` ou `#corriger` à une note.
2. Un petit script Python s'exécute périodiquement (ou à la demande), récupère les notes marquées, appelle l'IA, applique les corrections ou crée une sous-note d'analyse, puis retire le label.

---

### 3. Exemple concret : Ajouter un script d'action dans Trilium

Dans Trilium, vous pouvez créer un script JS Frontend qui ajoute une action sur la note active :

1. **Créer une note de script** dans Trilium :
   * Type de note : **JS frontend script**
   * Ajoutez-lui le label : `#run=frontendStartup`
2. **Principe du code du script** :
   ```javascript
   class AIService {
       async correctActiveNote() {
           // 1. Récupérer la note active
           const activeNote = api.getActiveContextNote();
           if (!activeNote) return;

           const content = await api.runOnServer(async (noteId) => {
               const note = api.getNote(noteId);
               return note ? note.getContent() : '';
           }, [activeNote.noteId]);

           api.showMessage("Analyse IA en cours...");

           // 2. Appel à l'IA (Exemple avec Ollama en local)
           try {
               const response = await fetch("http://localhost:11434/api/generate", {
                   method: "POST",
                   headers: { "Content-Type": "application/json" },
                   body: JSON.stringify({
                       model: "mistral",
                       prompt: `Corrige et améliore le texte suivant en conservant le sens et le formatage :\n\n${content}`,
                       stream: false
                   })
               });
               
               const data = await response.json();
               const correctedText = data.response;

               // 3. Créer une sous-note avec le résultat (ou proposer de remplacer)
               await api.runOnServer(async ({ parentId, resultText }) => {
                   api.createTextNote(parentId, "Correction IA", resultText);
               }, { parentId: activeNote.noteId, resultText: correctedText });

               api.showMessage("Correction créée en sous-note !");
           } catch (err) {
               api.showError("Erreur lors de l'appel IA : " + err.message);
           }
       }
   }

   // Ajout d'une commande / raccourci dans Trilium
   api.addGlobalShortcut("Ctrl+Alt+A", () => new AIService().correctActiveNote());
   ```

---

### Pour aller plus loin ensemble

Afin d'adapter la solution exacte à votre configuration :
1. **Où tourne votre Trilium ?** Est-ce l'application de bureau (Desktop) sur votre PC, ou une instance serveur (Docker / VPS) ?
2. **Quel type d'IA préférez-vous ?**
   * Une IA **locale et confidentielle** (ex: Ollama) ?
   * Une **API Cloud** (Gemini, OpenAI, etc.) ?
3. **Quel comportement souhaitez-vous ?**
   * Remplacer directement le texte de la note courante ?
   * Créer une sous-note avec l'analyse / correction ?
   * Une boîte de dialogue avec prévisualisation avant validation ?


---

### 💬 Échange #2 : Stratégie de migration VPS et génération de prompts dédiés *(2026-11-04 09:59:21)*

#### 👤 Utilisateur

Trillium sur mon pc mais jaimerais migrer sur un vps et ensuite l'avoir en serveur , avec un  docker sur un vps debian , pour l'ia de l'api cloud jai chatgptgo et google ai pro. dabord une sous note pour ensuite et une boite de dialogue ou un ide pour voir les changement proposé et donc accepter ou requalifier . jaimerais par la suite prendre un abo claude ou autre pour un max de 25 de credit par mois pour les rajouter dans trillium ou dans mon pc avec un agent ia sur mon pc car jaimerais quil bouge dans mon pc et dans mon navigateur donc dis moi deux prompt pour la prochaine instance pour dire mes contraites ce que jai besoins

#### 🤖 Assistant IA

Voici deux prompts précis et structurés, prêts à être copiés-collés dans votre prochaine session ou instance IA pour démarrer chaque étape sans repartir de zéro.

---

### Prompt 1 : Migration Trilium sur VPS Docker + Script IA de correction avec diff/sous-note

> **À utiliser pour :** Mettre en place votre Trilium en ligne sécurisé et le script IA d'analyse/correction avec boîte de dialogue interactive.

```text
Contexte et projet :
J'utilise actuellement Trilium Notes en local sur mon PC (Windows) et je souhaite le migrer vers un VPS Debian sous Docker, puis y intégrer un module IA d'analyse et de correction de notes.

Mes contraintes et ressources :
1. Hébergement : VPS Debian avec Docker / Docker Compose et un reverse-proxy avec certificat SSL (ex. Caddy ou Nginx Proxy Manager).
2. Migration : Sauvegarder ma base de données Trilium locale existante (trilium-data) et la restaurer proprement sur le conteneur Docker du VPS sans perte de données.
3. IA & API : Utilisation des API Cloud (Google Gemini API ou OpenAI ChatGPT via clé API).
4. Fonctionnalités souhaitées pour les notes :
   - Analyser et corriger le contenu de la note active.
   - Créer une sous-note automatique pour conserver l'historique de l'analyse.
   - Afficher une boîte de dialogue (modale dans Trilium) montrant un comparatif (diff / avant-après) des modifications proposées, avec possibilité d'accepter (remplacer la note), de rejeter ou d'ajuster le prompt.

Ce que tu dois faire :
1. Me donner le docker-compose.yml complet pour Trilium Notes sur Debian (avec persistance des données et configuration des ports).
2. M'expliquer pas à pas la procédure de sauvegarde de mon Trilium PC et de restauration sur le VPS.
3. Rédiger le script Trilium (JS Frontend / Backend) intégrant l'appel à l'API (Gemini/OpenAI) avec l'interface modale de comparaison (diff) et la création de la sous-note.
```

---

### Prompt 2 : Configuration de l'Agent IA sur votre PC (OS + Navigateur + Budget 25 €/mois)

> **À utiliser pour :** Déployer un agent capable d'agir sur votre machine, manipuler vos fichiers, piloter votre navigateur et communiquer avec votre Trilium via API.

```text
Contexte et projet :
Je souhaite installer et configurer un agent IA autonome sur mon PC. Cet agent doit être capable d'interagir directement avec mon système d'exploitation (manipulation de fichiers, scripts) et de naviguer sur le web (contrôle de navigateur / browser automation). Il devra également pouvoir communiquer avec mon instance Trilium Notes via son API (ETAPI).

Mes contraintes et budget :
1. Environnement : PC sous Windows.
2. Budget IA : Environ 25 € / mois maximum (soit via un abonnement Claude Pro / ChatGPT Plus, soit via des crédits API pay-as-you-go type Anthropic API / Gemini Flash / OpenAI).
3. Cas d'usage :
   - Déplacement et exécution de tâches dans mon environnement local (PC).
   - Automatisation et navigation web (recherche, extraction, interaction).
   - Synchronisation et envoi de résumés/actions vers mon serveur Trilium Notes.

Ce que tu dois faire :
1. Me recommander la meilleure architecture d'agent open-source actuelle adaptée à ce budget (ex. Open Interpreter, Browser-Use, CrewAI, ou outils MCP Anthropic).
2. M'expliquer la stratégie de modèle la plus rentable pour tenir dans les 25 €/mois (ex. utiliser un modèle léger/rapide comme Gemini Flash ou Claude Haiku pour la navigation, et un modèle plus poussé uniquement pour l'analyse complexe).
3. Me donner le guide d'installation étape par étape sur mon PC, avec la configuration d'accès au navigateur et la connexion à l'ETAPI de Trilium Notes.
```

---

### Résumé des priorités recommandées

1. **Étape 1 :** Lancez d'abord le **Prompt 1** pour avoir votre serveur Trilium fonctionnel et synchronisé.
2. **Étape 2 :** Pour l'agent PC (Prompt 2), avec un budget de 25 €/mois, l'accès **API Pay-as-you-go** (notamment avec *Claude 3.5 Haiku* ou *Gemini 1.5/2.0 Flash*) sera beaucoup plus économique et flexible qu'un simple abonnement web classique, car les outils d'automatisation d'ordinateur (comme *Browser-Use* ou *Open-Interpreter*) consomment des tokens via API.


---


---

[← 00. Index du Projet](00_INDEX_ET_CHRONOLOGIE.md) | [02. Migration VPS Docker →](02_CONV_2026-11-04_MIGRATION_VPS_DOCKER_TRILIUM.md)
