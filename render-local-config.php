<?php

declare(strict_types=1);

/**
 * Render Mautic's local.php from the environment.
 *
 * Mautic keeps its configuration in a PHP file that upstream shares between the web,
 * cron and worker containers through a bind mount. Railway volumes cannot be shared,
 * so instead every role rebuilds the file at boot: the keys listed in $pinned are
 * taken from Railway variables and overlaid on whatever is already on disk.
 *
 * Merging rather than overwriting matters on the web role, whose config directory is
 * on a volume — Mautic's own Configuration UI writes this file, and anything it set
 * that Railway does not pin has to survive a redeploy.
 *
 * Environment:
 *   MAUTIC_LOCAL_CONFIG_FILE  destination path (required)
 *   RAILWAY_RENDER_SITE_URL   "1" to include site_url; omitting it is what keeps
 *                             Mautic's "am I installed?" check false before install
 *   RAILWAY_RENDER_ADMIN      "1" to include the admin_* seed values that
 *                             `mautic:install` reads. Left out on every other boot so
 *                             the bootstrap password is not persisted to the volume.
 */
$target = getenv('MAUTIC_LOCAL_CONFIG_FILE');
if (!is_string($target) || '' === $target) {
    fwrite(STDERR, "render-local-config: MAUTIC_LOCAL_CONFIG_FILE is not set\n");
    exit(1);
}

$env = static function (string $key): ?string {
    $value = getenv($key);

    return (false === $value || '' === $value) ? null : $value;
};

// Load whatever is already there. Mautic's config file defines $parameters.
$parameters = [];
if (is_file($target)) {
    include $target;
}
if (!is_array($parameters)) {
    $parameters = [];
}

// db_driver is hardcoded by Mautic itself; restated so a fresh file is valid.
$pinned = [
    'db_driver'        => 'pdo_mysql',
    'db_host'          => $env('MAUTIC_DB_HOST'),
    'db_port'          => (int) ($env('MAUTIC_DB_PORT') ?? '3306'),
    'db_name'          => $env('MAUTIC_DB_DATABASE'),
    'db_user'          => $env('MAUTIC_DB_USER'),
    'db_password'      => $env('MAUTIC_DB_PASSWORD'),
    'db_table_prefix'  => $env('MAUTIC_DB_TABLE_PREFIX'),
    // Mautic renames existing tables to bak_* when it installs over them. A redeploy
    // must never be able to do that, so the behaviour is pinned off.
    'db_backup_tables' => false,
    'db_backup_prefix' => 'bak_',
    // Encrypts credentials Mautic stores in the database (mail transports, plugin API
    // keys). All three roles must agree on it and it must not change across restarts.
    'secret_key'       => $env('MAUTIC_SECRET_KEY'),
];

// Optional overrides. Only applied when the operator actually set the variable, so an
// unset one leaves Mautic's own default (or a UI-configured value) in place.
$optional = [
    'mailer_dsn'                  => 'MAUTIC_MAILER_DSN',
    'mailer_from_name'            => 'MAUTIC_MAILER_FROM_NAME',
    'mailer_from_email'           => 'MAUTIC_MAILER_FROM_EMAIL',
    'messenger_dsn_email'         => 'MAUTIC_MESSENGER_DSN_EMAIL',
    'messenger_dsn_hit'           => 'MAUTIC_MESSENGER_DSN_HIT',
    'messenger_dsn_failed'        => 'MAUTIC_MESSENGER_DSN_FAILED',
    'trusted_proxies'             => 'MAUTIC_TRUSTED_PROXIES',
    'mautic_installer_use_ssl'    => 'MAUTIC_INSTALLER_USE_SSL',
];
foreach ($optional as $param => $envKey) {
    $value = $env($envKey);
    if (null !== $value) {
        // trusted_proxies is a JSON array in Mautic's config.
        $pinned[$param] = ('trusted_proxies' === $param) ? json_decode($value, true) : $value;
    }
}

if ('1' === getenv('RAILWAY_RENDER_SITE_URL')) {
    $pinned['site_url'] = $env('MAUTIC_SITE_URL');
} else {
    unset($parameters['site_url']);
}

if ('1' === getenv('RAILWAY_RENDER_ADMIN')) {
    $pinned['admin_email']     = $env('MAUTIC_ADMIN_EMAIL');
    $pinned['admin_password']  = $env('MAUTIC_ADMIN_PASSWORD');
    $pinned['admin_username']  = $env('MAUTIC_ADMIN_USERNAME') ?? 'admin';
    $pinned['admin_firstname'] = $env('MAUTIC_ADMIN_FIRSTNAME') ?? 'Admin';
    $pinned['admin_lastname']  = $env('MAUTIC_ADMIN_LASTNAME') ?? 'User';
} else {
    // The installer is the only consumer of these; drop them once it has run.
    foreach (array_keys($parameters) as $key) {
        if (str_starts_with((string) $key, 'admin_')) {
            unset($parameters[$key]);
        }
    }
}

foreach ($pinned as $key => $value) {
    if (null !== $value) {
        $parameters[$key] = $value;
    }
}

ksort($parameters);

$rendered = "<?php\n\n// Generated at container start by render-local-config.php. Keys backed by a Railway\n"
    ."// variable are re-applied on every boot; edits to those in Mautic's Configuration\n"
    ."// UI will not survive a redeploy.\n\n"
    .'$parameters = '.var_export($parameters, true).";\n";

$dir = dirname($target);
if (!is_dir($dir) && !mkdir($dir, 0o775, true) && !is_dir($dir)) {
    fwrite(STDERR, "render-local-config: cannot create {$dir}\n");
    exit(1);
}

if (false === file_put_contents($target, $rendered, LOCK_EX)) {
    fwrite(STDERR, "render-local-config: cannot write {$target}\n");
    exit(1);
}

@chmod($target, 0o660);

$shown = ['site_url', 'db_host', 'db_name', 'db_user', 'messenger_dsn_email'];
$summary = [];
foreach ($shown as $key) {
    if (isset($parameters[$key])) {
        $summary[] = $key.'='.$parameters[$key];
    }
}
fwrite(STDOUT, '[railway] rendered '.$target.' ('.count($parameters).' parameters): '.implode(' ', $summary)."\n");
