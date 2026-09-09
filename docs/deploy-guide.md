# Déployer Cockpit — guide pas à pas

Objectif : le site `dashboard.caadesign.fr` est un **clone Git** du dépôt privé.
Une fois posé, chaque mise à jour = ouvrir une URL. Pas de SSH, pas de webhook.

Tu n'as besoin que de : un compte GitHub, l'accès FTP OVH, ~20 min.

---

## Partie A — GitHub (depuis le MacBook)

### A1. Créer le dépôt distant

1. github.com → bouton **+** en haut à droite → **New repository**.
2. Nom : `cockpit`. Visibilité : **Private**. **Ne coche rien** (pas de README).
3. **Create repository**. Laisse la page ouverte, tu y reviens en A3.

### A2. Créer un token (fine-grained PAT)

1. github.com → ton avatar → **Settings** → tout en bas **Developer settings**
   → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
2. Renseigne :
   - **Token name** : `cockpit-deploy`
   - **Expiration** : 90 days (tu le régénéreras)
   - **Repository access** → **Only select repositories** → coche `cockpit`
   - **Permissions** → **Repository permissions** → **Contents** → **Read and write**
     (lecture seule suffira plus tard pour le serveur ; pour l'instant on garde
     write pour pouvoir *push* depuis le MacBook avec le même token)
3. **Generate token**. **Copie la chaîne `github_pat_…` maintenant** (elle ne
   sera plus affichée). Colle-la dans une note temporaire.

### A3. Pousser le code

Dans le terminal, à la racine du projet (`~/Documents/Cockpit`) :

```bash
git remote add origin https://github.com/CedricGeorgel/cockpit.git
git push -u origin main
```

Au prompt : **Username** = `CedricGeorgel`, **Password** = colle le
`github_pat_…`. macOS le retient dans le Trousseau, tu ne le retaperas plus.

> Si `git push` râle « support for password authentication was removed » : c'est
> que tu as tapé ton vrai mot de passe. Recommence, mets le PAT à la place.

Vérifie sur github.com/CedricGeorgel/cockpit que les fichiers sont là.

---

## Partie B — Le serveur OVH (bootstrap, une fois)

### B1. Repérer le dossier du site

Connecte-toi en **FTP** (FileZilla, Transmit, Cyberduck…) avec les identifiants
FTP OVH. Retrouve le dossier servi par `dashboard.caadesign.fr` — c'est là que tu
avais déposé `cockpit-deploy.zip` la dernière fois (souvent quelque chose comme
`dashboard/` ou `www/dashboard/` selon ta config Multisite OVH).

Dans la suite on l'appelle **`DOCROOT`**.

> Tu ne changes **rien** dans le panneau OVH. Le dépôt Git va s'installer
> directement dans `DOCROOT`.

### B2. Préparer `init.php`

Sur le MacBook, à la racine du projet :

```bash
cp init.sample.php init.php
```

Ouvre `init.php` et remplis les 3 lignes en haut :

```php
$REPO = 'https://github_pat_TON_TOKEN@github.com/CedricGeorgel/cockpit.git';
$BRANCH = 'main';
$KEY = 'colle-ici-une-longue-chaine-au-hasard';   // invente-la, garde-la
```

Pour `$KEY`, génère-toi une chaîne :

```bash
openssl rand -hex 24
```

`init.php` est git-ignoré : il ne partira jamais sur GitHub.

### B3. Téléverser et lancer

1. En FTP, envoie **`init.php`** dans `DOCROOT` (à côté des fichiers existants).
2. Dans le navigateur, ouvre :
   `https://dashboard.caadesign.fr/init.php?go=LA_VALEUR_DE_$KEY`
3. Tu dois voir une sortie texte qui se termine par une ligne
   `checkout : HEAD is now at <hash> …`. C'est bon.

   - `git : INTROUVABLE` → OVH n'a pas `git` en shell pour ton offre ;
     ouvre un ticket support (ou reste en FTP + zip).
   - `checkout : … Permission denied` → le dossier n'est pas inscriptible ;
     en FTP, mets `DOCROOT` en `755`.

4. **Supprime `init.php`** du serveur (FTP) — il contient le token.
   Supprime-le aussi du MacBook : `rm init.php`.

### B4. `config.php` (clés Google)

Le `reset --hard` a peut-être écrasé ton ancien `config.php` ? Non : il est
git-ignoré, il survit. **Mais si c'est un tout nouveau dossier**, recrée-le :

1. En FTP, copie `config.sample.php` → `config.php` dans `DOCROOT`.
2. Édite `config.php` et colle :
   ```php
   'google_client_id'     => '....apps.googleusercontent.com',
   'google_client_secret' => 'GOCSPX-....',
   ```

### B5. Le DMG (téléchargement Mac depuis la landing)

En FTP, envoie **`Cockpit.dmg`** (celui produit par `./package.sh`, renommé sans
numéro de version) dans `DOCROOT`. Il est git-ignoré, à réenvoyer à chaque
nouvelle version.

---

## Partie C — Vérifier

```bash
# la PWA
curl -sI https://dashboard.caadesign.fr/ | head -1              # 200

# le flux Google (doit rediriger vers accounts.google.com)
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://dashboard.caadesign.fr/relay.php?auth=start&app=1"    # 302

# les données ne sont pas servies en direct
curl -s -o /dev/null -w '%{http_code}\n' \
  https://dashboard.caadesign.fr/data/                            # 403

# le dépôt n'est pas exposé
curl -s -o /dev/null -w '%{http_code}\n' \
  https://dashboard.caadesign.fr/.git/config                      # 403 ou 404
```

Puis : ouvre `https://dashboard.caadesign.fr/` sur le téléphone → **Se connecter
avec Google** → tu dois revenir connecté.

Côté Google Cloud, revérifie que l'**URI de redirection autorisé** de ton client
OAuth est *exactement* `https://dashboard.caadesign.fr/relay.php`.

---

## Partie D — Les mises à jour (le quotidien)

### D1. Depuis le MacBook

```bash
# ... tes modifs ...
./package.sh "ce que tu as changé"      # rebuild app + DMG + version.json
git add -A && git commit -m "…"
git push
```

### D2. Déclencher le déploiement

Ouvre dans le navigateur :

```
https://dashboard.caadesign.fr/deploy.php?key=LA_VALEUR_DE_$KEY
```

Sortie attendue : `reset : HEAD is now at <hash>` + `opcache : reset`. Le site
est à jour. `config.php`, `data/`, `Cockpit.dmg` ne sont pas touchés.

### D3. Nouvelle version de l'app Mac

1. Change `VERSION="0.2"` dans `build.sh`.
2. `./package.sh "notes de version"` → régénère `version.json` (0.2) et le DMG.
3. `git add -A && git commit -m "v0.2" && git push`
4. `deploy.php?key=…` (met `version.json` en ligne).
5. En FTP, remplace `Cockpit.dmg` par le neuf.

Résultat : la PWA affiche un bandeau « Nouvelle version », l'app Mac affiche
« Cockpit 0.2 est disponible · Télécharger ».

---

## Sécurité — rappels

- Le token vit dans `DOCROOT/.git/config`, bloqué par `.htaccess`. Si tu veux le
  durcir : régénère un PAT **Contents: Read-only**, et sur le serveur (via un
  `init.php` relancé) fais `git remote set-url` avec le nouveau.
- `$KEY` est un mot de passe : ne la mets nulle part de public. Pour la changer,
  édite `deploy.config.php` sur le serveur (ou relance `init.php`).
- `init.php` : **toujours le supprimer** après usage.
