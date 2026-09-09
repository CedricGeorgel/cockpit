<?php
/**
 * BOOTSTRAP à usage unique du déploiement Git.
 * Copie ce fichier en « init.php », renseigne les 3 constantes (dont le TOKEN),
 * téléverse « init.php » par FTP dans le docroot, ouvre-le dans le navigateur,
 * puis SUPPRIME « init.php ».  (« init.php » est git-ignoré.)
 *
 * Ensuite les mises à jour passent par  deploy.php?key=LA_CLE  (versionné, sans token).
 *
 * Prérequis OVH : le binaire `git` doit être accessible en shell_exec
 * (c'est le cas sur la plupart des mutualisés OVH). Le token est un
 * « fine-grained PAT » GitHub, accès *Contents: read* au seul dépôt cockpit.
 */

$REPO   = 'https://LE_TOKEN_ICI@github.com/CedricGeorgel/cockpit.git';
$BRANCH = 'main';
$KEY    = 'CHANGE-MOI-chaine-aleatoire-longue';   // servira aussi pour deploy.php

header('Content-Type: text/plain; charset=utf-8');
if (!hash_equals($KEY, (string) ($_GET['go'] ?? ''))) {
    http_response_code(403);
    exit("Ajoute ?go=LA_CLE à l'URL (la valeur de \$KEY).\n");
}

$root = __DIR__;                       // le dépôt = le docroot
$git  = 'git -C ' . escapeshellarg($root);
function sh(string $c): string { return rtrim((string) shell_exec($c . ' 2>&1')); }

$out = [];
$ver = sh('git --version');
$out[] = "git          : " . ($ver ?: 'INTROUVABLE — arrête ici, ouvre un ticket OVH');
if (!$ver) { echo implode("\n", $out), "\n"; exit; }

if (!is_dir("$root/.git")) {
    $out[] = "init         : " . sh("$git init -q && echo ok");
    $out[] = "remote       : " . sh("$git remote add origin " . escapeshellarg($REPO) . " && echo ok");
} else {
    $out[] = "remote       : " . sh("$git remote set-url origin " . escapeshellarg($REPO) . " && echo ok");
}
$out[] = "fileMode     : " . sh("$git config core.fileMode false && echo ok");
$out[] = "fetch        : " . sh("$git fetch --prune origin " . escapeshellarg($BRANCH));
$out[] = "checkout     : " . sh("$git reset --hard " . escapeshellarg("origin/$BRANCH"));
$out[] = "HEAD         : " . sh("$git log -1 --pretty=%h\\ %s");

$wrote = @file_put_contents(
    "$root/deploy.config.php",
    "<?php return " . var_export(['key' => $KEY, 'branch' => $BRANCH], true) . ";\n"
);
$out[] = "deploy.config: " . ($wrote ? "écrit" : "ÉCHEC d'écriture (droits du dossier ?)");

echo implode("\n", $out), "\n\n";
echo "Si 'checkout' affiche 'HEAD is now at ...' c'est bon.\n";
echo "1) Supprime init.php du serveur.\n";
echo "2) Crée config.php (copie de config.sample.php + tes clés Google).\n";
echo "3) Mises à jour : https://TON-DOMAINE/deploy.php?key=LA_CLE\n";
