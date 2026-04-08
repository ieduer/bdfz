# dl.sh memory

- Domain: `xz.bdfz.net`
- Host: `JP 45.129.9.245`
- Service: `ytweb.service`
- App path: `/opt/ytweb`
- Health endpoint: `http://127.0.0.1:5001/healthz`

## Operational invariants

- `x.com` / `twitter.com` downloads depend on `--impersonate chrome`
- For the validated runtime, keep `curl-cffi>=0.14,<0.15`
- `ffmpeg` must exist, otherwise muxed/best-format downloads degrade
- Cron healthcheck should be managed by `/etc/cron.d/ytweb-healthcheck`
- `dl.sh` must remain standalone because the repo install path is `curl | bash`
