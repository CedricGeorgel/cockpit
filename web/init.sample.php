<?php
/**
 * BOOTSTRAP à usage unique du déploiement Git.
 * Copie ce fichier en « init.php », renseigne les constantes (dont le TOKEN),
 * téléverse-le, lance-le, PUIS SUPPRIME init.php.  « init.php » est git-ignoré.
 *
 *  1. Édite les 4 constantes ci-dessous.
 *  2. Téléverse ce fichier par FTP dans le docroot du sous-domaine
 *     (le dossier où doivent finir index.html / relay.php).
 *  3. Ouvre  https://TON-DOMAINE/init.php?go=LA_CLE
 *  4. Quand ça affiche « OK », SUPPRIME init.php du serveur.
 *
 * Ensuite les mises à jour passent par deploy.php?key=LA_CLE (versionné, sans token).
 *
 * Prérequis OVH : le binaire `git` doit être accessible en shell_exec
 * (c'est le cas sur la plupart des mutualisés OVH). Le token est un
 * « fine-grained PAT » GitHub, accès *lecture* au seul dépôt cockpit.
 */

$REPO   = 'https://GITHUB_TOKEN@github.com/CedricGeorgel/cockpit.git';
$BRANCH = 'main';
$KEY    = 'CHANGE-MOI-chaine-aleatoire-longue';   // servira aussi pour deploy.php
$SUBDIR = 'web';   // 'web' si le docroot est <repo>/web (recommandé) ; '' si le docroot EST le dépôt

header('Content-Type: text/plain; charset=utf-8');
if (!hash_equals($KEY, (string) ($_GET['go'] ?? ''))) {
    http_response_code(403);
    exit("Ajoute ?go=$KEY à l'URL.\n");
}

/* Racine du dépôt = docroot, ou son parent si le docroot est <repo>/web. */
$root = ($SUBDIR === '') ? __DIR__ : dirname(__DIR__);
$git  = 'git -C ' . escapeshellarg($root);
function sh(string $c): string { return rtrim((string) shell_exec($c . ' 2>&1')); }

$out = [];
$ver = sh('git --version');
$out[] = "git         : " . ($ver ?: 'INTROUVABLE — arrête ici, contacte le support OVH');
if (!$ver) { echo implode("\n", $out), "\n"; exit; }

if (!is_dir("$root/.git")) {
    $out[] = "init        : " . sh("$git init -q && echo ok");
    $out[] = "remote      : " . sh("$git remote add origin " . escapeshellarg($REPO) . " && echo ok");
} else {
    $out[] = "remote      : " . sh("$git remote set-url origin " . escapeshellarg($REPO) . " && echo ok");
}
$out[] = "fileMode    : " . sh("$git config core.fileMode false && echo ok");
$out[] = "fetch       : " . sh("$git fetch --prune origin " . escapeshellarg($BRANCH));
$out[] = "checkout    : " . sh("$git reset --hard " . escapeshellarg("origin/$BRANCH"));
$out[] = "HEAD        : " . sh("$git log -1 --pretty=%h\\ %s");

/* clé partagée pour deploy.php (jamais commitée) */
$cfgDir = ($SUBDIR === '') ? $root : "$root/$SUBDIR";
$wrote  = @file_put_contents(
    "$cfgDir/deploy.config.php",
    "<?php return " . var_export(['key' => $KEY, 'branch' => $BRANCH], true) . ";\n"
);
$out[] = "deploy.config: " . ($wrote ? "écrit ($cfgDir/deploy.config.php)" : "ÉCHEC d'écriture");

echo implode("\n", $out), "\n\n";
echo "OK — supprime init.php maintenant.\n";
echo "Mises à jour suivantes : https://TON-DOMAINE/" . ($SUBDIR ? '' : '') . "deploy.php?key=$KEY\n";
