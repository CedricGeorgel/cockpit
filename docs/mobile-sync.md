# Cockpit, pont mobile

La PWA ne parle jamais directement au Mac. Chaque appareil (Mac mini, MacBook)
**pousse** son état ; la PWA agrège la flotte et **lit** les réglages partagés ;
la PWA **dépose** des actions, le Mac « exécutant » les **relève**. Entre les
deux : `relay.php`, un mini-script PHP posé sur ton hébergement.

**On se connecte avec Google**, sur l'app *et* sur le web. Le relais échange le
code OAuth, vérifie l'identité, et émet **son propre jeton de session**. Le
compte = l'identifiant Google. Un proche qui se connecte avec *son* Google a
*son* dossier, jamais le tien.

```
 Mac (Cockpit)            relay.php (ton hébergement)         Navigateur / PWA
 ────────────             ───────────────────────────         ────────────────
                          ?auth=start ─▶ Google ─▶ callback ─▶ #t=<jeton de session>
 POST ?f=device&d=… ────▶ data/acct/<id>/dev.<device>.json ─GET ?f=fleet─▶ agrégation
 GET/POST ?f=settings ◀─▶ data/acct/<id>/settings.json      (bloc-notes, ville, RSS…)
 GET  ?f=commands   ◀──── data/acct/<id>/commands.json  ◀─POST ?f=commands── cocher / +
```

**Le dépôt Git EST le docroot.** `index.html`, `relay.php`, `deploy.php` sont à la
racine du repo ; l'app macOS (`Sources/`, `build.sh`…) est dans le même dossier
mais masquée par `.htaccess`. Deux façons de mettre en ligne, **sans SSH** :
- **FTP** : dézippe `cockpit-deploy.zip` dans le docroot (premier déploiement).
- **Git** : `init.php` une fois, puis `deploy.php?key=…` (voir plus bas).

Guide pas à pas complet : `docs/deploy-guide.md`.

## 1. Créer l'app Google (~10 min, une fois)

[console.cloud.google.com](https://console.cloud.google.com) :

1. **Nouveau projet** « Cockpit ».
2. **API et services › Écran de consentement OAuth** : type *Externe*, renseigne
   le nom de l'app + ton e-mail. Scopes : `openid`, `email`, `profile`
   uniquement. Puis **Publier l'application** (le bouton « Publier ») : avec ces
   scopes non sensibles, aucune validation Google n'est nécessaire, c'est
   instantané. (Rester en mode *Test* ferait expirer les connexions au bout de 7
   jours.)
3. **API et services › Identifiants › Créer des identifiants › ID client OAuth**,
   type **Application Web** :
   - **URI de redirection autorisé** : `https://TON-DOMAINE/relay.php`
     (chemin nu, **sans** `?…`).
   - Créer → note l'**ID client** (`…apps.googleusercontent.com`) et le
     **secret client** (`GOCSPX-…`).

Une seule app suffit : le Mac passe par le relais, jamais directement par Google.

## 2. `config.php`

Dans le docroot, copie `config.sample.php` en **`config.php`** et colle tes
identifiants :

```php
'google_client_id'     => '....apps.googleusercontent.com',
'google_client_secret' => 'GOCSPX-....',
```

`signup_code` / `max_instances` ne concernent que l'ancienne création d'instance
par clé (rétro-compat), sans effet sur la connexion Google.

## 3. Mettre en ligne

Le docroot du sous-domaine (servi en **HTTPS**) reçoit le contenu du dépôt.
Fichiers servis : `index.html`, `relay.php`, `sw.js`, `manifest.webmanifest`,
`version.json`, `icons/`, `deploy.php`. Non versionnés mais présents :
`config.php` (étape 2), `Cockpit.dmg` (téléversé à la main), `data/` (créé au
runtime, `chmod 755`). `.htaccess` masque `.git`, `Sources/`, `*.swift`, etc.

L'URI de redirection Google doit pointer **exactement** sur
`https://TON-DOMAINE/relay.php`.

**Détail complet du déploiement Git (init.php / deploy.php / PAT) :
`docs/deploy-guide.md`.**

## 4. Vérifier

```sh
curl -sI  "https://TON-DOMAINE/"                                  # 200 → la PWA
curl -s -o /dev/null -w '%{http_code}\n' \
     "https://TON-DOMAINE/relay.php?auth=start&app=1"                 # 302 vers Google
curl -s   "https://TON-DOMAINE/data/"                             # 403 → protection OK
```

## 5. Connecter

- **iPhone / navigateur** : ouvre `https://TON-DOMAINE/`, **Se connecter avec
  Google**. De retour sur la page, tu es connecté. Puis *Partager › Ajouter à
  l'écran d'accueil*.
- **Mac mini** (et MacBook) : Cockpit › **Réglages › Tableau de bord mobile…** →
  saisis l'**adresse du relais** (`TON-DOMAINE`) → **Se connecter avec Google**.
  Sur les Macs secondaires, décoche « Cet appareil exécute les actions du
  mobile » pour éviter les doublons.

Au bout d'une minute, le tableau de bord se remplit.

### Donner accès à un proche

Il déploie sa propre copie **ou** tu partages ton URL : il clique **Se connecter
avec Google** avec *son* compte. Le relais crée un dossier séparé pour son
identifiant Google. Vos données ne se croisent jamais.

### Mises à jour

`https://TON-DOMAINE/deploy.php?key=LA_CLE` (ou ré-envoi FTP). `config.php`,
`data/`, `Cockpit.dmg` sont git-ignorés et survivent. `sw.js` est en *réseau
d'abord* : la nouvelle PWA est prise au chargement suivant.

Ménage automatique : `dev.*.json` inactif > 30 j supprimé ; compte sans appareil
et inactif > 60 j supprimé ; session Google inactive > 90 j supprimée ; `state`
OAuth > 10 min supprimé.

## Contrat de `relay.php`

### Authentification

| Requête | Effet |
|---|---|
| `GET relay.php?auth=start` (`&app=1` depuis l'app) | 302 vers Google. Cible du retour fixée par le serveur : `cockpit://auth` (app) ou le dossier de `relay.php` (PWA) |
| `GET relay.php?code=…&state=…` | callback Google : échange le code, crée la session, 302 vers `redirect#t=<jeton>&e=<email>` |
| `GET relay.php?auth=me` | `{ email, name }` (Bearer) |
| `POST relay.php?auth=logout` | révoque la session (Bearer) |

Le jeton de session (48 hex) arrive dans le **fragment** `#` (hors logs, hors
Referer). Côté serveur, seul son **SHA-256** est stocké.

### Données (Bearer obligatoire)

| Requête | Effet |
|---|---|
| `GET  relay.php?f=fleet` | agrège tous les `dev.*.json` du compte → `{ devices: [...], generatedAt }` |
| `POST relay.php?f=device&d=<deviceId>` | remplace l'état de cet appareil (corps JSON) |
| `GET  relay.php?f=settings` | réglages partagés (`{}` si rien) |
| `POST relay.php?f=settings` | remplace les réglages (corps JSON) |
| `GET  relay.php?f=commands` | file d'actions (`{}` si vide) |
| `POST relay.php?f=commands` | remplace la file (corps JSON) |

`PUT` = `POST`. Jeton via `Authorization: Bearer …` **ou** `X-Auth-Token: …`
(secours si l'hébergeur filtre `Authorization`). `Cache-Control: no-store` sur les
`GET`.

### Rétro-compat (ancienne clé)

`POST relay.php?new` (→ `{instance, token, key}`) et les routes `?f=…&i=<instance>`
avec le jeton d'instance restent acceptées, ainsi que `?f=snapshot` (GET → dernier
appareil ; POST → `dev.0eadbeef.json`). Une **clé de connexion** est le base64url
d'un JSON `{"u":"…/relay.php","i":"<instance>","t":"<token>"}`.

## Corps de `device` (Mac → PWA)

Poussé toutes les ~60 s, et ~1 s après chaque action appliquée. Dates ISO 8601.
Un appareil est identifié par `deviceId` = `SHA256(IOPlatformUUID).prefix(16)`.

```jsonc
{
  "generatedAt": "2026-09-09T08:12:00Z",
  "device": "Mac mini de Cedric",
  "deviceId": "a1b2c3d4e5f6a7b8",
  "platform": "mac",
  "appliedCommandIds": ["b1e9…", "77aa…"],
  "weather": { "place": "Strasbourg", "temp": 23, "feels": 22, "tempMax": 24,
               "tempMin": 15, "text": "Couvert", "symbol": "cloud.fill",
               "humidity": 59, "wind": 12, "precipProb": 53,
               "aqi": 25, "aqiLabel": "bon", "pollen": "armoise (faible)" },
  "agenda":  [ { "id": "…", "title": "Kiné", "start": "2026-09-09T13:00:00Z",
                 "end": "2026-09-09T14:00:00Z", "allDay": false,
                 "location": null, "dayLabel": "Aujourd'hui" } ],
  "todos":   [ { "id": "x-apple…", "title": "Loyer", "overdue": true, "due": null } ],
  "news":    [ { "id": "…", "title": "…", "link": "https://…",
                 "source": "Le Monde", "date": "2026-09-09T07:00:00Z" } ],
  "mail": {
    "accounts": [ { "name": "iCloud", "unread": 0 }, { "name": "Exchange", "unread": 2 } ],
    "otherUnread": 13,
    "items": [ { "id": "…", "from": "Équipe recrutement", "subject": "…",
                 "date": "2026-09-03T09:00:00Z", "seen": false,
                 "reason": "work", "account": "Exchange", "messageID": "<…@…>" } ]
  },
  "jobs":    [ { "company": "Iliad, Free", "stage": 1, "stageLabel": "Réponse reçue",
                 "lastSubject": "Retour sur ta candidature", "lastActivity": "2026-09-03T…",
                 "address": "rh@iliad.fr", "contactable": true } ],
  "trips":   [ { "id": "…", "title": "Strasbourg, Paris Gare de l'Est", "origin": "Strasbourg",
                 "departure": "2026-09-09T13:44:00Z", "receivedAt": null,
                 "mode": "train", "mapsURL": "maps://?daddr=gare%20Strasbourg&dirflg=r" } ],
  "parcels": [ { "id": "…", "carrier": "Colissimo", "number": "6M…FR",
                 "status": "En transit", "statusRank": 3, "merchant": "Decathlon",
                 "date": "2026-09-08T…", "trackingURL": "https://www.laposte.fr/outils/suivre-vos-envois?code=6M…FR" } ],
  "battery": {
    "mac": { "percent": 82, "charging": false, "minutesRemaining": 210,
             "cycleCount": 143, "healthPercent": 92 },
    "devices": [ { "name": "AirPods Pro", "icon": "airpodspro", "percent": 42,
                   "extra": "G 42 % · D 45 %", "seenAt": "2026-09-09T11:42:00Z" } ]
  },
  "disk": { "volumeName": "Macintosh HD", "usedBytes": 154000000000,
            "totalBytes": 245000000000, "freeBytes": 91000000000 },
  "callTime": [ { "name": "West", "timeZoneID": "America/Los_Angeles", "earliest": 8, "latest": 21 } ],
  "scratchpad": "notes libres…"
}
```

`weather` / `disk` peuvent être `null`. `battery.mac` absent sur un Mac de bureau.
`battery.devices[].seenAt` absent = lu à l'instant ; présent = dernière valeur
connue (l'appareil BT n'est plus là). `symbol` est un nom de SF Symbol (la PWA le
mappe vers son jeu d'icônes).

## Réglages partagés (`settings`)

Fusion **champ par champ, dernier qui écrit gagne** (`{ v, at }` par champ),
sauf `newsRead` fusionné par **union**. Ne jamais écraser une liste locale non
vide par une liste vide venue d'un autre appareil.

| Champ | Contenu |
|---|---|
| `scratchpad` | texte du bloc-notes |
| `weatherPlace` | ville météo |
| `newsFeeds` | URLs des flux RSS |
| `callContacts` | contacts « heure d'appel » (base64) |
| `columns` | disposition des colonnes (base64) |
| `mailKeywords` | mots-clés qui rendent un mail important |
| `newsRead` | liens d'actualités déjà ouverts (union, 300 max) |

## Corps de `commands` (PWA → Mac)

La PWA lit la file, **ajoute** son action avec un `id` unique, et la `POST` en
entier. Elle **retire** les actions dont l'`id` est dans
`appliedCommandIds`. Le Mac ignore les `id` déjà appliqués.

```jsonc
{
  "commands": [
    { "id": "b1e9…", "kind": "completeTodo",  "args": { "id": "x-apple-reminder://…" } },
    { "id": "77aa…", "kind": "addReminder",   "args": { "title": "Acheter du pain" } },
    { "id": "…",     "kind": "refreshMail" },
    { "id": "…",     "kind": "refreshParcels" }
  ]
}
```

| `kind` | `args` | Effet |
|---|---|---|
| `completeTodo` | `id` | coche le rappel EventKit |
| `addReminder` | `title` | crée un rappel, échéance aujourd'hui |
| `refreshMail` / `refreshParcels` | — | force un rafraîchissement |

Le bloc-notes et la ville météo passent maintenant par `settings` (plus par des
commandes). Seul le Mac dont « exécute les actions » est coché applique la file.

## Sécurité

- Le jeton de session donne accès en lecture **et écriture** au compte (mails,
  agenda, candidatures…). À traiter comme un mot de passe : HTTPS obligatoire,
  transmis dans le fragment `#`, jamais journalisé.
- Comptes **cloisonnés** par identifiant Google haché ; un jeton renvoie `401`
  ailleurs. Les identifiants de compte ne sont pas énumérables.
- Côté serveur : seul le **SHA-256** du jeton est stocké ; le `id_token` Google
  est validé (`aud`, `exp`, `iss`) puis jeté, aucun jeton Google n'est conservé.
- `data/.htaccess` bloque le téléchargement direct des JSON (vérif → `403`).
- Le Mac n'ouvre aucun port ; uniquement des requêtes sortantes vers `relay.php`
  et la fenêtre d'authentification système (`ASWebAuthenticationSession`).
- Révoquer : « Se déconnecter » (supprime la session), ou supprimer
  `data/sess/*` / `data/acct/<id>/` par FTP.
