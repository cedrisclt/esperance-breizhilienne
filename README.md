# Espérance Breizhilienne — Foot à 7

Page publique de l'équipe **Espérance Breizhilienne**, engagée en Football à 7 au sein de la FSGT Île-de-France (Comité 75).

🔗 Site FSGT officiel : https://www.footfsgtidf.org
🔗 Page en ligne : https://cedrisclt.github.io/esperance-breizhilienne/

## Contenu

- **index.html** — fiche équipe, prochain match, calendrier, contacts (public, en lecture seule)
- **equipe.html** — gestion de l'effectif (joueurs, postes)
- **matchs.html** — gestion des matchs (ajout manuel, en plus de la synchro auto FSGT)
- **disponibilites.html** — chaque joueur indique sa disponibilité par match, via son nom
- **compo.html** — construction des compositions (plusieurs compos possibles par match, formation + placement par poste sur un terrain)

Ces quatre dernières pages sont une petite app connectée à une base de données
[Supabase](https://supabase.com) (gratuite), partagée par tous les joueurs qui ont le lien —
il n'y a **pas d'authentification** : quiconque a le lien peut lire et modifier les données. Adapté à un
usage d'équipe amateur entre personnes de confiance, pas à un usage public sensible.

## Mise en route de l'app (joueurs/dispos/compos)

1. Crée un compte gratuit sur [supabase.com](https://supabase.com) et un nouveau projet.
2. Dans le projet, va dans **SQL Editor > New query**, colle le contenu de
   [`supabase/schema.sql`](supabase/schema.sql) et exécute-le (crée les tables + règles d'accès).
3. Va dans **Project Settings > API**, récupère l'**URL du projet** et la clé **anon public**.
4. Édite [`js/config.js`](js/config.js) et remplace les deux valeurs placeholder par les tiennes.
5. Commit et push — les pages sont alors connectées à ta base.

La clé "anon" est faite pour être publique côté client (Supabase protège les données via les règles
RLS définies dans `schema.sql`), donc pas de souci à la committer.

## Mise à jour du calendrier

`scrape_calendar.py` re-scrape le calendrier officiel FSGT chaque jour (via un LaunchAgent macOS local,
voir `update_and_push.sh`) : il met à jour `index.html`, et si Supabase est configuré, synchronise aussi
automatiquement les matchs dans la table `matches` (les matchs amicaux se gèrent en plus via
`matchs.html`).
