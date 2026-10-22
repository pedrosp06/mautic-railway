# Mautic on Railway

A thin wrapper over the official [`mautic/mautic`](https://hub.docker.com/r/mautic/mautic)
image that makes Mautic deploy on Railway with no manual setup step.

One image serves all three Mautic roles; the role is selected per service with
`DOCKER_MAUTIC_ROLE` (`mautic_web`, `mautic_worker`, `mautic_cron`), exactly as
upstream's own compose files do.

## What the wrapper adds

| | Why |
|---|---|
| Apache MPM normalisation | Current `php:*-apache` images enable `mpm_event`/`mpm_worker` alongside the `mpm_prefork` that `mod_php` needs, and Apache aborts on *More than one MPM loaded*. It has to be redone at container start — the build's `/etc/apache2` is not what runs. |
| Apache listens on `$PORT` | Railway probes the port named by `PORT`. |
| One consolidated volume | Railway allows a service exactly one volume; the image wants `config`, `docroot/media` and `var/logs` persisted. They become symlinks into the single mount, seeded once from the image's own content. |
| `config/parameters_local.php` written at boot | `trusted_proxies`, HSTS and the secure-cookie decision are read from the config *files*, never from the environment. |
| Idempotent `mautic:install` | A template deploy has no manual steps. With `MAUTIC_ADMIN_EMAIL` and `MAUTIC_ADMIN_PASSWORD` set, the first boot installs Mautic and creates the admin; later boots detect the existing install and do nothing. Without them, Mautic's own web installer runs instead. |
| Worker and cron config from the environment | Those roles normally read the web service's shared config volume, which Railway cannot express. They build an equivalent config from their service variables and wait for the schema before starting. |

`trusted_proxies` deliberately trusts every hop. Railway's edge overwrites a
client-supplied `X-Forwarded-For` and appends its own entry, and that entry is a
public address that changes per request — trusting all hops is what makes
Symfony return the leftmost entry, which is the real client.

## Variables

Required on all three Mautic services:

| Variable | Notes |
|---|---|
| `DOCKER_MAUTIC_ROLE` | `mautic_web`, `mautic_worker` or `mautic_cron` |
| `MAUTIC_DB_HOST` `MAUTIC_DB_PORT` `MAUTIC_DB_DATABASE` `MAUTIC_DB_USER` `MAUTIC_DB_PASSWORD` | MySQL connection |
| `MAUTIC_SITE_URL` | Full public URL, including scheme |
| `MAUTIC_SECRET_KEY` | Must be identical on all three; it encrypts stored integration credentials |

Web service only:

| Variable | Notes |
|---|---|
| `PORT` | Port Apache listens on |
| `MAUTIC_ADMIN_EMAIL` `MAUTIC_ADMIN_PASSWORD` | First admin, used once on the first boot |
| `MAUTIC_ADMIN_USERNAME` `MAUTIC_ADMIN_FIRSTNAME` `MAUTIC_ADMIN_LASTNAME` | Optional, default `admin` / `Admin` / `User` |

Recommended on all three, to give the worker tier something to consume:

```
MAUTIC_MESSENGER_DSN_EMAIL=doctrine://default
MAUTIC_MESSENGER_DSN_HIT=doctrine://default
MAUTIC_MESSENGER_DSN_FAILED=doctrine://default?queue_name=failed
MAUTIC_MAILER_DSN=smtp://<your mail host>:<port>
```

Left unset, the messenger DSNs default to `sync://` and email is sent inside the
web request instead of by the worker.

Any other Mautic setting can be supplied the same way: the parameter `foo_bar`
is read from `MAUTIC_FOO_BAR`, and an environment variable wins over the value
stored in `config/local.php`.

## Bounces e reclamações via SNS

A imagem inclui `symfony/amazon-mailer` e o plugin
[`matbcvo/mautic-amazon-sns-callback`](https://github.com/matbcvo/mautic-amazon-sns-callback)
(Mautic 7), instalados no build em `docroot/plugins`. O entrypoint roda
`mautic:plugins:reload` e `cache:clear` como `www-data` a cada boot do serviço
web, então o plugin é registrado sem passo manual.

Variáveis (todas as três, web/worker/cron — nunca versione o valor):

```
MAUTIC_MAILER_DSN=ses+smtp://USUARIO:SENHA_URL_ENCODED@default?region=sa-east-1
```

Use as **credenciais SMTP do SES** (geradas em *SES → SMTP settings → Create
SMTP credentials*), não chaves de API/IAM. A senha SMTP deve ir URL-encoded no
DSN (`+`, `/` e `=` precisam ser codificados). Troque `sa-east-1` pela região
do seu SES.

O `smtp://host:porta` genérico continua funcionando como fallback para enviar
e-mail, mas só `ses+smtp` (também aceitos pelo plugin: `ses+api`, `ses+https`)
identifica a mensagem como SES para o tratamento de bounces e reclamações.

Rota de callback: `POST https://<MAUTIC_SITE_URL>/mailer/callback`

Passo a passo no AWS:

1. **SES → Identities → sua identidade → Notifications**: configure *Feedback
   notifications* (Bounce e Complaint) apontando para um tópico SNS, e desligue
   *Include original headers* se não precisar deles.
2. **SNS → Topics → Create topic** (tipo Standard), ou use o tópico do passo 1.
3. No tópico: **Create subscription** → Protocol `HTTPS` → Endpoint
   `https://<seu-dominio>/mailer/callback`.
4. O plugin confirma a inscrição automaticamente; o status deve virar
   *Confirmed*. Se ficar *Pending*, veja `var/logs` do serviço web.
5. Teste enviando para `bounce@simulator.amazonses.com` e
   `complaint@simulator.amazonses.com`; o contato deve ficar como *Do Not
   Contact* em Mautic.

O endpoint precisa ser publicamente acessível (sem autenticação e sem bloqueio
de firewall/WAF) para o SNS.

## Version

The base tag is pinned in the `Dockerfile`. Web, worker and cron all build from
this repository and run migrations against one schema, so they must resolve to
the same Mautic release; a floating tag lets a redeploy of one service land on a
different build from the other two.

The pin is also holding back one release. `mautic/mautic:7.1.3-apache`, which
`latest` points at, was built four days after Twig 3.28.0 changed `include()` to
return a `Twig\Markup` — Mautic's `OverrideIncludeExtension` still declared a
`string` return type, so every page render throws a `TypeError` and returns 500.
Upstream widened the type after 7.1.3 shipped; the pin can move to the first
release carrying that fix. 7.1.2 gives up only bug fixes: it is itself the
security release, and no migrations changed between the two.
Novo deploy.