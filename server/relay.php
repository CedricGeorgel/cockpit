<?php
/**
 * Cockpit, relais mobile (PHP, hébergement mutualisé, sans SSH).
 *
 * Déposé (avec la PWA) dans un dossier servi en HTTPS. On se connecte avec
 * Google (sur l'app ET sur le web) ; le relais échange le code, vérifie
 * l'identité, et émet SON PROPRE jeton de session. Le compte = l'identifiant
 * Google. Personne ne voit les données d'un autre.
 *
 *   GET  relay.php?auth=start&redirect=… → 302 vers Google
 *   GET  relay.php?code=…&state=…        → callback Google, 302 vers redirect#t=<jeton>
 *   GET  relay.php?auth=me               → {email, name} (Bearer)
 *   POST relay.php?auth=logout           → révoque la session (Bearer)
 *
 *   GET  relay.php?f=fleet      → agrège les appareils du compte (Bearer)
 *   POST relay.php?f=device&d=… → un appareil écrit son état (Bearer)
 *   GET/POST relay.php?f=commands | ?f=settings → file d'actions / réglages
 *
 * Rétro-compat : ?new + ?i=<instance> + jeton d'instance restent acceptés.
 *
 * Config voisine : config.php (google_client_id, google_client_secret),
 * .htaccess, data/.htaccess. Contrat détaillé : docs/mobile-sync.md
 */

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS');
header('Access-Control-Allow-Headers: Authorization, Content-Type, X-Auth-Token');
header('Access-Control-Max-Age: 86400');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }

$cfg    = @include __DIR__ . '/config.php';
if (!is_array($cfg)) $cfg = [];
$SIGNUP  = (string) ($cfg['signup_code']   ?? '');
$MAX     = (int)    ($cfg['max_instances']  ?? 50);
$DATA    = $cfg['data_dir'] ?? (__DIR__ . '/data');
$GCID    = (string) ($cfg['google_client_id']     ?? '');
$GCSECRET= (string) ($cfg['google_client_secret'] ?? '');
@mkdir($DATA, 0755, true);

// ---------------------------------------------------------------- authentification
$auth = $_GET['auth'] ?? '';
// Google redirige vers l'URI nue (relay.php) en ajoutant ?code&state.
if ($auth === '' && isset($_GET['state']) && (isset($_GET['code']) || isset($_GET['error'])))
    $auth = 'callback';
if ($auth !== '') { handle_auth($auth, $DATA, $GCID, $GCSECRET); exit; }

function out($x, int $code = 200) {
    http_response_code($code);
    header('Content-Type: application/json');
    echo is_string($x) ? $x : json_encode($x);
    exit;
}
function b64url(string $s): string { return rtrim(strtr(base64_encode($s), '+/', '-_'), '='); }
function self_url(): string {
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    $local = preg_match('/^(localhost|127\.0\.0\.1|\[?::1\]?)(:\d+)?$/', $host)
          || preg_match('/\.local(:\d+)?$/', $host);
    // Derrière le proxy TLS d'un mutualisé OVH, $_SERVER['HTTPS'] est souvent absent.
    // On considère HTTPS par défaut pour un vrai domaine ; HTTP seulement en local.
    $forwardedHttps = in_array(strtolower($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? ''), ['https'], true)
          || strtolower($_SERVER['HTTP_X_FORWARDED_SSL'] ?? '') === 'on'
          || strtolower($_SERVER['REQUEST_SCHEME'] ?? '') === 'https';
    $directHttps = (!empty($_SERVER['HTTPS']) && strtolower($_SERVER['HTTPS']) !== 'off')
          || ($_SERVER['SERVER_PORT'] ?? '') == 443;
    $https = $forwardedHttps || $directHttps || !$local;
    return ($https ? 'https' : 'http') . '://' . $host
         . strtok($_SERVER['REQUEST_URI'], '?');
}
function bearer(): ?string {
    $src = [];
    foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION'] as $k)
        if (!empty($_SERVER[$k])) $src[] = $_SERVER[$k];
    if (function_exists('getallheaders'))
        foreach (getallheaders() as $k => $v) {
            if (strcasecmp($k, 'Authorization') === 0) $src[] = $v;
            if (strcasecmp($k, 'X-Auth-Token')  === 0) $src[] = 'Bearer ' . $v;
        }
    if (!empty($_SERVER['HTTP_X_AUTH_TOKEN'])) $src[] = 'Bearer ' . $_SERVER['HTTP_X_AUTH_TOKEN'];
    foreach ($src as $s) if (preg_match('/Bearer\s+(\S+)/i', $s, $m)) return $m[1];
    return null;
}
function b64url_decode(string $s): string {
    return base64_decode(strtr($s, '-_', '+/') . str_repeat('=', (4 - strlen($s) % 4) % 4));
}
/// POST application/x-www-form-urlencoded. curl si dispo, sinon flux HTTP.
function http_post_form(string $url, array $fields): ?array {
    $body = http_build_query($fields);
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_POST => true, CURLOPT_POSTFIELDS => $body,
            CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15,
            CURLOPT_HTTPHEADER => ['Content-Type: application/x-www-form-urlencoded'],
        ]);
        $res = curl_exec($ch); curl_close($ch);
        if ($res === false) return null;
        $j = json_decode($res, true);
        return is_array($j) ? $j : null;
    }
    $ctx = stream_context_create(['http' => [
        'method' => 'POST', 'timeout' => 15, 'ignore_errors' => true,
        'header' => "Content-Type: application/x-www-form-urlencoded\r\n",
        'content' => $body,
    ]]);
    $res = @file_get_contents($url, false, $ctx);
    if ($res === false) return null;
    $j = json_decode($res, true);
    return is_array($j) ? $j : null;
}
/// Petite page HTML (erreur d'auth lisible dans le navigateur / la webview).
function auth_fail(string $msg): void {
    http_response_code(400);
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><meta charset=utf-8><title>Connexion Cockpit</title>'
       . '<body style="font:15px system-ui;margin:3rem;max-width:32rem">'
       . '<h2>Connexion impossible</h2><p>' . htmlspecialchars($msg) . '</p>'
       . '<p><a href="javascript:history.back()">Retour</a></p>';
    exit;
}
/// Résout un jeton de session Cockpit → dossier de compte, ou null.
function account_dir_for_token(string $DATA, ?string $tok): ?array {
    if (!$tok) return null;
    $sf = $DATA . '/sess/' . hash('sha256', $tok) . '.json';
    $sj = @json_decode(@file_get_contents($sf), true);
    if (!is_array($sj) || empty($sj['acct'])) return null;
    if (time() - ($sj['seen'] ?? 0) > 86400) {
        $sj['seen'] = time();
        @file_put_contents($sf, json_encode($sj));
    }
    return ['dir' => $DATA . '/acct/' . $sj['acct'], 'sess' => $sj];
}

/// Flux Google : ?auth=start | callback (?code&state) | me | logout.
function handle_auth(string $auth, string $DATA, string $GCID, string $GCSECRET): void {
    $odir = $DATA . '/oauth';
    @mkdir($odir, 0755, true);
    // Ménage des states périmés (>10 min).
    foreach (glob($odir . '/*.json') ?: [] as $sf)
        if (time() - filemtime($sf) > 600) @unlink($sf);

    if ($auth === 'me') {
        $a = account_dir_for_token($DATA, bearer());
        if (!$a) out(['error' => 'non authentifié'], 401);
        out(['email' => $a['sess']['email'] ?? '', 'name' => $a['sess']['name'] ?? '']);
    }
    if ($auth === 'logout') {
        $tok = bearer();
        if ($tok) @unlink($DATA . '/sess/' . hash('sha256', $tok) . '.json');
        http_response_code(204); exit;
    }

    if ($GCID === '' || $GCSECRET === '')
        auth_fail("Le serveur n'est pas configuré pour Google (config.php : google_client_id / google_client_secret).");

    $redirect_uri = self_url();   // = https://<hôte>/relay.php (sans query)

    if ($auth === 'start') {
        // La cible du retour n'est jamais fournie par le client : soit l'app
        // (schéma cockpit://), soit la PWA voisine (dossier de relay.php).
        $isApp = ($_GET['app'] ?? '') === '1' || ($_GET['redirect'] ?? '') === 'cockpit://auth';
        $webReturn = preg_replace('#/[^/]*(\?.*)?$#', '/', self_url());   // …/relay.php → …/
        $r = $isApp ? 'cockpit://auth' : $webReturn;

        $state = bin2hex(random_bytes(16));
        file_put_contents($odir . '/' . $state . '.json', json_encode(['redirect' => $r]));
        $q = http_build_query([
            'client_id'     => $GCID,
            'redirect_uri'  => $redirect_uri,
            'response_type' => 'code',
            'scope'         => 'openid email profile',
            'state'         => $state,
            'access_type'   => 'online',
            'prompt'        => 'select_account',
        ]);
        header('Location: https://accounts.google.com/o/oauth2/v2/auth?' . $q, true, 302);
        exit;
    }

    if ($auth === 'callback') {
        $state = (string) ($_GET['state'] ?? '');
        $code  = (string) ($_GET['code'] ?? '');
        if (!preg_match('/^[a-f0-9]{32}$/', $state)) auth_fail('State invalide.');
        $spath = $odir . '/' . $state . '.json';
        $sj = @json_decode(@file_get_contents($spath), true);
        @unlink($spath);
        if (!is_array($sj)) auth_fail('Session de connexion expirée, réessaie.');
        if (isset($_GET['error'])) auth_fail('Google a refusé la connexion (' . htmlspecialchars($_GET['error']) . ').');

        $tok = http_post_form('https://oauth2.googleapis.com/token', [
            'code'          => $code,
            'client_id'     => $GCID,
            'client_secret' => $GCSECRET,
            'redirect_uri'  => $redirect_uri,
            'grant_type'    => 'authorization_code',
        ]);
        if (!$tok || empty($tok['id_token'])) auth_fail("Échange du code impossible auprès de Google.");

        $parts = explode('.', $tok['id_token']);
        $claims = count($parts) === 3 ? json_decode(b64url_decode($parts[1]), true) : null;
        if (!is_array($claims)) auth_fail('Jeton Google illisible.');
        if (($claims['aud'] ?? '') !== $GCID) auth_fail('Jeton Google adressé à une autre application.');
        if (($claims['exp'] ?? 0) < time()) auth_fail('Jeton Google expiré.');
        $iss = $claims['iss'] ?? '';
        if ($iss !== 'accounts.google.com' && $iss !== 'https://accounts.google.com')
            auth_fail('Émetteur du jeton inattendu.');
        $sub = (string) ($claims['sub'] ?? '');
        if ($sub === '') auth_fail('Identifiant Google manquant.');

        $acct = substr(hash('sha256', $sub), 0, 24);
        @mkdir($DATA . '/acct/' . $acct, 0755, true);
        $opath = $DATA . '/acct/' . $acct . '/owner.json';
        $owner = @json_decode(@file_get_contents($opath), true) ?: [];
        $owner['sub']   = $sub;
        $owner['email'] = $claims['email'] ?? ($owner['email'] ?? '');
        $owner['name']  = $claims['name']  ?? ($owner['name']  ?? '');
        $owner['created'] = $owner['created'] ?? time();
        $owner['seen']  = time();
        @file_put_contents($opath, json_encode($owner));

        $sess = bin2hex(random_bytes(24));   // 48 hex, jamais journalisé (fragment #)
        @mkdir($DATA . '/sess', 0755, true);
        @file_put_contents($DATA . '/sess/' . hash('sha256', $sess) . '.json', json_encode([
            'acct'    => $acct,
            'email'   => $owner['email'],
            'name'    => $owner['name'],
            'created' => time(),
            'seen'    => time(),
        ]));

        $frag = 't=' . $sess . '&e=' . rawurlencode($owner['email']);
        $dest = $sj['redirect'];
        $dest .= (strpos($dest, '#') === false ? '#' : '&') . $frag;
        header('Location: ' . $dest, true, 302);
        // Certaines webviews suivent mal un 302 vers un schéma custom : filet de secours.
        echo '<!doctype html><meta charset=utf-8><meta http-equiv="refresh" content="0;url='
           . htmlspecialchars($dest, ENT_QUOTES) . '"><body style="font:15px system-ui;margin:3rem">'
           . 'Connexion réussie. <a href="' . htmlspecialchars($dest, ENT_QUOTES) . '">Continuer</a>.';
        exit;
    }

    auth_fail('Action d’authentification inconnue.');
}

function rmrf(string $d): void { array_map('unlink', glob($d . '/*') ?: []); @rmdir($d); }

function gc_instances(string $DATA): void {
    // Sessions Google inactives depuis 90 j.
    foreach (glob($DATA . '/sess/*.json') ?: [] as $sf) {
        $sj = @json_decode(@file_get_contents($sf), true);
        if (!is_array($sj) || time() - ($sj['seen'] ?? filemtime($sf)) > 90 * 86400) @unlink($sf);
    }
    // Comptes : purge des dev.*.json > 30 j ; compte sans appareil ET inactif > 60 j → supprimé.
    foreach (glob($DATA . '/acct/*', GLOB_ONLYDIR) ?: [] as $d) {
        foreach (glob($d . '/dev.*.json') ?: [] as $df)
            if (time() - filemtime($df) > 30 * 86400) @unlink($df);
        $owner = @json_decode(@file_get_contents($d . '/owner.json'), true) ?: [];
        if (!glob($d . '/dev.*.json') && time() - ($owner['seen'] ?? 0) > 60 * 86400) rmrf($d);
    }
    // Anciennes instances (?new) : mêmes règles qu'avant.
    foreach (glob($DATA . '/*', GLOB_ONLYDIR) ?: [] as $d) {
        $meta = @json_decode(@file_get_contents($d . '/meta.json'), true);
        if (!is_array($meta)) continue;
        foreach (glob($d . '/dev.*.json') ?: [] as $df)
            if (time() - filemtime($df) > 30 * 86400) @unlink($df);
        if (!glob($d . '/dev.*.json') && time() - ($meta['created'] ?? 0) > 7 * 86400) rmrf($d);
    }
}

// ---------------------------------------------------------------- provisionnement
if (isset($_GET['new'])) {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') out(['error' => 'POST requis'], 405);
    $in   = json_decode(file_get_contents('php://input'), true) ?: [];
    $code = (string) ($_GET['code'] ?? $in['code'] ?? '');
    if ($SIGNUP !== '' && !hash_equals($SIGNUP, $code))
        out(['error' => 'code d’accès requis ou invalide'], 403);

    gc_instances($DATA);
    if (count(glob($DATA . '/*', GLOB_ONLYDIR) ?: []) >= $MAX)
        out(['error' => 'nombre maximum d’instances atteint'], 429);

    $instance = bin2hex(random_bytes(9));   // 18 hex
    $token    = bin2hex(random_bytes(24));  // 48 hex
    $idir     = $DATA . '/' . $instance;
    if (!@mkdir($idir, 0755)) out(['error' => 'création impossible (dossier data/ inscriptible ?)'], 500);
    file_put_contents($idir . '/meta.json', json_encode([
        'created'      => time(),
        'token_sha256' => hash('sha256', $token),
    ]));
    out([
        'instance' => $instance,
        'token'    => $token,
        'key'      => b64url(json_encode(['u' => self_url(), 'i' => $instance, 't' => $token])),
    ]);
}

// ---------------------------------------------------------------- accès au compte
$f = $_GET['f'] ?? '';
$i = $_GET['i'] ?? '';
$d = $_GET['d'] ?? '';
// Rétro-compat : d'anciens clients utilisent ?f=snapshot.
if ($f === 'snapshot') { $f = ($_SERVER['REQUEST_METHOD'] === 'GET') ? 'fleet_compat' : 'device'; if ($d === '') $d = '0eadbeef'; }
if (!in_array($f, ['fleet', 'fleet_compat', 'device', 'commands', 'settings'], true))
    out(['error' => 'requête invalide'], 404);

$tok  = bearer();
$idir = null;

// 1. Jeton de session Google (cas normal).
if ($a = account_dir_for_token($DATA, $tok)) { $idir = $a['dir']; @mkdir($idir, 0755, true); }

// 2. Rétro-compat : ?i=<instance> + jeton d'instance.
if (!$idir && preg_match('/^[a-f0-9]{18}$/', $i)) {
    $legacy = $DATA . '/' . $i;
    $meta = @json_decode(@file_get_contents($legacy . '/meta.json'), true);
    if (is_array($meta) && hash_equals((string) ($meta['token_sha256'] ?? '_'), hash('sha256', (string) $tok)))
        $idir = $legacy;
}

if (!$idir) out(['error' => 'non authentifié'], 401);

$method = $_SERVER['REQUEST_METHOD'];

// --- lecture de la flotte : agrège tous les dev.*.json ---
if (($f === 'fleet' || $f === 'fleet_compat') && $method === 'GET') {
    $devs = [];
    foreach (glob($idir . '/dev.*.json') ?: [] as $df) {
        $j = json_decode(file_get_contents($df));
        if ($j) { $j->_mtime = filemtime($df); $devs[] = $j; }
    }
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    if ($f === 'fleet_compat') {                       // ancien client : renvoie l'appareil le plus récent
        if (!$devs) { echo '{}'; exit; }               // flotte vide : pas une erreur
        usort($devs, fn($a, $b) => ($b->_mtime ?? 0) <=> ($a->_mtime ?? 0));
        echo json_encode($devs[0]);
    } else {
        echo json_encode(['devices' => $devs, 'generatedAt' => date('c')]);
    }
    exit;
}

// --- écriture de l'état d'un appareil ---
if ($f === 'device') {
    if (!preg_match('/^[a-f0-9]{8,32}$/', $d)) out(['error' => 'appareil invalide'], 400);
    if ($method !== 'POST' && $method !== 'PUT') out(['error' => 'POST requis'], 405);
    write_json($idir . '/dev.' . $d . '.json');
}

// --- file de commandes / réglages partagés ---
if ($f === 'commands' || $f === 'settings') {
    $path = $idir . '/' . $f . '.json';
    if ($method === 'GET') {
        header('Content-Type: application/json');
        header('Cache-Control: no-store');
        if (!is_file($path)) { echo '{}'; exit; }      // rien encore poussé : objet vide, pas 404
        readfile($path);
        exit;
    }
    if ($method === 'POST' || $method === 'PUT') write_json($path);
}
out(['error' => 'méthode non gérée'], 405);

function write_json(string $path): void {
    $raw = file_get_contents('php://input');
    if (strlen($raw) === 0 || strlen($raw) > 5 * 1024 * 1024) out(['error' => 'corps vide ou trop gros'], 413);
    json_decode($raw);
    if (json_last_error() !== JSON_ERROR_NONE) out(['error' => 'JSON invalide'], 400);
    $tmp = $path . '.tmp' . getmypid();
    if (file_put_contents($tmp, $raw, LOCK_EX) === false || !rename($tmp, $path)) {
        @unlink($tmp);
        out(['error' => 'écriture impossible'], 500);
    }
    http_response_code(204);
    exit;
}
