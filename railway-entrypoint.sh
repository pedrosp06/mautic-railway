#!/bin/bash
# Prepare the container for Railway, then hand over to the image's own
# entrypoint unchanged. Runs as root; every Mautic command is run as www-data.
set -euo pipefail

ROLE="${DOCKER_MAUTIC_ROLE:-mautic_web}"
APP_DIR=/var/www/html
CONFIG_DIR="${APP_DIR}/config"
DATA_DIR="${MAUTIC_DATA_DIR:-/data}"
DB_PORT="${MAUTIC_DB_PORT:-3306}"

log() { echo "[railway] $*"; }

# --------------------------------------------------------------------------
# Volume. Railway gives a service one volume, while the image wants three
# separate paths persisted, so the volume holds all of them and the image paths
# become symlinks into it. Existing image content is copied across once, before
# the original directory is replaced, so nothing baked in is hidden.
# --------------------------------------------------------------------------
link_into_volume() {
  local src="$1" dst="$2"
  [ -L "$src" ] && return 0
  mkdir -p "$dst"
  if [ -d "$src" ] && [ -z "$(ls -A "$dst")" ]; then
    cp -a "$src/." "$dst/"
  fi
  rm -rf "$src"
  ln -s "$dst" "$src"
}

if [ -d "$DATA_DIR" ]; then
  log "consolidating persistent paths under ${DATA_DIR}"
  link_into_volume "$CONFIG_DIR"                    "${DATA_DIR}/config"
  link_into_volume "${APP_DIR}/docroot/media"       "${DATA_DIR}/media"
  link_into_volume "${APP_DIR}/var/logs"            "${DATA_DIR}/logs"
  chown -R www-data:www-data "$DATA_DIR"
  chmod -R u+rwX,g+rwX "$DATA_DIR"
fi

# The image chowns var/ at build time, but the directories Symfony writes to are
# created lazily, so make sure they exist and belong to www-data either way.
mkdir -p "${APP_DIR}/var/cache" "${APP_DIR}/var/tmp" "${APP_DIR}/var/logs"
chown -R www-data:www-data "${APP_DIR}/var"

# --------------------------------------------------------------------------
# Apache. Two fixes, both web-role only.
#
# The php:*-apache images currently ship mpm_event/mpm_worker enabled alongside
# the mpm_prefork that mod_php requires, which aborts the server on
# "More than one MPM loaded". Re-normalising has to happen here rather than in
# a build layer, because the build's /etc/apache2 is not what ends up running.
#
# Railway health-checks the port named by $PORT, so Apache listens on it.
# --------------------------------------------------------------------------
if [ "$ROLE" = "mautic_web" ]; then
  a2dismod -f mpm_event mpm_worker >/dev/null 2>&1 || true
  rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
  a2enmod mpm_prefork >/dev/null 2>&1 || true
  log "apache MPM modules enabled: $(cd /etc/apache2/mods-enabled && ls mpm_* 2>/dev/null | tr '\n' ' ')"

  APACHE_PORT="${PORT:-80}"
  sed -ri "s/^Listen [0-9]+$/Listen ${APACHE_PORT}/" /etc/apache2/ports.conf
  sed -ri "s!<VirtualHost \\*:[0-9]+>!<VirtualHost *:${APACHE_PORT}>!" /etc/apache2/sites-available/*.conf
  grep -q '^ServerName ' /etc/apache2/apache2.conf || echo 'ServerName localhost' >> /etc/apache2/apache2.conf
  log "apache listening on ${APACHE_PORT}"
  apache2ctl -t || true
fi

# --------------------------------------------------------------------------
# Forced parameters.
#
# Almost every Mautic setting can come from a MAUTIC_* environment variable,
# but three consumers read the config *files* directly and never the
# environment: the trusted-proxy and HSTS middlewares, and the secure-cookie
# decision that is derived from site_url. parameters_local.php is loaded after
# local.php and wins, so it is where the platform's own settings belong.
#
# The file calls getenv() rather than embedding values, so a changed domain or
# rotated key takes effect on the next boot with no rewrite.
#
# trusted_proxies covers every address on purpose. Railway's edge overwrites a
# client-supplied X-Forwarded-For and appends its own entry, and that entry is a
# public address that rotates per request; trusting all hops makes Symfony
# return the leftmost entry, which is the real client.
# --------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
cat > "${CONFIG_DIR}/parameters_local.php" <<'PHP'
<?php
// Written by the Railway entrypoint on every boot. Edit the service variables
// instead; changes made here are overwritten.
$parameters = [
    'site_url'                => getenv('MAUTIC_SITE_URL') ?: '',
    'secret_key'              => getenv('MAUTIC_SECRET_KEY') ?: 'temp',
    'trusted_proxies'         => ['0.0.0.0/0', '::/0'],
    'headers_sts'             => true,
    'headers_sts_expire_time' => 31536000,
];
PHP
chown www-data:www-data "${CONFIG_DIR}/parameters_local.php"

# --------------------------------------------------------------------------
# Database helpers.
# --------------------------------------------------------------------------
db() {
  MYSQL_PWD="${MAUTIC_DB_PASSWORD}" mysql \
    --host="${MAUTIC_DB_HOST}" --port="${DB_PORT}" --user="${MAUTIC_DB_USER}" \
    --database="${MAUTIC_DB_DATABASE}" --batch --skip-column-names -e "$1"
}

wait_for_db() {
  local i
  for i in $(seq 1 60); do
    if MYSQL_PWD="${MAUTIC_DB_PASSWORD}" mysqladmin \
         --host="${MAUTIC_DB_HOST}" --port="${DB_PORT}" \
         --user="${MAUTIC_DB_USER}" ping >/dev/null 2>&1; then
      return 0
    fi
    [ $((i % 6)) -eq 1 ] && log "waiting for ${MAUTIC_DB_HOST}:${DB_PORT} (attempt ${i})"
    sleep 5
  done
  return 1
}

mautic_schema_present() {
  local n
  n=$(db "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'users';" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

# local.php is what both the image and Mautic itself treat as the "installed"
# marker: db_driver plus site_url present means installed. Mautic writes it
# during installation and whenever an admin saves the configuration screen.
write_local_php() {
  cat > "${CONFIG_DIR}/local.php" <<'PHP'
<?php
$parameters = [
    'db_driver'       => 'pdo_mysql',
    'db_host'         => getenv('MAUTIC_DB_HOST'),
    'db_port'         => getenv('MAUTIC_DB_PORT') ?: 3306,
    'db_name'         => getenv('MAUTIC_DB_DATABASE'),
    'db_user'         => getenv('MAUTIC_DB_USER'),
    'db_password'     => getenv('MAUTIC_DB_PASSWORD'),
    'db_table_prefix' => null,
    'site_url'        => getenv('MAUTIC_SITE_URL'),
];
PHP
  chown www-data:www-data "${CONFIG_DIR}/local.php"
}

installed_marker_present() {
  [ -f "${CONFIG_DIR}/local.php" ] && php -r "
    \$parameters = [];
    include '${CONFIG_DIR}/local.php';
    exit(!empty(\$parameters['db_driver']) && !empty(\$parameters['site_url']) ? 0 : 1);
  " 2>/dev/null
}

as_www_data() {
  ( cd "$APP_DIR" \
    && setpriv --reuid=www-data --regid=www-data --init-groups \
         env HOME=/var/www "$@" )
}

# Mautic's installer refuses to start unless it can write its config, cache and
# log directories, and reports only an untranslated placeholder for the path it
# tried. Print what it will actually see, as the user it will actually run as.
report_writability() {
  log "paths: config -> $(readlink -f "$CONFIG_DIR" 2>/dev/null || echo '?')"
  ls -ldn "$CONFIG_DIR" "${APP_DIR}/var/cache" "${APP_DIR}/var/logs" 2>&1 | sed 's/^/[railway] /'
  ls -ldn "$DATA_DIR" "${DATA_DIR}"/* 2>&1 | sed 's/^/[railway] /'
  ls -lan "${DATA_DIR}/config" 2>&1 | sed 's/^/[railway] /'
  as_www_data sh -c 'touch /var/www/html/config/.probe && echo "[railway] probe write: ok" || echo "[railway] probe write: denied"'
  rm -f "${CONFIG_DIR}/.probe" 2>/dev/null || true
  as_www_data php -r '
    foreach (["/var/www/html/config", "/var/www/html/var/cache", "/var/www/html/var/logs"] as $p) {
      printf("[railway] writable %s: %s\n", $p, is_writable($p) ? "yes" : "no");
    }
  '
}

case "$ROLE" in
  mautic_web)
    if installed_marker_present; then
      log "already installed; leaving config alone"
    else
      wait_for_db || { log "database never became reachable"; exit 1; }

      if mautic_schema_present; then
        # The database survived but the config did not — a replaced volume, say.
        # Re-point at the existing schema rather than reinstalling over it.
        log "existing Mautic schema found with no local config; restoring config"
        write_local_php
      elif [ -n "${MAUTIC_ADMIN_EMAIL:-}" ] && [ -n "${MAUTIC_ADMIN_PASSWORD:-}" ]; then
        log "empty database; running mautic:install for ${MAUTIC_SITE_URL}"
        report_writability
        as_www_data php bin/console mautic:install "${MAUTIC_SITE_URL}" \
          --force --no-interaction \
          --db_host="${MAUTIC_DB_HOST}" \
          --db_port="${DB_PORT}" \
          --db_name="${MAUTIC_DB_DATABASE}" \
          --db_user="${MAUTIC_DB_USER}" \
          --db_password="${MAUTIC_DB_PASSWORD}" \
          --admin_email="${MAUTIC_ADMIN_EMAIL}" \
          --admin_password="${MAUTIC_ADMIN_PASSWORD}" \
          --admin_username="${MAUTIC_ADMIN_USERNAME:-admin}" \
          --admin_firstname="${MAUTIC_ADMIN_FIRSTNAME:-Admin}" \
          --admin_lastname="${MAUTIC_ADMIN_LASTNAME:-User}"
        installed_marker_present \
          && log "install complete" \
          || { log "install did not write a usable config"; exit 1; }
      else
        # No admin credentials supplied: fall through to Mautic's own web
        # installer, which the image already pre-fills with the DB settings.
        log "MAUTIC_ADMIN_EMAIL/MAUTIC_ADMIN_PASSWORD unset; leaving the web installer to run"
      fi
    fi
    ;;

  mautic_worker|mautic_cron)
    # These roles never install anything, and Railway cannot share the web
    # service's volume with them, so they get their config from the environment.
    # Waiting on the schema keeps them from consuming against an empty database
    # while the web service is still installing.
    wait_for_db || { log "database never became reachable"; exit 1; }
    i=0
    until mautic_schema_present; do
      i=$((i + 1))
      [ $((i % 6)) -eq 1 ] && log "waiting for the web service to finish installing Mautic (attempt ${i})"
      [ "$i" -ge 120 ] && { log "Mautic schema never appeared"; exit 1; }
      sleep 10
    done
    write_local_php
    log "config written from environment; starting ${ROLE}"
    ;;
esac

exec /entrypoint.sh "$@"
