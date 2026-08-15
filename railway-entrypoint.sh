#!/bin/bash
#
# Railway boot wrapper for the official Mautic image.
#
# Runs as root, prepares the container for Railway's constraints, then hands over to
# the image's own /entrypoint.sh, which dispatches on DOCKER_MAUTIC_ROLE.
set -euo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] ERROR: $*" >&2; exit 1; }

ROLE="${DOCKER_MAUTIC_ROLE:-mautic_web}"
DATA_DIR="${RAILWAY_DATA_DIR:-/data}"
CONSOLE="${MAUTIC_CONSOLE:-/var/www/html/bin/console}"
WWW_USER="${MAUTIC_WWW_USER:-www-data}"
WWW_GROUP="${MAUTIC_WWW_GROUP:-www-data}"

for required in MAUTIC_DB_HOST MAUTIC_DB_DATABASE MAUTIC_DB_USER MAUTIC_DB_PASSWORD MAUTIC_SECRET_KEY MAUTIC_SITE_URL; do
  [ -n "${!required:-}" ] || die "$required is required but not set"
done

# Mautic reads config/local.php relative to the app root. Only the web role has a
# volume, so point every role's config directory at $DATA_DIR and let the web role's
# copy live on persistent storage.
export MAUTIC_VOLUME_CONFIG="${MAUTIC_VOLUME_CONFIG:-$DATA_DIR/config}"
export MAUTIC_VOLUME_LOGS="${MAUTIC_VOLUME_LOGS:-$DATA_DIR/logs}"
export MAUTIC_LOCAL_CONFIG_FILE="$MAUTIC_VOLUME_CONFIG/local.php"

mkdir -p "$MAUTIC_VOLUME_CONFIG" "$MAUTIC_VOLUME_LOGS"

# Mautic resolves its own config path from config/paths.php, which honours an optional
# paths_local.php override. Written here rather than baked in so RAILWAY_DATA_DIR works.
printf '<?php\n\n$paths[%s] = %s;\n' \
  "'local_config'" "'$MAUTIC_LOCAL_CONFIG_FILE'" \
  > /var/www/html/config/paths_local.php

render_config() { php /render-local-config.php; }

mysql_do() {
  MYSQL_PWD="$MAUTIC_DB_PASSWORD" mysql \
    --host="$MAUTIC_DB_HOST" --port="${MAUTIC_DB_PORT:-3306}" \
    --user="$MAUTIC_DB_USER" --batch --skip-column-names "$@"
}

wait_for_database() {
  local attempt=0
  until MYSQL_PWD="$MAUTIC_DB_PASSWORD" mysqladmin \
      --host="$MAUTIC_DB_HOST" --port="${MAUTIC_DB_PORT:-3306}" \
      --user="$MAUTIC_DB_USER" ping >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 60 ] || die "database $MAUTIC_DB_HOST did not accept connections after 60 attempts"
    [ $((attempt % 6)) -eq 1 ] && log "waiting for database $MAUTIC_DB_HOST ..."
    sleep 5
  done
  log "database $MAUTIC_DB_HOST is accepting connections"
}

# Mautic's own "already installed?" test reads local.php, which on Railway we generate
# — so it cannot distinguish a fresh database from an installed one. Ask the database.
schema_present() {
  local count
  count=$(mysql_do -e \
    "SELECT COUNT(*) FROM information_schema.tables
      WHERE table_schema = '$MAUTIC_DB_DATABASE'
        AND table_name = '${MAUTIC_DB_TABLE_PREFIX:-}users';" 2>/dev/null) || return 1
  [ "${count:-0}" -ge 1 ]
}

if [ "$ROLE" = "mautic_web" ]; then
  # --- Apache -------------------------------------------------------------------
  # php:*-apache currently enables mpm_event/mpm_worker alongside the mpm_prefork that
  # mod_php requires, and Apache aborts with AH00534. The build's /etc/apache2 is not
  # what runs, so this is re-checked and re-normalised on every container start.
  a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
  rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
  a2enmod mpm_prefork >/dev/null 2>&1 || true
  log "apache MPM modules: $(ls /etc/apache2/mods-enabled/ | grep -E '^mpm_' | tr '\n' ' ')"

  APACHE_PORT="${PORT:-80}"
  sed -ri "s/^Listen [0-9]+/Listen ${APACHE_PORT}/" /etc/apache2/ports.conf
  sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${APACHE_PORT}>/" /etc/apache2/sites-available/000-default.conf
  echo "ServerName localhost" > /etc/apache2/conf-available/zz-railway-servername.conf
  a2enconf zz-railway-servername >/dev/null 2>&1 || true
  apache2ctl -t || die "apache configuration is invalid"
  log "apache will listen on ${APACHE_PORT}"

  # --- Uploaded media ------------------------------------------------------------
  # Mautic serves user uploads from inside the document root, so the volume is linked
  # into place rather than mounted over it. The image ships default images under that
  # path; seed them once so mounting does not hide them.
  mkdir -p "$DATA_DIR/media"
  if [ ! -e "$DATA_DIR/media/.seeded" ]; then
    log "seeding default media from the image into $DATA_DIR/media"
    cp -an /var/www/html/docroot/media/. "$DATA_DIR/media/" 2>/dev/null || true
    touch "$DATA_DIR/media/.seeded"
  fi
  mkdir -p "$DATA_DIR/media/files" "$DATA_DIR/media/images"
  rm -rf /var/www/html/docroot/media
  ln -sfn "$DATA_DIR/media" /var/www/html/docroot/media

  export MAUTIC_VOLUME_MEDIA="$DATA_DIR/media"
  export MAUTIC_VOLUME_FILES="$DATA_DIR/media/files"
  export MAUTIC_VOLUME_IMAGES="$DATA_DIR/media/images"

  # --- First-boot install --------------------------------------------------------
  wait_for_database
  if schema_present; then
    log "existing Mautic schema found; skipping install"
    RAILWAY_RENDER_SITE_URL=1 render_config
  else
    log "no Mautic schema found; installing Mautic non-interactively"
    [ -n "${MAUTIC_ADMIN_EMAIL:-}" ] || die "MAUTIC_ADMIN_EMAIL is required for the first install"
    [ -n "${MAUTIC_ADMIN_PASSWORD:-}" ] || die "MAUTIC_ADMIN_PASSWORD is required for the first install"

    # site_url is deliberately withheld: Mautic treats "db_driver and site_url both
    # present" as proof it is already installed and would refuse to run. The admin_*
    # values are read out of local.php by mautic:install, which keeps the password off
    # the process list.
    RAILWAY_RENDER_ADMIN=1 render_config
    chown -R "$WWW_USER:$WWW_GROUP" "$MAUTIC_VOLUME_CONFIG" /var/www/html/var
    su -s /bin/bash "$WWW_USER" -c "php $CONSOLE mautic:install '$MAUTIC_SITE_URL' --force" \
      || die "mautic:install failed"
    schema_present || die "mautic:install reported success but the schema is missing"
    log "Mautic installed"

    # Re-render with site_url and without the admin seed values.
    RAILWAY_RENDER_SITE_URL=1 render_config
  fi
else
  # cron and worker have no volume and no install responsibility. They only need a
  # config file that matches the web role's and a schema to work against — Railway has
  # no service ordering, so wait for the web role to finish installing.
  RAILWAY_RENDER_SITE_URL=1 render_config
  wait_for_database
  attempt=0
  until schema_present; do
    attempt=$((attempt + 1))
    [ $((attempt % 6)) -eq 1 ] && log "[$ROLE] waiting for the web role to install the Mautic schema ..."
    sleep 10
  done
  log "[$ROLE] Mautic schema is present"
fi

chown -R "$WWW_USER:$WWW_GROUP" "$MAUTIC_VOLUME_CONFIG" "$MAUTIC_VOLUME_LOGS" 2>/dev/null || true

# The image compiles Symfony's container at build time, when no database configuration
# exists. Drop that cache and rebuild it against the real config, otherwise the first
# request pays for the rebuild inside the health-check window.
rm -rf /var/www/html/var/cache/prod
su -s /bin/bash "$WWW_USER" -c "php $CONSOLE cache:warmup --no-interaction" >/dev/null 2>&1 \
  || log "cache:warmup did not complete; the first request will rebuild it"

log "handing over to the Mautic image entrypoint (role=$ROLE)"
exec /entrypoint.sh "$@"
