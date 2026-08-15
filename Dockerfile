# Mautic on Railway.
#
# The upstream image is used as-is; everything here is a thin boot-time wrapper that
# adapts it to Railway's constraints:
#
#   * Railway volumes are 1:1 with a service, and upstream's compose shares one
#     config/media mount across the web, cron and worker containers. This wrapper
#     renders Mautic's local.php from environment variables in every role instead,
#     so the three services agree on configuration without a shared filesystem.
#   * php:*-apache images currently boot with mpm_event/mpm_worker enabled alongside
#     the mpm_prefork that mod_php requires; that has to be normalised in the running
#     container, not in a build layer.
#   * A template deploy has no manual steps, so first boot installs the schema and the
#     admin user non-interactively rather than leaving Mautic's web wizard to a human.
#
# The tag is pinned because the web, cron and worker services build this file
# independently: `latest` could resolve to different Mautic builds per service.
FROM mautic/mautic:7.1.3-apache

COPY --chmod=755 railway-entrypoint.sh /railway-entrypoint.sh
COPY --chmod=755 render-local-config.php /render-local-config.php

# The base image already runs as root and its own entrypoint chowns the data
# directories to www-data before dropping to that user for every PHP process.
USER root

ENTRYPOINT ["/railway-entrypoint.sh"]
