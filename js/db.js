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

    async addPlayer({ name, position, phone }) {
      assertConfigured();
      const { data, error } = await client
        .from("players")
        .insert({ name, position, phone: phone || null })
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

    async addMatch({ match_date, match_time, competition, opponent, home_away, venue }) {
      assertConfigured();
      const { data, error } = await client
        .from("matches")
        .insert({ match_date, match_time, competition, opponent, home_away, venue })
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
      const { data, error } = await client
        .from("availability")
        .select("*")
        .eq("match_id", matchId);
      if (error) throw error;
      return data;
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
