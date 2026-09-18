// Client Supabase partagé + fonctions d'accès aux données.
// Nécessite js/config.js et le script CDN @supabase/supabase-js chargés avant.

const db = (() => {
  const configured =
    window.SUPABASE_CONFIG &&
    window.SUPABASE_CONFIG.url &&
    !window.SUPABASE_CONFIG.url.includes("YOUR-PROJECT");

  const client = configured
    ? window.supabase.createClient(
        window.SUPABASE_CONFIG.url,
        window.SUPABASE_CONFIG.anonKey
      )
    : null;

  function assertConfigured() {
    if (!client) {
      throw new Error(
        "Supabase n'est pas configuré : renseigne js/config.js avec ton URL et ta clé anon."
      );
    }
  }

  return {
    isConfigured: () => configured,

    async listPlayers({ activeOnly = true } = {}) {
      assertConfigured();
      let q = client.from("players").select("*").order("name");
      if (activeOnly) q = q.eq("active", true);
      const { data, error } = await q;
      if (error) throw error;
      return data;
    },

    async addPlayer({ name, positions, phone, notes, priority }) {
      assertConfigured();
      const { data, error } = await client
        .from("players")
        .insert({
          name,
          positions,
          phone: phone || null,
          notes: notes || null,
          priority: !!priority,
        })
        .select()
        .single();
      if (error) throw error;
      return data;
    },

    async updatePlayer(id, patch) {
      assertConfigured();
      const { data, error } = await client
        .from("players")
        .update(patch)
        .eq("id", id)
        .select()
        .single();
      if (error) throw error;
      return data;
    },

    async deactivatePlayer(id) {
      return this.updatePlayer(id, { active: false });
    },

    async listMatches({ upcomingOnly = false } = {}) {
      assertConfigured();
      let q = client.from("matches").select("*").order("match_date");
      if (upcomingOnly) {
        const today = new Date().toISOString().slice(0, 10);
        q = q.gte("match_date", today);
      }
      const { data, error } = await q;
      if (error) throw error;
      return data;
    },

    async addMatch({ match_date, match_time, competition, opponent, home_away, venue, drop_at, capacity }) {
      assertConfigured();
      const { data, error } = await client
        .from("matches")
        .insert({
          match_date, match_time, competition, opponent, home_away, venue,
          drop_at: drop_at || null,
          capacity: capacity || 9,
        })
        .select()
        .single();
      if (error) throw error;
      return data;
    },

    async updateMatch(id, patch) {
      assertConfigured();
      const { data, error } = await client
        .from("matches")
        .update(patch)
        .eq("id", id)
        .select()
        .single();
      if (error) throw error;
      return data;
    },

    async deleteMatch(id) {
      assertConfigured();
      const { error } = await client.from("matches").delete().eq("id", id);
      if (error) throw error;
    },

    async getAvailabilityForMatch(matchId) {
      assertConfigured();
      await this.ensurePriorityAvailability(matchId);
      const { data, error } = await client
        .from("availability")
        .select("*")
        .eq("match_id", matchId);
      if (error) throw error;
      return data;
    },

    // Les joueurs "prioritaires" (ex. les organisateurs) sont marqués
    // disponibles automatiquement dès qu'un match est consulté pour la
    // première fois — sans écraser un choix déjà fait (désistement inclus).
    async ensurePriorityAvailability(matchId) {
      assertConfigured();
      const [{ data: priorityPlayers, error: pErr }, { data: existing, error: eErr }] = await Promise.all([
        client.from("players").select("id").eq("priority", true).eq("active", true),
        client.from("availability").select("player_id").eq("match_id", matchId),
      ]);
      if (pErr) throw pErr;
      if (eErr) throw eErr;
      const existingIds = new Set(existing.map((a) => a.player_id));
      const missing = priorityPlayers.filter((p) => !existingIds.has(p.id));
      if (missing.length === 0) return;
      const { error } = await client
        .from("availability")
        .insert(missing.map((p) => ({ match_id: matchId, player_id: p.id, status: "disponible" })));
      if (error) throw error;
    },

    async getAvailabilityForPlayer(playerId) {
      assertConfigured();
      const { data, error } = await client
        .from("availability")
        .select("*")
        .eq("player_id", playerId);
      if (error) throw error;
      return data;
    },

    async setAvailability({ matchId, playerId, status }) {
      assertConfigured();
      const { data, error } = await client
        .from("availability")
        .upsert(
          {
            match_id: matchId,
            player_id: playerId,
            status,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "match_id,player_id" }
        )
        .select()
        .single();
      if (error) throw error;
      return data;
    },

    async listAllAvailability() {
      assertConfigured();
      const { data, error } = await client.from("availability").select("*");
      if (error) throw error;
      return data;
    },

    // "Drop" : réclame une place. Confirmé si une place reste dans la
    // capacité du match, sinon mis en liste d'attente. Meilleur effort
    // côté client (pas de verrou atomique) — suffisant pour une équipe
    // amateur, un léger dépassement ponctuel n'est pas dramatique.
    async claimSpot({ matchId, playerId, capacity }) {
      assertConfigured();
      const current = await this.getAvailabilityForMatch(matchId);
      const confirmedCount = current.filter(
        (a) => a.status === "disponible" && a.player_id !== playerId
      ).length;
      const status = confirmedCount < capacity ? "disponible" : "liste_attente";
      await this.setAvailability({ matchId, playerId, status });
      return status;
    },

    // Se retire (indisponible). Si le joueur libère une place confirmée,
    // le premier de la liste d'attente est automatiquement promu.
    async withdraw({ matchId, playerId }) {
      assertConfigured();
      const current = await this.getAvailabilityForMatch(matchId);
      const mine = current.find((a) => a.player_id === playerId);
      const wasConfirmed = mine && mine.status === "disponible";
      await this.setAvailability({ matchId, playerId, status: "indisponible" });

      if (wasConfirmed) {
        const waitlist = current
          .filter((a) => a.status === "liste_attente" && a.player_id !== playerId)
          .sort((a, b) => new Date(a.updated_at) - new Date(b.updated_at));
        if (waitlist.length > 0) {
          await this.setAvailability({
            matchId,
            playerId: waitlist[0].player_id,
            status: "disponible",
          });
        }
      }
    },

    async listLineupsForMatch(matchId) {
      assertConfigured();
      const { data, error } = await client
        .from("lineups")
        .select("*, lineup_slots(*)")
        .eq("match_id", matchId)
        .order("created_at");
      if (error) throw error;
      return data;
    },

    async createLineup({ matchId, name, formation }) {
      assertConfigured();
      const { data, error } = await client
        .from("lineups")
        .insert({ match_id: matchId, name, formation })
        .select()
        .single();
      if (error) throw error;
      return data;
    },

    async deleteLineup(id) {
      assertConfigured();
      const { error } = await client.from("lineups").delete().eq("id", id);
      if (error) throw error;
    },

    async updateLineupFormation(id, formation) {
      assertConfigured();
      // Changing formation invalidates existing slot keys, so slots are cleared first.
      const { error: delErr } = await client.from("lineup_slots").delete().eq("lineup_id", id);
      if (delErr) throw delErr;
      const { error } = await client.from("lineups").update({ formation }).eq("id", id);
      if (error) throw error;
    },

    async setLineupSlot({ lineupId, slotKey, playerId }) {
      assertConfigured();
      const { data, error } = await client
        .from("lineup_slots")
        .upsert(
          { lineup_id: lineupId, slot_key: slotKey, player_id: playerId },
          { onConflict: "lineup_id,slot_key" }
        )
        .select()
        .single();
      if (error) throw error;
      return data;
    },
  };
})();
