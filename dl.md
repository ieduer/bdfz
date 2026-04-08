# dl.sh / xz.bdfz.net

`dl.sh` is the standalone installer for the `xz.bdfz.net` yt-dlp web frontend.

## Production target

- Host: `JP 45.129.9.245`
- Service: `ytweb.service`
- App path: `/opt/ytweb`
- Download path: `/var/www/yt-downloads`
- Public URL: `https://xz.bdfz.net/`

## 2026-04-08 hardening

This installer was updated on `2026-04-08` after X/Twitter downloads started failing with:

```text
Impersonate target "chrome" is not available
```

Root cause:

- `yt-dlp 2026.03.17` needs a compatible `curl_cffi` build for `--impersonate chrome`
- `curl_cffi 0.15.x` is not accepted by this yt-dlp release
- `ffmpeg` was missing on the production host

What `dl.sh` now guarantees:

- installs `ffmpeg`
- pins `curl-cffi>=0.14,<0.15`
- verifies `yt-dlp --list-impersonate-targets` contains `Chrome`
- exposes `/healthz`
- installs `/usr/local/sbin/check-ytweb.sh` and `/etc/cron.d/ytweb-healthcheck`

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ieduer/bdfz/main/dl.sh)
```

## Post-install verification

```bash
systemctl status ytweb.service --no-pager
curl -fsS http://127.0.0.1:5001/healthz
/opt/ytweb/venv/bin/yt-dlp --list-impersonate-targets | grep '^Chrome'
ffmpeg -version | head -n 1
curl -fsSI https://xz.bdfz.net/
```

Optional smoke test:

```bash
/opt/ytweb/venv/bin/yt-dlp --impersonate chrome --simulate --print title "https://x.com/ThoNg676733/status/2026220564310823317?s=20"
```
