/**
 * background.js — Service Worker (Manifest V3)
 * Gère l'appel au Backend Docker (/api/relay), l'ouverture de la route /go/{provider}
 * et l'injection automatique du contexte distillé dans le nouvel onglet une fois chargé.
 */

const PENDING_INJECTIONS = new Map();

async function getStoredConfig() {
  const data = await chrome.storage.local.get(["apiBaseUrl", "apiToken"]);
  return {
    apiBaseUrl: (data.apiBaseUrl || "").replace(/\/+$/, ""),
    apiToken: (data.apiToken || "").trim()
  };
}

/**
 * Écoute la fin du chargement des onglets pour injecter le résumé en attente
 * après la redirection HTTP 302 de `/go/{provider}` vers l'IA cible.
 */
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status !== "complete" || !PENDING_INJECTIONS.has(tabId)) {
    return;
  }
  const url = tab.url || "";
  const isTargetAi =
    url.includes("chatgpt.com") ||
    url.includes("gemini.google.com") ||
    url.includes("claude.ai") ||
    url.includes("chat.mistral.ai");

  if (!isTargetAi) return;

  const promptText = PENDING_INJECTIONS.get(tabId);
  PENDING_INJECTIONS.delete(tabId);

  setTimeout(() => {
    chrome.tabs.sendMessage(tabId, { action: "INJECT_PROMPT", prompt: promptText }, () => {
      // Ignore lastError si l'utilisateur a déjà collé manuellement via Ctrl+V
      void chrome.runtime.lastError;
    });
  }, 900);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.action === "RELAY_CONTEXT") {
    handleRelayRequest(message.payload)
      .then((res) => sendResponse({ ok: true, data: res }))
      .catch((err) => sendResponse({ ok: false, error: err.message || "Erreur réseau" }));
    return true;
  }

  if (message?.action === "OPEN_PROVIDER_TAB") {
    openProviderWithOptionalPrompt(message.provider, message.prompt)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  return false;
});

async function handleRelayRequest({ raw_text, source_provider, target_provider, open_tab }) {
  const { apiBaseUrl, apiToken } = await getStoredConfig();
  if (!apiBaseUrl || !apiToken) {
    throw new Error("Configurez l'URL du VPS et le X-API-Token dans ⚙️ Config.");
  }

  const response = await fetch(`${apiBaseUrl}/api/relay`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Token": apiToken
    },
    body: JSON.stringify({
      raw_text,
      source_provider,
      target_provider
    })
  });

  if (!response.ok) {
    let detail = `Erreur HTTP ${response.status}`;
    try {
      const errJson = await response.json();
      if (errJson.detail) detail = errJson.detail;
    } catch {
      // ignore
    }
    throw new Error(detail);
  }

  const data = await response.json();

  if (open_tab) {
    await openProviderWithOptionalPrompt(target_provider, data.summary);
  }

  return data;
}

async function openProviderWithOptionalPrompt(provider, promptText = "") {
  const { apiBaseUrl } = await getStoredConfig();
  if (!apiBaseUrl) {
    throw new Error("Configurez d'abord l'URL du Backend dans ⚙️ Config.");
  }

  const redirectUrl = `${apiBaseUrl}/go/${encodeURIComponent(provider)}`;
  const createdTab = await chrome.tabs.create({ url: redirectUrl, active: true });

  if (promptText && createdTab?.id) {
    PENDING_INJECTIONS.set(createdTab.id, promptText);
  }
}
