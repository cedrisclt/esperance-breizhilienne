// Formations standard en foot à 7 (1 gardien + 6 joueurs de champ).
// Chaque formation est décrite par [défenseurs, milieux, attaquants].

const FORMATIONS = {
  "2-3-1": [2, 3, 1],
  "3-2-1": [3, 2, 1],
  "2-2-2": [2, 2, 2],
  "3-1-2": [3, 1, 2],
  "1-3-2": [1, 3, 2],
};

// Génère les emplacements (slot_key, label, position x/y en % sur le terrain)
// pour une formation donnée. y=95 proche de son propre but, y=5 proche du but adverse.
function getFormationSlots(formation) {
  const [defCount, midCount, attCount] = FORMATIONS[formation] || FORMATIONS["2-3-1"];

  const rows = [
    { key: "GK", label: "Gardien", count: 1, y: 92 },
    { key: "DEF", label: "Défenseur", count: defCount, y: 68 },
    { key: "MID", label: "Milieu", count: midCount, y: 42 },
    { key: "ATT", label: "Attaquant", count: attCount, y: 16 },
  ];

  const slots = [];
  for (const row of rows) {
    for (let i = 0; i < row.count; i++) {
      const x = (100 / (row.count + 1)) * (i + 1);
      const key = row.count === 1 ? row.key : `${row.key}${i + 1}`;
      slots.push({
        key,
        label: row.count === 1 ? row.label : `${row.label} ${i + 1}`,
        suggestedPosition: row.key, // GK / DEF / MID / ATT, pour suggérer les joueurs au bon poste
        x,
        y: row.y,
      });
    }
  }
  return slots;
}

const POSITION_LABELS = {
  GK: "Gardien",
  DEF: "Défenseur",
  MID: "Milieu",
  ATT: "Attaquant",
};
