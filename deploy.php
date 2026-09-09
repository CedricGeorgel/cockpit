<?php
/**
 * Déploiement par « git pull » (hébergement mutualisé, sans SSH ni webhook).
 *
 *   1. Une fois : téléverse init.php, lance-le, supprime-le (voir init.php).
 *   2. Ensuite : à chaque mise à jour, ouvre
 *        https://TON-DOMAINE/deploy.php?key=LA_CLE
 *      (ou déclenche-le depuis un GitHub Action / un cron).
 *
 * La clé est dans web/deploy.config.php (créé par init.php, jamais commité).
 * Ce fichier-ci EST versionné : il se met à jour tout seul avec le dépôt.
 */

header('Content-Type: text/plain; charset=utf-8');

$cfgFile = __DIR__ . '/deploy.config.php';
if (!is_file($cfgFile)) {
    http_response_code(409);
    exit("Pas encore initialisé. Téléverse et lance init.php d'abord.\n");
}
$cfg = require $cfgFile;
$key = (string) ($cfg['key'] ?? '');

if ($key === '' || !hash_equals($key, (string) ($_GET['key'] ?? ''))) {
    http_response_code(403);
    exit("Forbidden\n");
}

/** Le dépôt EST le docroot (deploy.php à la racine). */
$root = __DIR__;
if (!is_dir("$root/.git")) {
    http_response_code(409);
    exit("Dépôt Git introuvable. Relance init.php.\n");
}

$branch = (string) ($cfg['branch'] ?? 'main');
$git    = 'git -C ' . escapeshellarg($root);

function sh(string $c): string { return rtrim((string) shell_exec($c . ' 2>&1')); }

$steps = [
    "fetch"  => sh("$git fetch --prune origin"),
    "reset"  => sh("$git reset --hard " . escapeshellarg("origin/$branch")),
    "commit" => sh("$git log -1 --pretty=%h\\ %s\\ (%cr)"),
];

if (function_exists('opcache_reset')) { @opcache_reset(); $steps["opcache"] = "reset"; }

foreach ($steps as $k => $v) echo str_pad($k, 8) . ": " . str_replace("\n", "\n          ", $v) . "\n";
echo "\nOK\n";
