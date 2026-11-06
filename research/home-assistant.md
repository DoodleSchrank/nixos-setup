# Research: Home Assistant container → NixOS `services.home-assistant`

Ticket: `.scratch/optiplex-nixos-migration/issues/07-research-home-assistant.md` (map: Optiplex → NixOS).
Researched 2026-11-06. nixpkgs sources are cited at master commit
[`0734212`](https://github.com/NixOS/nixpkgs/tree/0734212d269c1ccfb74ab571b930b3a210555680). Home Assistant core is cited at tag
[`2026.10.4`](https://github.com/home-assistant/core/tree/2026.10.4), the version packaged there.

Abbreviations used below:

- `MOD` = [`nixos/modules/services/home-automation/home-assistant.nix`](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix)
- `PKG` = [`pkgs/servers/home-assistant/default.nix`](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/default.nix)
- `TEST` = [`nixos/tests/home-assistant.nix`](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/tests/home-assistant.nix)

## Question

What does moving Home Assistant from the `ghcr.io/home-assistant/home-assistant:stable` container (config in
`/srv/homeassistant`, uses `/run/dbus`, go2rtc on :18555, port 8123) to NixOS `services.home-assistant` involve?
Cover: how existing UI-configured integrations and `.storage` carry over, `extraComponents` discovery, custom
components / HACS, go2rtc, Bluetooth via dbus, and known pitfalls.

## Short answer

- **State carries over by copying the config directory.** UI-configured integrations, auth, and the device and entity registries all live in `.storage/`. The native service runs `hass --config <configDir>` as user `hass`. Copy `/srv/homeassistant` (457 MB, mostly a 406 MB log) to `configDir` and `chown -R hass:hass` it. The container wrote everything as root.
- **Version trap:** the container runs **2026.5.1** today. nixpkgs master and both unstable channels ship **2026.10.4**. This repo's committed `flake.lock` pins nixpkgs from **March 2025**, which ships **HA 2025.3.0**. Deploying with that lock would start a newer `.storage` on an older HA. Update the lock before the Cutover.
- **`extraComponents` are not discovered from `.storage`.** The module adds Python dependencies only for domains named in the Nix `config`, `extraComponents`, the default integrations, or `customComponents`. pip is disabled (`--skip-pip`), so every UI-added integration must be listed. For the Optiplex that is `tplink`, `cast`, `heos`, `met`, `bluetooth`, `group`, `mobile_app`, `sun`, `backup`, `shopping_list`, `radio_browser`, `google_translate`, plus the module defaults `default_config`, `met` and `esphome`.
- **`configuration.yaml` changes owner.** Unless `services.home-assistant.config = null`, the module replaces `configuration.yaml` with a symlink to a Nix-generated file on every start. The current file is small and translates easily. Drop its `http:` block: HA ≥ 2026.8 moves HTTP settings into the UI (`.storage/http` already holds them).
- **Custom components:** two are installed, HACS 2.0.5 and `ble_adv` v2.2.0 (NicoIIT). Neither is packaged in nixpkgs. They can stay as plain directories, because the module removes only symlinks that point into `/nix/store`. Their Python dependencies must come from Nix, since pip is off: `aiogithubapi`, `pycryptodome` and `btsocket`. All three exist in nixpkgs. The alternative is to package `ble_adv` with `buildHomeAssistantComponent` and drop HACS.
- **go2rtc can be dropped.** HA starts its bundled go2rtc only when it detects a container. On a native install, `default_config` without an explicit `go2rtc.url` silently removes the go2rtc entry. The Optiplex has **no camera entities**, so nothing uses go2rtc. If cameras come later, run `services.go2rtc` and set `go2rtc.url`.
- **Bluetooth works natively in principle.** `default_config` triggers the module to grant `CAP_NET_ADMIN`, `CAP_NET_RAW` and `AF_BLUETOOTH`. That is what HA's Bluetooth integration and `ble_adv`'s raw HCI and mgmt sockets need. The host needs `hardware.bluetooth.enable = true` (BlueZ). NixOS already defaults to dbus-broker, which HA recommends.
- **Bluetooth caveat:** the adapter is a TP-Link UB500, which HA lists as "unsupported" for active connections. `ble_adv` only advertises and listens, so this probably matters less. A VM test can't cover Bluetooth, so check it on the real hardware after the Cutover.
- **Other pitfalls:**
  - Caddy needs to be in `trusted_proxies`, including `::1` if it dials `localhost`.
  - The NixOS firewall may drop mDNS/SSDP discovery that the host-network container saw.
  - Two unreachable Tapo bulbs flood the log, which is why it is 406 MB.
  - Upstream does not support this install method. Issues go to nixpkgs first.

## Details

### What runs today (read-only inspection of `ssh optiplex`, 2026-11-06)

- Container `homeassistant`, image `ghcr.io/home-assistant/home-assistant:stable`, image version label `2026.5.1` (built 2026-05-08). `.HA_VERSION` = `2026.5.1`. It runs with `network_mode: host` and `privileged: true`. Mounts: `/srv/homeassistant:/config`, `/etc/localtime:ro`, `/run/dbus:/run/dbus:ro`. Restart policy is `unless-stopped`.
- `/srv/homeassistant` is 457 MB. `home-assistant.log` alone is 406 MB. The SQLite recorder DB `home-assistant_v2.db` is 6.7 MB, plus its WAL. `deps/` is empty, and there is no `www/` and no `themes/` dir. `secrets.yaml` exists but `configuration.yaml` never references `!secret`.
- `configuration.yaml`: `default_config:`, `frontend.themes: !include_dir_merge_named themes`, `automation/script/scene: !include …`, `http: { use_x_forwarded_for: true, trusted_proxies: [127.0.0.1] }`.
- Config entry domains in `.storage/core.config_entries`:
  - `sun`, `go2rtc` (system), `backup` (system)
  - `cast`, `heos` (zeroconf)
  - `shopping_list`, `radio_browser`, `google_translate`, `met` (onboarding)
  - `bluetooth`, `hacs`, `ble_adv`, `group`, `mobile_app`
  - `tplink` ×7
- Enabled entities by platform: tplink (48), sun, backup, ble_adv (light, switch, event), cast, heos, met, mobile_app, group, google_translate (tts), shopping_list, 3 scenes. There are **no `camera.*` entities**.
- Devices: TP-Link L430C/L530/L920 bulbs and strips, a Marantz PM7000N (HEOS), an NVIDIA Shield (Cast), a Pixel 6a (mobile_app), a "lampsmart_pro_v1" (ble_adv), and the adapter "TP-Link UB500 Adapter (2357:0604)". `/sys/class/bluetooth/hci0` exists and host `bluetooth.service` is active.
- `custom_components/`: `hacs` (manifest 2.0.5, requires `aiogithubapi>=22.10.1`) and `ble_adv` (manifest v2.2.0, requires `pycryptodome` and `btsocket`, `after_dependencies: esphome`). HACS lists only those two repositories as installed.
- Listening ports: TCP `*:8123`, TCP `*:18555` (`/bin/go2rtc` spawned by HA with a temp config), UDP 5353 and 1900.
- Reverse proxy today: nginx vhost `homeassistant.opti.plex` → `http://localhost:8123/` with WebSocket upgrade headers and `X-Forwarded-For`, LAN-only (`allow 192.168.178.0/24`).
- Log noise: about 500 `ERROR [kasa.smart.smartdevice]` lines per 300 KB of log tail, from 192.168.178.24 and .34 (`Connect call failed … No route to host`). There are also periodic `ble_adv.adapters` "HCI Adapter error: Socket closed by peer" warnings.

### The NixOS module in brief

- The service runs `hass --config ${configDir}` as user and group `hass`. `configDir` defaults to `/var/lib/hass`, and the module creates the `hass` user with that directory as its home. Sources: [MOD L348-352](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L348-L352), [L1005-1018](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1005-L1018), [L1121-1128](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1121-L1128)
- The unit is heavily sandboxed ([MOD L1026-1105](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1026-L1105)):
  - `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`
  - `ReadWritePaths` limited to `configDir` and any `homeassistant.allowlist_external_dirs`
  - `UMask=0077`, `DevicePolicy=closed`
  - `RestrictAddressFamilies` limited to INET, INET6, NETLINK and UNIX, plus `AF_BLUETOOTH` and `AF_PACKET` depending on the components in use
- The upstream project does not support this installation method. The option description says to "file issues against nixpkgs first". Source: [MOD L322-337](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L322-L337)
- Version: nixpkgs master packages `hassVersion = "2026.10.4"` on Python 3.14 ([PKG L135, L155-166](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/default.nix#L135-L166)). The `nixos-unstable` and `nixpkgs-unstable` branches carry the same version as of today. Sources: [nixos-unstable](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/servers/home-assistant/default.nix), [nixpkgs-unstable](https://github.com/NixOS/nixpkgs/blob/nixpkgs-unstable/pkgs/servers/home-assistant/default.nix)
- **This repo's `flake.lock`** pins nixpkgs `de0fe30` (lastModified 2025-03-07). That revision packages [`hassVersion = "2025.3.0"`](https://github.com/NixOS/nixpkgs/blob/de0fe301211c267807afd11b12613f5511ff7433/pkgs/servers/home-assistant/default.nix).
- HA records `.HA_VERSION` in the config dir and runs upgrade steps when it starts on a newer version. Source: [`homeassistant/config.py` `process_ha_config_upgrade`](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/config.py#L287-L340)
- Inference: going forward from 2026.5.1 to 2026.10.x is the normal upgrade path. Starting `.storage` written by 2026.5 on 2025.3 is not an upgrade path HA has code for. The Arch Rollback image keeps the original 2026.5 State in any case.

### How UI-configured integrations and `.storage` carry over

- Everything HA knows about UI-configured integrations lives in the config directory: `.storage/core.config_entries`, `core.device_registry`, `core.entity_registry`, `auth`, `http`, the recorder DB, and so on. The native service reads exactly the directory given by `--config` ([MOD L1005-1012](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1005-L1012)). So the restore is a copy of the whole directory:
  1. Stop the container. HA holds the SQLite DB open, and the recorder DB has a live `-wal` file.
  2. Copy `/srv/homeassistant/` to the new `configDir`. Optionally leave out `home-assistant.log*`, `.ha_run.lock`, `.cache`, the empty `deps/`, and `tts/` (a cache).
  3. `chown -R hass:hass` the copy. The container ran as root (`privileged`, files are `root:root`), while the native service runs as the `hass` system user with `UMask=0077` ([MOD L1016-1017, L1105](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1016-L1105)).
- `configDir` location: point `services.home-assistant.configDir` at wherever ticket 03 (data placement) puts it, or restore into `/var/lib/hass`. `ReadWritePaths` follows `configDir` automatically ([MOD L1059-1070](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1059-L1070)).
- `configuration.yaml` ownership ([MOD L512-676](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L512-L676), [L679-690](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L679-L690), [L886-897](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L886-L897)):
  - The docs for `services.home-assistant.config` say: "Unless this option is explicitly set to `null` we assume your `configuration.yaml` is managed through this module and thereby overwritten on startup."
  - In `preStart` the module runs `rm -f configuration.yaml` and symlinks `/etc/home-assistant/configuration.yaml`.
  - With `configWritable = true` it copies the file instead, but that copy is still overwritten on every start.
  - YAML tags such as `!include automations.yaml` and `!include_dir_merge_named themes` can be written as Nix strings. The renderer unquotes strings that start with `!` ([MOD L55-68](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L55-L68)). `automations.yaml`, `scenes.yaml` and `scripts.yaml` stay as State files in `configDir`, and the UI editors keep writing to them.
  - `config.homeassistant.time_zone` defaults to `config.time.timeZone` ([MOD L578-588](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L578-L588)). If the host sets `time.timeZone`, the generated YAML therefore contains a `homeassistant:` block. Inference: YAML-provided core settings take precedence over the UI-stored ones in `.storage/core.config`, so the time zone becomes fixed by Nix.
- The `http:` block: since HA 2026.8 the HTTP integration is configured in the UI. On the first start after upgrading, the existing `http:` YAML is imported and a Repair asks you to remove it from `configuration.yaml` ([home-assistant.io: HTTP → Migrating from YAML](https://www.home-assistant.io/integrations/http/#migrating-from-yaml)). The Optiplex's `.storage/http` already contains `use_x_forwarded_for: true` and `trusted_proxies: [127.0.0.1]`. Inference: the Nix `config` can leave out `http` entirely and keep those settings in the UI.

### `extraComponents` discovery

- The module decides which integrations get their Python dependencies baked in with `useComponent` ([MOD L111-123](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L111-L123)). A domain counts as used if it is any of:
  - a top-level key in the Nix `config`
  - a `platform = "…"` value inside it
  - in the package's `extraComponents`
  - in `services.home-assistant.extraComponents`
  - in `defaultIntegrations`
  - a `customComponents` domain

  The module **does not read `.storage`**, so integrations added through the UI are invisible to it.
- The package is wrapped with `--skip-pip` by default ([PKG L27-28, L299-302](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/default.nix#L27-L302)). With `skip_pip`, HA skips requirement processing entirely ([`requirements.py` L163-164](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/requirements.py#L160-L165)). An integration whose Python libraries are missing from the Nix environment therefore fails to import instead of being pip-installed.
- The `extraComponents` default is `[ "default_config" "met" "esphome" ]` ([MOD L393-421](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L393-L421)). Setting the option replaces that default, so re-add those three. Valid names are the keys of the generated [`component-packages.nix`](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/component-packages.nix), whose type is `types.enum availableComponents`, so typos fail at eval time.
- A practical discovery method, read-only on the old host, is the union of:
  - (a) the `domain` values in `.storage/core.config_entries`
  - (b) the top-level keys of `configuration.yaml`
  - (c) the `requirements` of each `custom_components/*/manifest.json`, which go into `extraPackages`, not `extraComponents`
- For the Optiplex this gives:

  ```nix
  extraComponents = [
    "default_config" "met" "esphome"            # module defaults (esphome: ble_adv after_dependency)
    "tplink" "cast" "heos" "bluetooth" "group" "mobile_app"
    "sun" "backup" "shopping_list" "radio_browser" "google_translate"
  ];
  extraPackages = ps: with ps; [ aiogithubapi pycryptodome btsocket ];  # hacs + ble_adv
  ```

  - `default_config` pulls in the dependencies of its own sub-integrations: assist_pipeline, bluetooth, cloud, dhcp, go2rtc, mobile_app, ssdp, stream, usb, zeroconf, and others. Sources: [core `default_config/manifest.json`](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/default_config/manifest.json), [component-packages.nix `default_config`](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/component-packages.nix#L1362)
  - `aiogithubapi`, `pycryptodome` and `btsocket` all exist as nixpkgs Python packages: [aiogithubapi](https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/python-modules/aiogithubapi), [pycryptodome](https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/python-modules/pycryptodome), [btsocket](https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/python-modules/btsocket). `aiogithubapi` is also what HA's built-in `github` integration uses ([component-packages.nix L2450-2453](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/component-packages.nix#L2450-L2453)).
- The upstream NixOS VM test exercises this pattern: `extraComponents`, `extraPackages`, `customComponents`, and an explicit `default_config` equivalent ([TEST L33-115](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/tests/home-assistant.nix#L33-L115)).

### Custom components and HACS

- nixpkgs packages custom components under `pkgs.home-assistant-custom-components` (122 entries today) and builds them with `buildHomeAssistantComponent`. Neither `hacs` nor `ble_adv` is among them. Sources: [custom-components dir](https://github.com/NixOS/nixpkgs/tree/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/custom-components), [packaging README](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/custom-components/README.md), [builder](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/build-custom-component/default.nix)
- `buildHomeAssistantComponent` takes `owner`, `domain`, `version` and `dependencies`. A manifest check hook verifies that the `manifest.json` requirements are satisfied. Dependencies must come from `home-assistant.python3Packages` (README above).
- How the module installs `customComponents` ([MOD L918-936](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L918-L936)):
  - In `preStart` it deletes only symlinks in `custom_components/` that point into `/nix/store`.
  - It then `ln -fns`-es each packaged component's directory into `custom_components/`.
  - It also adds each package's `propagatedBuildInputs` to the HA environment ([MOD L130-134](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L125-L136)).
  - Consequences:
    - Plain directories such as today's `custom_components/hacs` and `custom_components/ble_adv` are left alone. HACS can keep managing them in the writable `configDir`.
    - Switching a component from a plain directory to Nix-managed requires deleting the old directory first. Inference: `ln` will not replace a real directory with a symlink.
- HACS on a pip-less HA: HACS's own manifest requires `aiogithubapi`. Any integration HACS downloads later also gets its `requirements` from pip, which `--skip-pip` disables. Each new HACS integration with Python requirements therefore needs a matching `extraPackages` entry and a rebuild. HACS still works for pure-Python integrations and frontend cards. This is an inference from the `skip_pip` code path and HACS's manifest (see above).
- `ble_adv` facts from [README v2.2.0](https://github.com/NicoIIT/ha-ble-adv/blob/v2.2.0/README.md):
  - It needs HA ≥ 2025.2.4 and HACS ≥ 2.0.1. It talks to the host Bluetooth adapter, or to an ESPHome `ble_adv_proxy`.
  - It uses **raw HCI sockets** (`SOCK_RAW`, `BTPROTO_HCI`) plus the BlueZ **mgmt** API, because BlueZ over D-Bus cannot send its non-standard advertisements ([adapters/__init__.py](https://github.com/NicoIIT/ha-ble-adv/blob/v2.2.0/custom_components/ble_adv/adapters/__init__.py), [wiki: non-root installs](https://github.com/NicoIIT/ha-ble-adv/wiki/Workaround-for-HA-non-'network_mode:-host'-or-non-root-installations)).
  - The author's container guidance is "root or privileged" plus host networking. Natively this maps to the `CAP_NET_ADMIN`/`CAP_NET_RAW` ambient capabilities and `AF_BLUETOOTH`, which the module grants (next section).

### go2rtc

- In the container, HA starts `/bin/go2rtc` itself with WebRTC on `:18555/tcp` and RTSP on `127.0.0.1:18554` ([core go2rtc/server.py L32-58](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/go2rtc/server.py#L32-L58)). That explains the :18555 listener.
- HA only does this when `is_docker_env()` is true: `/.dockerenv` exists, or similar. Otherwise ([core go2rtc/__init__.py L124-150](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/go2rtc/__init__.py#L124-L150), [`util/package.py` `is_docker_env`](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/util/package.py#L39-L46)):
  - With only `default_config` and no explicit `go2rtc:`, HA **removes the go2rtc config entry** and continues.
  - With `go2rtc:` but no `url`, HA logs "Go2rtc URL required in non-docker installs".
- So on NixOS the native pattern is a separate `services.go2rtc` ([nixpkgs module](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/video/go2rtc/default.nix)) plus `config.go2rtc.url = "http://127.0.0.1:1984"`. The nixpkgs test comments out `go2rtc` as "Requires go2rtc service" ([TEST L99-100](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/tests/home-assistant.nix#L99-L100)). The module also puts `pkgs.go2rtc` on the unit's `PATH` when the `go2rtc` component is used ([MOD L1109](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1109)), but HA won't spawn it outside a container.
- go2rtc only provides WebRTC streaming for camera entities. The Optiplex has **no camera entities** (registry inspection above), so dropping go2rtc loses nothing today. HA's recommended go2rtc version is pinned in core ([`go2rtc/const.py` `RECOMMENDED_VERSION = "1.9.14"`](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/go2rtc/const.py)). Keep that in mind if `services.go2rtc` is added later.

### Bluetooth via D-Bus

- HA's Linux requirements ([home-assistant.io Bluetooth: Requirements for Linux systems](https://www.home-assistant.io/integrations/bluetooth/#requirements-for-linux-systems), [source](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/bluetooth.markdown)):
  - The D-Bus socket must be reachable.
  - BlueZ ≥ 5.43, with ≥ 5.63 recommended.
  - The D-Bus implementation "should be dbus-broker".
  - Kernel ≥ 5.15.62.
  - Without `NET_ADMIN` and `NET_RAW`, Bluetooth runs "degraded": no adapter recovery, missing raw advertisement data, and a "Missing required permissions" repair. The container got these through `--privileged`.
- NixOS mapping:
  - `hardware.bluetooth.enable = true` provides BlueZ and its D-Bus service. The upstream HA VM test sets it "required for dbus activation in the bluetooth component" ([TEST L30-31](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/tests/home-assistant.nix#L30-L31)).
  - `services.dbus.implementation` already defaults to `"broker"` ([nixpkgs dbus.nix L66-71](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/system/dbus.nix#L66-L71)).
  - The native service talks to the host system bus directly, so the `/run/dbus` bind mount has no equivalent.
  - When any component in `componentsUsingBluetooth` is used, the module adds `CAP_NET_ADMIN` and `CAP_NET_RAW` to `AmbientCapabilities`/`CapabilityBoundingSet` and `AF_BLUETOOTH` to `RestrictAddressFamilies`. That list includes `default_config`, `bluetooth` and `esphome` ([MOD L167-213](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L167-L213), [L972-1000](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L972-L1000), [L1071-1081](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1071-L1081)). Inference: those are the privileges `ble_adv`'s raw HCI and mgmt sockets need, so it should work without root. This is unverified until it runs on the hardware.
- Adapter: the Optiplex uses a **TP-Link UB500 (RTL8761BU)**. HA's docs list it under "Unsupported adapters" with "Frequent connection failures with active connections" ([bluetooth.markdown](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/bluetooth.markdown)). This is unchanged by the migration. The current log already shows periodic `ble_adv` "HCI Adapter error: Socket closed by peer" warnings.

### Other pitfalls

- **Reverse proxy (Caddy):**
  - HA blocks proxied requests unless "Trust X-Forwarded-For" is on and the proxy's address is in "Trusted proxies" ([home-assistant.io HTTP: Reverse proxies](https://www.home-assistant.io/integrations/http/#reverse-proxies)).
  - Today only `127.0.0.1` is trusted. Inference: if Caddy dials `localhost:8123` and resolves to `::1`, HA rejects it. Proxy to `127.0.0.1:8123` or add `::1`.
  - Caddy's `reverse_proxy` handles WebSocket upgrades itself, where nginx needed explicit `Upgrade` headers. That is general Caddy behaviour; confirm it in ticket 11.
- **Firewall and discovery:**
  - The container used host networking on Arch. The NixOS firewall is on by default.
  - `openFirewallForComponents` only opens ports for `homekit` and `sonos` ([MOD L846-856](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L846-L856)).
  - Inference: inbound multicast replies for zeroconf/mDNS (UDP 5353, used by `cast`/`heos` discovery) and SSDP (UDP 1900) may be dropped. Discovery-based device tracking could then degrade. `tplink` entries are stored by host IP.
  - Port 8123 does not need opening if only Caddy talks to HA.
- **Recorder DB:** today it is SQLite (`home-assistant_v2.db`, 6.7 MB) in the config dir. It carries over as a file. The map's "shared PostgreSQL" decision could also cover HA via `recorder.db_url` plus `psycopg2` in `extraPackages` ([home-assistant.io Recorder](https://www.home-assistant.io/integrations/recorder/), [MOD L423-441 example](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L423-L441)). Inference: HA has no built-in SQLite→PostgreSQL history migration, so switching means starting history fresh.
- **Log size:** HA writes `CONFIG/home-assistant.log` unless `--log-file` is given, and rotates daily only with `--log-rotate-days` ([core `__main__.py` L124-137](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/__main__.py#L124-L137)). Both can be passed through `services.home-assistant.extraArgs` ([MOD L339-346](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L339-L346)). Today's 406 MB log comes from two unreachable Tapo devices (192.168.178.24/.34).
- **Python 3.14:** custom components run on nixpkgs' Python 3.14 HA environment ([PKG L135, L166](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/default.nix#L135-L166)). The official container image ships its own Python. Inference: a custom component that pins old libraries could break. The two in use declare unpinned requirements.
- **Sandbox paths:** HA can write only inside `configDir` unless a path is listed in `homeassistant.allowlist_external_dirs` ([MOD L1059-1070](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix#L1059-L1070)). That includes the `backup` integration's default `backups/` directory. Relevant if Backup (ticket 13/17) wants HA backups written elsewhere.

## Options / trade-offs

1. **`configuration.yaml` management**
   - A. Nix-managed `config` (module default). Declarative and reviewable, and the file is regenerated every start. Requires translating the current yaml and keeping `automations/scenes/scripts.yaml` as `!include`d State. UI YAML edits are impossible.
   - B. `config = null`. The current `configuration.yaml` is restored as State and stays hand/UI-edited. Zero translation, but not declarative, and `extraComponents` must then be maintained fully by hand.
2. **Custom components**
   - A. Keep HACS and `ble_adv` as plain directories, add their Python dependencies via `extraPackages`. Least work and in-UI updates keep working. A HACS-installed integration with new requirements needs a Nix change, and versions aren't pinned in the flake.
   - B. Package `ble_adv` with `buildHomeAssistantComponent` in this repo and drop HACS. Fully reproducible, with versions in `flake.lock` or a fetcher hash, but updates mean editing Nix.
   - C. Hybrid: keep HACS for frontend cards only, and package `ble_adv`.
3. **go2rtc**
   - A. Drop it (no cameras today). Simplest.
   - B. Add `services.go2rtc` with `config.go2rtc.url`. Only worth it if cameras are planned.
4. **Recorder DB**
   - A. Keep SQLite in `configDir`. Carries over as-is, and the Backup must handle a live SQLite file.
   - B. Move to the shared PostgreSQL. Matches the map's database decision, but history starts fresh.
5. **configDir location**
   - A. `/var/lib/hass` (module default) on the System disk.
   - B. Keep a path on `/srv` or the Data disk via `configDir`. Ticket 03 decides. The state is small (~50 MB without the log).

## Open questions

- Will `ble_adv` work on the UB500 under the `hass` user with only ambient `CAP_NET_ADMIN`/`CAP_NET_RAW`? This can't be tested in a VM, so it needs verifying on the hardware at Cutover. If it fails, fall back to an ESPHome `ble_adv_proxy`.
- Does the NixOS firewall break `cast`/`heos` discovery or state updates? Check after Cutover. Open UDP 5353 and 1900 if needed.
- Should the two unreachable Tapo devices (192.168.178.24/.34) be removed in the UI before the migration to stop the log flood?
- Does `secrets.yaml` matter? Nothing references it today. If secrets get added later, sops-nix could template it.
- Which recorder backend and configDir location? This depends on the user's choice and tickets 03 and 10.
- Bumping `flake.lock` to a nixpkgs with HA ≥ 2026.5.1 is a prerequisite. Does the host-foundation ticket own it?

## Sources

- nixpkgs (master @ `0734212d`):
  - [HA NixOS module](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/home-automation/home-assistant.nix)
  - [HA package](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/default.nix)
  - [component-packages.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/component-packages.nix)
  - [custom components README](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/custom-components/README.md)
  - [buildHomeAssistantComponent](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/servers/home-assistant/build-custom-component/default.nix)
  - [NixOS HA VM test](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/tests/home-assistant.nix)
  - [go2rtc module](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/video/go2rtc/default.nix)
  - [dbus module](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/system/dbus.nix)
- nixpkgs at this repo's lock (`de0fe301`): [HA package 2025.3.0](https://github.com/NixOS/nixpkgs/blob/de0fe301211c267807afd11b12613f5511ff7433/pkgs/servers/home-assistant/default.nix)
- Home Assistant core 2026.10.4:
  - [go2rtc/__init__.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/go2rtc/__init__.py)
  - [go2rtc/server.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/go2rtc/server.py)
  - [go2rtc/const.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/go2rtc/const.py)
  - [default_config manifest](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/default_config/manifest.json)
  - [util/package.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/util/package.py)
  - [requirements.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/requirements.py)
  - [config.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/config.py)
  - [__main__.py](https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/__main__.py)
- home-assistant.io:
  - [Bluetooth](https://www.home-assistant.io/integrations/bluetooth/) ([markdown source](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/bluetooth.markdown))
  - [HTTP](https://www.home-assistant.io/integrations/http/) ([markdown source](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/http.markdown))
  - [Recorder](https://www.home-assistant.io/integrations/recorder/)
- ha-ble-adv: [README v2.2.0](https://github.com/NicoIIT/ha-ble-adv/blob/v2.2.0/README.md), [adapters source](https://github.com/NicoIIT/ha-ble-adv/blob/v2.2.0/custom_components/ble_adv/adapters/__init__.py), [non-root workaround wiki](https://github.com/NicoIIT/ha-ble-adv/wiki/Workaround-for-HA-non-'network_mode:-host'-or-non-root-installations)
- Live host: read-only `ssh optiplex` inspection on 2026-11-06 (`docker inspect`, `/srv/homeassistant` listing, config-entry domains, entity/device registry summaries, `ss`, nginx vhost). No secrets copied.
