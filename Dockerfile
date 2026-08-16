# Mautic on Railway.
#
# A thin wrapper over the official image. Nothing about Mautic itself changes —
# the wrapper only adds what the platform needs:
#
#   * the Apache MPM normalisation every php:*-apache image currently needs
#   * one consolidated volume, because Railway allows a service exactly one
#   * the two settings Mautic reads from a file rather than the environment
#     (trusted_proxies, HSTS) written at boot
#   * an idempotent first-boot `mautic:install`, so a template deploy needs no
#     manual setup step
#
# The tag is pinned because the web, worker and cron services all build from
# this file and must run the same Mautic release against one database schema.
ARG MAUTIC_TAG=7.1.3-apache
FROM mautic/mautic:${MAUTIC_TAG}

COPY --chmod=755 railway-entrypoint.sh /railway-entrypoint.sh

# The upstream image already runs as root and drops to www-data itself; the
# entrypoint needs root to chown the volume and normalise the Apache config.
USER root

ENTRYPOINT ["/railway-entrypoint.sh"]
