# Monitoring the Optiplex from the outside

Two layers, both open source and without an account (decided in the Backup and monitoring ticket):

1. **Self-hosted, on the Optiplex**: ntfy (`https://ntfy.nnik.dev`, push to the Android app) and healthchecks
   (`http://healthchecks.opti.plex`, LAN only). Failed systemd units (`notify-failure@`), smartd, the nightly
   Backup and the weekly check, the LAN probes of Paperless and Home Assistant, and a five-minute "no failed
   unit" heartbeat report through them (`machines/optiplex/services/{ntfy,healthchecks,restic}.nix`).
2. **The phone**, for when the Optiplex itself is down (power cut, dead disk, router): an open-source
   monitoring app that probes the public sites. When the host is down these probes fail and the phone
   alerts; healthchecks, which lives on the host, cannot. A down host after a power cut is also the
   signal to unlock the initrd over SSH from the LAN (port 2222).

## The phone app

Install **Website Monitor** or **Nightbell** from F-Droid (both are open source and need no account). Pick
one at setup. Exempt the app from Android's battery optimisation, or checks are delayed (known limit).
Also subscribe the ntfy app to `https://ntfy.nnik.dev`, topic `optiplex`, user `yannik` (password in
Vaultwarden).

## The probes

Public sites only. Each must answer over IPv4 and IPv6 (every public service has an AAAA record).

| Name | URL | Expect |
|---|---|---|
| Matrix client | `https://nnik.dev/_matrix/client/versions` | 200 |
| Matrix federation | `https://nnik.dev:8448/_matrix/federation/v1/version` | 200 |
| Gitea | `https://git.nnik.dev/api/healthz` | 200 |
| Vaultwarden | `https://pw.nnik.dev/alive` | 200 |
| Seafile | `https://filesync.nnik.dev/api2/ping/` | 200 (`"pong"`) |
| etesync | `https://etesync.nnik.dev/` | not 5xx |
| etesync-dav | `https://dav.nnik.dev/` | 401 or 2xx (not 5xx) |
| ntfy | `https://ntfy.nnik.dev/v1/health` | 200 |

Check every URL against the running service before saving it. Paperless, Home Assistant, transmission and
healthchecks are LAN only and are not probed from outside: healthchecks watches Paperless and Home
Assistant from the LAN (`lan-paperless`, `lan-homeassistant`).

If the app can pin the address family, add one IPv6 probe, for example Gitea over IPv6.

## What alerts where

| Event | Channel |
|---|---|
| A systemd unit fails, smartd finds a problem | ntfy push (from the host, over loopback) |
| The nightly Backup fails | ntfy push (unit failure) |
| The nightly Backup is missing (host down, timer broken) | healthchecks `backup-nightly` (period 1 day, grace 3 h), then ntfy |
| The weekly check is missing | healthchecks `backup-check` (7 days, grace 1 day), then ntfy |
| Paperless or Home Assistant do not answer | healthchecks `lan-paperless` / `lan-homeassistant` (5 min, grace 10 min), then ntfy |
| Some unit stays failed | healthchecks `units-ok` (5 min, grace 10 min), then ntfy |
| The host or a public site is down | the phone app's own alert (healthchecks and ntfy are down with the host) |

## One-time steps on the host (after the first deploy)

```sh
healthchecks-manage createsuperuser            # email + password (password to Vaultwarden)
sudo systemctl start healthchecks-ensure       # ping key, ntfy integration and the five checks (also runs daily)
```

Log in at `http://healthchecks.opti.plex` from the LAN, confirm the project shows the ntfy integration and the
checks. Nothing else to click: the ping key and the publisher token come from sops.
