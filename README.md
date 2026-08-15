# Mautic on Railway

Deployment wrapper around the official [`mautic/mautic`](https://hub.docker.com/r/mautic/mautic)
image, for running Mautic 7 on [Railway](https://railway.com) as three services that
share one database.

The upstream image is unmodified. Everything here is boot-time glue that closes the gap
between upstream's `docker-compose` shape and Railway's platform constraints.

## Services

All three build this same repository and differ only by `DOCKER_MAUTIC_ROLE`:

| Role | `DOCKER_MAUTIC_ROLE` | Public | Volume | What it runs |
|---|---|---|---|---|
| web | `mautic_web` | yes | `/data` | Apache + mod_php serving the UI, tracking and forms |
| cron | `mautic_cron` | no | — | segment, campaign and trigger schedules |
| worker | `mautic_worker` | no | — | supervisord running `messenger:consume` for the email, hit and failed queues |

A fourth service, MySQL 8.4, holds all application state and also backs the message
queue.

## Why this wrapper exists

**Configuration is rendered from environment variables.** Upstream shares Mautic's
`config/` directory between the web, cron and worker containers through a bind mount.
Railway volumes are strictly 1:1 with a service and cannot be shared, so
`render-local-config.php` rebuilds `local.php` at boot in every role from Railway
variables. Keys backed by a variable are re-applied on each boot; anything else that
Mautic's Configuration UI wrote to the web role's volume is preserved.

**First boot installs Mautic.** A Railway template deploy has no manual steps, so the
web role runs `mautic:install` non-interactively when it finds no schema, creating the
database structure and the first admin user from `MAUTIC_ADMIN_*`. Mautic decides it is
already installed purely from `local.php`, which this wrapper generates — so the check
is made against the database instead. `db_backup_tables` is pinned off so a redeploy can
never rename live tables to `bak_*`.

**Apache's MPM is normalised at container start.** `php:*-apache` images currently ship
with `mpm_event`/`mpm_worker` enabled alongside the `mpm_prefork` that `mod_php`
requires, and Apache aborts with `AH00534: More than one MPM loaded`. A build layer
cannot fix it — the running container's `/etc/apache2` is not the build's — so the
entrypoint re-checks it on every start and validates with `apache2ctl -t`.

**Startup ordering is explicit.** Railway has no service dependency ordering. The cron
and worker roles wait for the database to accept connections and for the web role to
finish creating the schema before handing over to the image's entrypoint.

## Configuration

Required:

| Variable | Notes |
|---|---|
| `MAUTIC_DB_HOST`, `MAUTIC_DB_PORT`, `MAUTIC_DB_DATABASE`, `MAUTIC_DB_USER`, `MAUTIC_DB_PASSWORD` | reference the MySQL service |
| `MAUTIC_SITE_URL` | full public URL, including scheme |
| `MAUTIC_SECRET_KEY` | encrypts credentials Mautic stores in the database; must be identical across all three roles and stable across restarts |
| `MAUTIC_ADMIN_EMAIL`, `MAUTIC_ADMIN_PASSWORD` | read only by the first install |
| `DOCKER_MAUTIC_ROLE` | `mautic_web`, `mautic_cron` or `mautic_worker` |

Optional, each applied only when set: `MAUTIC_MAILER_DSN`, `MAUTIC_MAILER_FROM_NAME`,
`MAUTIC_MAILER_FROM_EMAIL`, `MAUTIC_MESSENGER_DSN_EMAIL`, `MAUTIC_MESSENGER_DSN_HIT`,
`MAUTIC_MESSENGER_DSN_FAILED`, `MAUTIC_TRUSTED_PROXIES`, `MAUTIC_DB_TABLE_PREFIX`,
`MAUTIC_ADMIN_USERNAME`, `MAUTIC_ADMIN_FIRSTNAME`, `MAUTIC_ADMIN_LASTNAME`,
`RAILWAY_DATA_DIR` (defaults to `/data`).

Because these are re-applied on every boot, changing one of them in Mautic's
Configuration UI will not survive a redeploy — change the Railway variable instead.

## Queueing

Mautic 7 dropped `symfony/amqp-messenger`; the Doctrine transport is the only queue
backend it still ships. Setting `MAUTIC_MESSENGER_DSN_EMAIL` and
`MAUTIC_MESSENGER_DSN_HIT` to `doctrine://default` is what gives the worker role
something to consume — left unset, Mautic sends synchronously and the worker idles. The
queue lives in the `messenger_messages` table, so watch database size under heavy
sending.

## Licence

Mautic is GPL-3.0. This wrapper carries no separate licence beyond that of the files it
builds on.
