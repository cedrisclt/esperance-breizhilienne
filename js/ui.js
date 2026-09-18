// Confirmation intégrée à la page, en remplacement de window.confirm().
// window.confirm()/alert() sont peu fiables dans certains navigateurs
// intégrés (WhatsApp, Messenger, Instagram...) : parfois invisibles ou
// auto-annulés, ce qui donne l'impression qu'un bouton "ne marche pas".
//
// anchorEl : élément après lequel afficher "Confirmer / Annuler"
// (le bouton cliqué lui-même est masqué pendant la confirmation).
// Résout à true (confirmé) ou false (annulé).
function confirmAction(anchorEl, message) {
  return new Promise((resolve) => {
    const wasButton = anchorEl.tagName === "BUTTON";
    if (wasButton) anchorEl.style.display = "none";

    const box = document.createElement("span");
    box.className = "inline-confirm";

    const msgSpan = document.createElement("span");
    msgSpan.className = "inline-confirm-msg";
    msgSpan.textContent = message; // texte brut : message peut contenir un nom saisi par un joueur

    const yesBtn = document.createElement("button");
    yesBtn.type = "button";
    yesBtn.className = "btn small danger";
    yesBtn.textContent = "Confirmer";

    const noBtn = document.createElement("button");
    noBtn.type = "button";
    noBtn.className = "btn secondary small";
    noBtn.textContent = "Annuler";

    box.append(msgSpan, yesBtn, noBtn);
    anchorEl.insertAdjacentElement("afterend", box);

    function cleanup(result) {
      box.remove();
      if (wasButton) anchorEl.style.display = "";
      resolve(result);
    }

    yesBtn.addEventListener("click", () => cleanup(true));
    noBtn.addEventListener("click", () => cleanup(false));
  });
}

// Message temporaire non bloquant, en remplacement de window.alert().
function showToast(message) {
  let toast = document.getElementById("__toast");
  if (!toast) {
    toast = document.createElement("div");
    toast.id = "__toast";
    toast.className = "toast";
    document.body.appendChild(toast);
  }
  toast.textContent = message;
  toast.classList.add("visible");
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => toast.classList.remove("visible"), 3200);
}
