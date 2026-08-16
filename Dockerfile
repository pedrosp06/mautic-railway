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
# The tag is pinned for two reasons. The web, worker and cron services all build
# from this file and must run the same Mautic release against one schema; and
# 7.1.3 — which `latest` currently points at — is unusable. Its image was built
# on 2026-07-07, four days after Twig 3.28.0 changed include() to return a
# Twig\Markup, while Mautic's OverrideIncludeExtension still declared a `string`
# return type, so every page render dies with a TypeError and a 500. Upstream
# has since widened the type to `string|Markup`; lift this pin to the first
# release that carries that fix. 7.1.2 is the newest release without the bug and
# is itself the security release (CVE-2026-4776, CVE-2026-9557) — 7.1.3 added
# only bug fixes and no migrations, so nothing security-related is given up.
ARG MAUTIC_TAG=7.1.2-apache
FROM mautic/mautic:${MAUTIC_TAG}

COPY --chmod=755 railway-entrypoint.sh /railway-entrypoint.sh

# The upstream image already runs as root and drops to www-data itself; the
# entrypoint needs root to chown the volume and normalise the Apache config.
USER root

ENTRYPOINT ["/railway-entrypoint.sh"]
