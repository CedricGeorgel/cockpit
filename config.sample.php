<?php
// Copie ce fichier en « config.php » (même dossier).

return [
    // --- Connexion Google (« Se connecter avec Google » sur l'app et le web) ---
    // Console Google Cloud → Identifiants → ID client OAuth, type « Application Web ».
    //   URI de redirection autorisé : https://TON-DOMAINE/relay.php   (sans query)
    // Écran de consentement : scopes openid / email / profile, puis « Publier ».
    'google_client_id'     => '',   // ....apps.googleusercontent.com
    'google_client_secret' => '',   // GOCSPX-....

    // --- Rétro-compat : ancienne création d'instance par clé (?new) ---
    //   ''        n'importe qui peut créer une instance (par défaut)
    //   'xyz…'    il faut ce code
    'signup_code' => '',

    // Garde-fou anti-abus sur l'ancienne création d'instances.
    'max_instances' => 200,

    // Emplacement des données. Par défaut « data/ » à côté de relay.php,
    // protégé par data/.htaccess. Ne change que si tu sais ce que tu fais.
    // 'data_dir' => __DIR__ . '/data',
];
