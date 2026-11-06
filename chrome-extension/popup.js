/**
 * popup.js — Logique de l'interface Extension Chrome
 * Orchestre l'extraction DOM, l'appel à background.js, la copie dans le presse-papier
 * et l'affichage des statistiques / historiques depuis `/api/stats`.
 */

document.addEventListener("DOMContentLoaded", async () => {
  const settingsPanel = document.getElementById("settingsPanel");
  const toggleSettingsBtn = document.getElementById("toggleSettingsBtn");
  const saveSettingsBtn = document.getElementById("saveSettingsBtn");
  const apiBaseUrlInput = document.getElementById("apiBaseUrl");
  const apiTokenInput = document.getElementById("apiToken");
  const providersGrid = document.getElementById("providersGrid");
  const relayBtn = document.getElementById("relayBtn");
  const openTargetTabCheckbox = document.getElementById("openTargetTab");
  const statusMsg = document.getElementById("statusMsg");
  const summaryPreview = document.getElementById("summaryPreview");
  const historyList = document.getElementById("historyList");
  const refreshStatsBtn = document.getElementById("refreshStatsBtn");

  const PROVIDER_LABELS = {
    claude: "Claude",
    chatgpt: "ChatGPT",
    gemini: "Gemini",
    mistral: "Mistral"
  };

  let selectedTarget = "claude";

  function showStatus(text, isError = false) {
    statusMsg.textContent = text;
    statusMsg.className = "status-msg " + (isError ? "err" : "ok");
  }

  // 1. Chargement de la configuration locale
  const stored = await chrome.storage.local.get(["apiBaseUrl", "apiToken", "selectedTarget"]);
  if (stored.apiBaseUrl) apiBaseUrlInput.value = stored.apiBaseUrl;
  if (stored.apiToken) apiTokenInput.value = stored.apiToken;
  if (stored.selectedTarget && PROVIDER_LABELS[stored.selectedTarget]) {
    setSelectedProvider(stored.selectedTarget);
  }

  if (!stored.apiBaseUrl || !stored.apiToken) {
    settingsPanel.style.display = "block";
  } else {
    fetchStats();
  }

  toggleSettingsBtn.addEventListener("click", () => {
    settingsPanel.style.display = settingsPanel.style.display === "block" ? "none" : "block";
  });

  saveSettingsBtn.addEventListener("click", async () => {
    const apiBaseUrl = apiBaseUrlInput.value.trim().replace(/\/+$/, "");
    const apiToken = apiTokenInput.value.trim();
    if (!apiBaseUrl || !apiToken) {
      showStatus("Veuillez remplir l'URL du VPS et le token secret.", true);
      return;
    }
    await chrome.storage.local.set({ apiBaseUrl, apiToken });
    settingsPanel.style.display = "none";
    showStatus("Configuration enregistrée ✅");
    await fetchStats();
  });

  // 2. Sélection de l'IA cible (simple clic) ou Ouverture directe `/go/{provider}` (double-clic)
  function setSelectedProvider(provider) {
    selectedTarget = provider;
    chrome.storage.local.set({ selectedTarget: provider });
    document.querySelectorAll(".provider-card").forEach((card) => {
      card.classList.toggle("selected", card.dataset.provider === provider);
    });
    relayBtn.textContent = `Distiller & Transférer vers ${PROVIDER_LABELS[provider]} →`;
  }

  providersGrid.addEventListener("click", (e) => {
    const card = e.target.closest(".provider-card");
    if (!card) return;
    setSelectedProvider(card.dataset.provider);
  });

  providersGrid.addEventListener("dblclick", (e) => {
    const card = e.target.closest(".provider-card");
    if (!card) return;
    const provider = card.dataset.provider;
    chrome.runtime.sendMessage({ action: "OPEN_PROVIDER_TAB", provider });
  });

  refreshStatsBtn.addEventListener("click", () => fetchStats());

  // 3. Action principale : Extraction DOM -> Distillation Mistral -> Presse-papier -> Ouverture onglet
  relayBtn.addEventListener("click", async () => {
    relayBtn.disabled = true;
    summaryPreview.style.display = "none";
    showStatus("Extraction de la conversation en cours…");

    try {
      const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (!activeTab?.id) {
        throw new Error("Aucun onglet actif détecté.");
      }

      // Extraction via content.js (ou injection à la volée si l'onglet était déjà ouvert avant installation)
      let extraction = await sendExtractMessage(activeTab.id);
      if (!extraction) {
        await chrome.scripting.executeScript({
          target: { tabId: activeTab.id },
          files: ["content.js"]
        });
        extraction = await sendExtractMessage(activeTab.id);
      }

      if (!extraction || !extraction.ok || !extraction.raw_text || extraction.raw_text.length < 10) {
        throw new Error(
          "Impossible d'extraire le texte. Ouvrez une discussion ChatGPT, Gemini, Claude ou Mistral."
        );
      }

      showStatus(
        `Distillation Mistral en cours (${extraction.raw_text.length.toLocaleString("fr-FR")} caract., mode: ${extraction.mode})…`
      );

      const relayRes = await chrome.runtime.sendMessage({
        action: "RELAY_CONTEXT",
        payload: {
          raw_text: extraction.raw_text,
          source_provider: extraction.source_provider,
          target_provider: selectedTarget,
          open_tab: openTargetTabCheckbox.checked
        }
      });

      if (!relayRes?.ok) {
        throw new Error(relayRes?.error || "Échec lors de l'appel à /api/relay.");
      }

      const { summary } = relayRes.data;

      // Copie automatique dans le presse-papier
      await navigator.clipboard.writeText(summary);

      summaryPreview.textContent = summary;
      summaryPreview.style.display = "block";
      showStatus(
        `Résumé copié dans le presse-papier (${summary.length} caract.) !` +
          (openTargetTabCheckbox.checked ? ` Ouverture de ${PROVIDER_LABELS[selectedTarget]}…` : "")
      );

      await fetchStats();
    } catch (err) {
      showStatus(err.message || "Erreur inattendue", true);
    } finally {
      relayBtn.disabled = false;
    }
  });

  function sendExtractMessage(tabId) {
    return new Promise((resolve) => {
      chrome.tabs.sendMessage(tabId, { action: "EXTRACT_CONTEXT" }, (res) => {
        if (chrome.runtime.lastError) {
          resolve(null);
        } else {
          resolve(res);
        }
      });
    });
  }

  // 4. Récupération des quotas du jour et de l'historique depuis `/api/stats`
  async function fetchStats() {
    const { apiBaseUrl, apiToken } = await chrome.storage.local.get(["apiBaseUrl", "apiToken"]);
    if (!apiBaseUrl || !apiToken) return;

    try {
      const res = await fetch(`${apiBaseUrl.replace(/\/+$/, "")}/api/stats?limit=10`, {
        headers: { "X-API-Token": apiToken }
      });
      if (!res.ok) return;
      const data = await res.json();

      // Mise à jour des compteurs
      if (data.quotas_today) {
        for (const [prov, count] of Object.entries(data.quotas_today)) {
          const el = document.getElementById(`q-${prov}`);
          if (el) el.textContent = count;
        }
      }

      // Mise à jour de la liste des derniers résumés
      const relays = data.recent_relays || [];
      if (relays.length === 0) {
        historyList.innerHTML =
          '<div style="color:var(--muted);text-align:center;padding:12px;font-size:11px;">Aucun résumé enregistré.</div>';
        return;
      }

      historyList.innerHTML = "";
      relays.forEach((item) => {
        const row = document.createElement("div");
        row.className = "history-item";

        const meta = document.createElement("div");
        meta.className = "history-meta";

        const route = document.createElement("span");
        route.className = "history-route";
        route.textContent = `${item.source_provider} → ${item.target_provider}`;

        const snippet = document.createElement("span");
        snippet.className = "history-snippet";
        snippet.textContent = item.summary.replace(/\s+/g, " ").slice(0, 70);

        meta.appendChild(route);
        meta.appendChild(snippet);

        const copyBtn = document.createElement("button");
        copyBtn.className = "icon-btn";
        copyBtn.textContent = "Copier";
        copyBtn.addEventListener("click", async () => {
          await navigator.clipboard.writeText(item.summary);
          copyBtn.textContent = "✓";
          setTimeout(() => {
            copyBtn.textContent = "Copier";
          }, 1200);
        });

        row.appendChild(meta);
        row.appendChild(copyBtn);
        historyList.appendChild(row);
      });
    } catch {
      // Silencieux si hors-ligne
    }
  }
});
