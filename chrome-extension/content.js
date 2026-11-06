/**
 * content.js — Extraction DOM propre & Pré-remplissage intelligent
 * Cibles : chatgpt.com, gemini.google.com, claude.ai, chat.mistral.ai
 */

(() => {
  "use strict";

  const NOISE_SELECTORS = [
    "nav",
    "header",
    "footer",
    "aside",
    "script",
    "style",
    "noscript",
    "svg",
    "button",
    "form",
    "[role='navigation']",
    "[role='banner']",
    "[aria-hidden='true']"
  ].join(",");

  function detectProviderFromHost(hostname) {
    if (hostname.includes("chatgpt.com")) return "chatgpt";
    if (hostname.includes("gemini.google.com")) return "gemini";
    if (hostname.includes("claude.ai")) return "claude";
    if (hostname.includes("mistral.ai")) return "mistral";
    return "unknown";
  }

  /**
   * Extrait soit la sélection active de l'utilisateur, soit le conteneur principal
   * de la conversation en supprimant les menus, boutons et scripts parasites.
   */
  function extractCleanConversation() {
    const provider = detectProviderFromHost(window.location.hostname);
    const selection = window.getSelection ? window.getSelection().toString().trim() : "";

    if (selection && selection.length >= 15) {
      return {
        mode: "selection",
        source_provider: provider,
        raw_text: selection
      };
    }

    // Sélecteurs spécifiques par plateforme avec repli sur <main> puis <body>
    const rootCandidate =
      document.querySelector("main") ||
      document.querySelector("[ role='main' ]") ||
      document.querySelector("chat-window") ||
      document.body;

    const clone = rootCandidate.cloneNode(true);
    clone.querySelectorAll(NOISE_SELECTORS).forEach((el) => el.remove());

    // Normalisation des sauts de ligne multiples
    const rawText = (clone.innerText || clone.textContent || "")
      .replace(/\r\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();

    return {
      mode: "full_page",
      source_provider: provider,
      raw_text: rawText
    };
  }

  /**
   * Pré-remplit la zone de saisie de l'IA cible (compatible ProseMirror / Quill / React textarea).
   */
  function injectPromptIntoEditor(promptText) {
    const editorSelectors = [
      "#prompt-textarea", // ChatGPT (ProseMirror div ou textarea)
      "div.ProseMirror[contenteditable='true']", // Claude & ChatGPT
      "rich-textarea div.ql-editor[contenteditable='true']", // Gemini
      "div[contenteditable='true'][role='textbox']", // Générique
      "textarea" // Mistral / Fallback
    ];

    let targetEl = null;
    for (const sel of editorSelectors) {
      const candidate = document.querySelector(sel);
      if (candidate && candidate.offsetParent !== null) {
        targetEl = candidate;
        break;
      }
    }

    if (!targetEl) {
      return { injected: false, reason: "Champ de saisie introuvable" };
    }

    targetEl.focus();

    if (targetEl.tagName === "TEXTAREA" || targetEl.tagName === "INPUT") {
      const nativeSetter = Object.getOwnPropertyDescriptor(
        window.HTMLTextAreaElement.prototype,
        "value"
      )?.set;
      if (nativeSetter) {
        nativeSetter.call(targetEl, promptText);
      } else {
        targetEl.value = promptText;
      }
      targetEl.dispatchEvent(new Event("input", { bubbles: true }));
      targetEl.dispatchEvent(new Event("change", { bubbles: true }));
      return { injected: true };
    }

    // Éditeur contenteditable (ProseMirror / Quill)
    try {
      document.execCommand("selectAll", false, null);
      const ok = document.execCommand("insertText", false, promptText);
      if (!ok) {
        targetEl.textContent = promptText;
        targetEl.dispatchEvent(
          new InputEvent("input", { bubbles: true, inputType: "insertText", data: promptText })
        );
      }
      return { injected: true };
    } catch (err) {
      targetEl.textContent = promptText;
      targetEl.dispatchEvent(new Event("input", { bubbles: true }));
      return { injected: true };
    }
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.action === "EXTRACT_CONTEXT") {
      try {
        const result = extractCleanConversation();
        sendResponse({ ok: true, ...result });
      } catch (err) {
        sendResponse({ ok: false, error: err.message || "Erreur d'extraction DOM" });
      }
      return true;
    }

    if (message?.action === "INJECT_PROMPT" && typeof message.prompt === "string") {
      // Attente progressive que le DOM SPA (React/ProseMirror) monte l'éditeur
      let attempts = 0;
      const maxAttempts = 15;
      const timer = setInterval(() => {
        attempts += 1;
        const res = injectPromptIntoEditor(message.prompt);
        if (res.injected || attempts >= maxAttempts) {
          clearInterval(timer);
          sendResponse(res);
        }
      }, 400);
      return true;
    }
    return false;
  });
})();
