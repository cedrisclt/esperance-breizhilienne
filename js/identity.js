// Identité partagée entre toutes les pages : choisie une fois dans le bandeau
// d'en-tête (#identityBar), mémorisée en localStorage, réutilisée partout où
// on a besoin de savoir "qui est-ce qui regarde cette page".
const Identity = (() => {
  const STORAGE_KEY = "eb_player_id";
  let players = [];

  function getPlayerId() {
    return localStorage.getItem(STORAGE_KEY) || "";
  }

  function getPlayer() {
    return players.find((p) => p.id === getPlayerId()) || null;
  }

  function setPlayerId(id) {
    if (id) localStorage.setItem(STORAGE_KEY, id);
    else localStorage.removeItem(STORAGE_KEY);
    window.dispatchEvent(new CustomEvent("eb:identity-changed", { detail: { playerId: id } }));
  }

  function render() {
    const bar = document.getElementById("identityBar");
    if (!bar) return;
    const current = getPlayerId();
    bar.innerHTML = "";

    const label = document.createElement("span");
    label.className = "identity-label";
    label.textContent = "Tu es";
    bar.appendChild(label);

    const select = document.createElement("select");
    select.autocomplete = "off";
    select.setAttribute("aria-label", "Choisir qui tu es");

    const emptyOpt = document.createElement("option");
    emptyOpt.value = "";
    emptyOpt.textContent = "— Choisir —";
    select.appendChild(emptyOpt);

    for (const p of players) {
      const opt = document.createElement("option");
      opt.value = p.id;
      opt.textContent = p.name;
      if (p.id === current) opt.selected = true;
      select.appendChild(opt);
    }

    select.addEventListener("change", () => setPlayerId(select.value));
    bar.appendChild(select);
  }

  async function init() {
    if (typeof db === "undefined" || !db.isConfigured()) return;
    try {
      players = await db.listPlayers();
    } catch (e) {
      return;
    }
    render();
  }

  init();

  return { getPlayerId, getPlayer, setPlayerId };
})();
