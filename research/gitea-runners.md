# Gitea Actions runners without Docker on the Optiplex

Research for ticket 06 of the Optiplex migration map (`.scratch/optiplex-nixos-migration/issues/06-research-gitea-runners.md`).
Researched 2026-11-08. Live facts come from read-only commands over `ssh optiplex` (`docker inspect`, `docker exec`, `psql` catalog queries, `git show` on the Gitea repositories). Sources were pinned at nixpkgs `nixos-unstable` @ `f9a75f41be3a` (2026-11-05), Gitea Runner `v5.4.1` @ `bb6d793cb984`, Gitea `main` @ `8cb6fb2001ba` and the `gitea/docs` repo @ `878c88505055`.

## Question

How can Gitea Actions runners (today: 3x `gitea/runner:4.0.0-dind-rootless` containers) run on NixOS with Docker removed? Cover:

- `services.gitea-actions-runner` and the runner's job execution backends: host executor, podman as a Docker-compatible socket, and nix-based labels.
- What the existing workflows (container jobs, `docker` steps) will need.
- The security trade-offs.
- How the native `services.gitea` module handles migrating from the official Docker image's `/data` layout and its PostgreSQL 14 database.

## Short answer

- **The runner is not tied to Docker.** A label `name:host` runs steps directly on the machine, and `name:docker://image` runs them in a container on any Docker-API daemon. Gitea Runner autodetects `/run/podman/podman.sock` and lists "`podman` with `podman.socket` enabled" as a supported prerequisite ([runner README][r-readme], [daemon.go L372-L378][r-daemon]). A job-level `container:` key forces container execution even under a `:host` label ([run_context.go L1249-L1283][r-rc]), so container jobs can never run on the host executor.
- **NixOS ships a module.** `services.gitea-actions-runner.instances.<name>` writes one systemd unit per instance (`gitea-runner-<name>`), registers it with a token file, and (for podman) sets `DOCKER_HOST=unix:///run/podman/podman.sock` and adds the `podman` group ([module L203-L332][nix-runner]). It asserts that `virtualisation.docker` or `virtualisation.podman` is on if any label is `docker://` ([L191-L193][nix-runner]). It is tested with one `native:host` runner and one podman runner ([nixos test][nix-runner-test]).
- **The module lags upstream.** nixos-unstable packages runner `3.1.0`, nixos-26.05 `1.0.3`, nixos-25.11 `0.2.13`, and this repo's pinned nixpkgs (Mar 2025) `0.2.11`. Upstream is at `5.4.1`, and the live runners are `4.0.0`. The binary was renamed `gitea-runner` ([package.nix][nix-runner-pkg]).
- **The existing workflows need a container backend, not just a host executor.** All 7 `ci.yml` jobs in `battle-tracker` use `container: image: git.nnik.dev/aitopia/flutter-ci[-android]:latest`. Four workflows (`build-flutter-ci`, `build-flutter-android-ci`, `deploy-web`, `sync-server-image`) use `container: docker:dind` with `options: --privileged` and start `dockerd` inside the job. Only `demo`/`factory` `ci.yml` and the three `pr-title-check.yml` files could run on a host executor.
- **The dind workflows work today only through a side channel.** The live runner config has `privileged: false`, which makes the runner ignore `--privileged` in a workflow ([docker_run.go L623-L627][r-dockerrun]). The jobs get their capabilities from `container.options` in the runner's own config (`SYS_ADMIN`, unconfined seccomp and so on). Any replacement must carry that over, or the workflows must change.
- **Podman as the backend is the closest drop-in, and it is root.** Rootful podman gives each job a real root container on the host kernel. The runner also mounts a proxied daemon socket into every job container by default ([run_context.go L389-L391][r-rc]). That proxy only adds labels and rewrites bind paths ([docker_proxy.go L370-L409][r-proxy]), so a job can ask podman for a privileged container with `/` mounted. The NixOS option text says the same of the `podman` group: "members of this group can gain root access" ([podman module][nix-podman]). Today's dind-rootless setup has the same exposure inside its own outer container, but not on the host.
- **The host executor is the best-contained option, but only for simple jobs.** The unit runs as a `DynamicUser` (implies `ProtectSystem=strict`, `ProtectHome=read-only`, `NoNewPrivileges`; [systemd.exec][sd-exec]). Default `hostPackages` has no `grep`, which the `pr-title-check.yml` workflows call ([module L152-L161][nix-runner]).
- **Gitea itself has a native module, but the `/data` layout does not map one to one.** The Docker image keeps `WORK_PATH` = `APP_DATA_PATH` = `/data/gitea`, repos in `/data/git/repositories`, LFS in `/data/git/lfs` and the OS user `git` ([Dockerfile, app.ini template][g-docker]). The NixOS module defaults to `/var/lib/gitea`, `custom/`, `data/`, `repositories/` and user `gitea`. It writes `app.ini` on every start from `settings` and reads secrets from files in `custom/conf/` ([gitea.nix L816-L903][nix-gitea]). The four live secrets (`SECRET_KEY`, `INTERNAL_TOKEN`, `LFS_JWT_SECRET`, `JWT_SECRET`) must be seeded into those files before the first start. `SECRET_KEY` also encrypts the 4 Actions repository secrets ([secret.go][g-secret]).
- **Version jump.** The live Gitea is `1.26.4`. nixos-unstable packages `28.3.0`, nixos-26.05 `1.27.3`. Upstream dropped the `1.` prefix at 28.0.0 and listed breaking changes, among them that `[server] DOMAIN` is no longer read ([28.0.0 post][g-blog-28]).

## Details

### 1. What exists today

All read-only over `ssh optiplex`.

**Runners.** `gitea_runners-factory_runner-{1,2,3}`, image `gitea/runner:4.0.0-dind-rootless`, from compose project `gitea_runners` (stack file under Portainer's `/data/compose/35`).

- The outer container runs `Privileged=true` with `apparmor=rootlesskit` and `label=disable`. It runs its own rootless `dockerd` (`DOCKER_HOST=unix:///run/user/1000/docker.sock`). The README says the rootless variant runs as UID 1000 and needs "rootless Docker support on the host" ([README][r-readme]).
- Registration: org-level for the Gitea organisation `aitopia` (`action_runner.owner_id = 2`, `repo_id = 0`). Runner ids 15-17 are the live ones. Ids 9-14 are stale earlier container incarnations. Ids 1-8 are stale `portainer-runner-0x` rows from the retired Portainer runners (ids 1-3 instance-level, 4-8 repo-level on `battle-tracker`). The registration token is passed as `GITEA_RUNNER_REGISTRATION_TOKEN` in the container environment. It is not reproduced here.
- Labels: `ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest` and `ubuntu-24.04:docker://docker.gitea.com/runner-images:ubuntu-24.04`.
- Config (`/config.yaml`): `capacity: 2` (6 concurrent jobs in total on 12 CPUs, 15 GB RAM), `timeout: 3h`, `cache` enabled at `/data/cache` (`size_limit 20GB`), `tool_cache_mode: none`, `health_check.enabled` with `min_free_disk_space_mb: 5120`, `container.privileged: false`, `container.require_docker: true`, `container.network: ""`, and this `container.options`:
  `--security-opt seccomp=unconfined --security-opt systempaths=unconfined --cap-add=SYS_ADMIN --cap-add=SYS_CHROOT --cap-add=NET_ADMIN --cap-add=SETUID --cap-add=SETGID --cap-add=SYS_PTRACE`.
- Disk: runner 1's inner Docker image cache (`/home/rootless/.local/share/docker`) is 22 GB on the Data disk. Runners 2 and 3 are comparable in kind. The `/data` volumes with `.runner` and cache are tiny.
- Runner URL: `https://git.nnik.dev` (the public name, resolved from the same host, and that works today).

**Activity** (Gitea database `gitea`, PostgreSQL 14):

- 3138 runs since 2026-06-25, 916 in the last 30 days. Per repo: `AItopia/battle-tracker` 2242, `AItopia/factory` 873, `AItopia/demo` 23. 7754 jobs, all `runs-on: ubuntu-latest`. Average job duration over 30 days: about 79 s (max 344 s).
- Repositories: `demo`, `matrix-db-converter` (no workflows), `battle-tracker` (21 MB), `factory` (35 MB), all public (`is_private = f`). Workflows live in `.gitea/workflows/` on the default branch.
- Actions secrets: 4, all on repo 1 (`battle-tracker`): `REGISTRY_USER`, `REGISTRY_TOKEN`, `BT_SYNC_BASE_URL`, `PORTAINER_WEBHOOK_URL`. No variables, artifacts or schedules.
- Container registry: 4 container packages (`flutter-ci`, `flutter-android-ci`, `battle-tracker-web`, `bt-sync-server`), 347 blobs, 6.5 GB under `/data/gitea/packages`.

**Gitea.** `docker.gitea.com/gitea:latest` = Gitea `1.26.4` (Go 1.26.4), `gitea-db-1` = `postgres:14`, volumes `gitea_data` (`/data`) and `gitea_pgdata`. Ports: web `25579`, container sshd `22` published as `25580`. `app.ini` has `WORK_PATH`, `APP_DATA_PATH` and `GITEA_CUSTOM` all `/data/gitea`; `ROOT = /data/git/repositories`; `LFS PATH = /data/git/lfs`; `[database] HOST = db:5432`, `SSL_MODE = disable`; `INSTALL_LOCK`, `DISABLE_REGISTRATION = true`; secrets set inline. `/data/git` is 128 MB, `/data/gitea/actions_log` 78 MB, the Postgres volume 191 MB. `DOMAIN = git.nnik.dev` is set in `[server]`.

### 2. Runner backends

#### 2a. How the runner chooses

From the [README][r-readme]:

- A label is `<name>[:<schema>[:<args>]]`. `docker://<image>` runs the job in a container, `kubernetes://<image>` in a pod, `host` (the default) on the machine.
- Jobs that match no label run in `runner.default_image`, "or on the host when docker is unavailable".
- "Host jobs still need a Docker daemon for Docker actions and `docker://` steps."
- `git` 2.34.1 or newer is needed on the host. `node` is needed for JavaScript actions and `hashFiles()`. `bash` or `sh` too.
- Unlike GitHub, host jobs start no `services:`; give them a `container:` to get services.

In code, a job runs on the host only when it has no job-level `container.image` *and* its platform is the `-self-hosted` pseudo-image ([run_context.go L1281-L1283][r-rc]). A job-level `container:` therefore always starts a container ([L1249-L1258][r-rc]).

#### 2b. Host executor (`native:host`)

- NixOS module: `labels = [ "native:host" ]` and `hostPackages` (default: `bash coreutils curl gawk gitMinimal gnused nodejs wget`) put on the unit's `PATH` ([L151-L161, L251-L256][nix-runner]). The option text warns: "Many common actions require bash, git and nodejs, as well as a filesystem that follows the filesystem hierarchy standard" ([L125-L127][nix-runner]).
- **Sandboxing.** The unit uses `DynamicUser = true`, `StateDirectory = gitea-runner/<name>`, and `HOME = /var/lib/gitea-runner/<name>`. `DynamicUser` implies `RemoveIPC`, a private `/tmp`, `NoNewPrivileges`, `RestrictSUIDSGID`, `ProtectSystem=strict` and `ProtectHome=read-only` ([systemd.exec][sd-exec]). Jobs can only write to the state directory and the private `/tmp`, so host mode is already a moderately confined unprivileged user. The module adds no further hardening. The job can still read world-readable files and reach every `localhost` service of the Optiplex.
- **Nix on the host.** `nix.settings.allowed-users` defaults to `[ "*" ]` ([nix.nix L385-L388][nix-nixconf]), so a dynamic user can use the Nix daemon. A host label with `nix` and `just`/`python3` in `hostPackages` is therefore a viable "nix-based" label. Anything from a pinned flake gives the job a reproducible toolchain, but only for jobs that don't need `container:`.
- **FHS binaries.** Prebuilt tools (for example `actions/setup-python`, the Flutter SDK that `install_just.sh` and the Flutter images pull in) will not start without a compatible loader. `programs.nix-ld` provides one ([nix-ld.nix][nix-ld]). I did not test whether the specific setup actions used here work with it.
- **Missing tools.** `grep` is not in the default `hostPackages`, and both `pr-title-check.yml` variants call it. `gitMinimal` lacks things such as `git-lfs` and `ssh`, which `builtin:checkout` needs for `lfs: true` and `ssh-key` ([README][r-readme]).

#### 2c. Podman as a Docker-compatible socket

- **Podman side.** `podman system service` serves a "compatibility layer offering support for the Docker v1.40 API" ([podman-system-service(1)][podman-svc]). The NixOS `virtualisation.podman` module creates the `podman` group, makes `podman.socket` group-owned by it, and with `dockerSocket.enable` symlinks `/run/docker.sock` ([podman module L82-L94, L305-L317, L343][nix-podman]). The runner module sets `DOCKER_HOST=unix:///run/podman/podman.sock` and `SupplementaryGroups = [ "podman" ]` if `virtualisation.podman.enable` ([L241-L243, L309-L315][nix-runner]).
- **Unqualified image names.** The NixOS containers module installs the `containers-shortnames` alias file ([containers.nix L209][nix-containers]), which maps `docker` to `docker.io/library/docker` and `ubuntu`, `node`, `alpine` likewise ([shortnames.conf][shortnames]). `docker:dind` and bare names therefore resolve under podman. Fully qualified names such as `docker.gitea.com/runner-images:...` and `git.nnik.dev/...` need no alias.
- **Runner side.** The runner's own test script has a `podman` target that checks "the Docker proxy probe for podman" ([test-dind.sh][r-testdind]), and a number of podman workarounds are in the code ([docker_proxy.go L209][r-proxy], [docker_run.go L518, L544][r-dockerrun]). The README says the *images* "target Docker, not Podman".
- **Socket mounted into jobs.** Unless `container.docker_host: "-"`, every job container gets the daemon socket as `/var/run/docker.sock` ([run_context.go L389-L391][r-rc], [config.example.yaml][r-cfg]). On Linux with a unix-socket daemon the runner interposes a per-job proxy. The proxy labels created objects per job (so `container.sweep: true` can remove them) and translates workspace paths in bind mounts ([docker_proxy.go L370-L409][r-proxy]). In `rewriteCreate`, the function applied to create requests, I found no filtering of `Privileged`, `Binds` or capabilities. A job with the socket therefore has the rights of whoever owns the daemon.
- **`docker build` in a job.** With the mounted socket, a plain `docker build` or `docker push` step works without `dockerd` in the job, as long as the job image has a Docker client. The podman compat API also serves `/build`. I did not test the specific Dockerfiles here (the Flutter images are large).
- **Rootful vs rootless podman.** The module only supports the rootful system socket. With `DynamicUser` and `NoNewPrivileges` the unit cannot use the setuid `newuidmap`/`newgidmap` that rootless podman needs. A rootless setup (static user, `loginctl enable-linger`, `$XDG_RUNTIME_DIR/podman/podman.sock`, which the runner also autodetects) means writing the systemd unit by hand instead of using the module.

#### 2d. Nix-based labels

Three things the ticket could mean, all available:

1. **Host label with Nix-provisioned tools** (2b). Per-job reproducible environment by calling `nix develop` / `nix run` from the workflow.
2. **Container label with a Nix-built image.** `pkgs.dockerTools.buildLayeredImage` plus `podman load -i` and `labels = [ "container:docker://test-image:latest" ]`. This is exactly what the module's own test does ([nixos test][nix-runner-test]). With `container.force_pull: false` (the default) a locally loaded image is used. Loading would need a small oneshot unit or activation script.
3. **No Docker daemon for image builds at all.** Build with `nix build` (`dockerTools`) and push with `skopeo` to `git.nnik.dev`. Not needed for the Flutter or server images unless their Dockerfiles are replaced with Nix expressions; listed for completeness.

#### 2e. Kubernetes

The runner can also schedule jobs as pods (`kubernetes://` labels, [docs/kubernetes.md][r-k8s]). Out of scope on a single host.

#### 2f. Instance layout

The module takes one `instances.<name>` per runner. Three instances reproduce today's 3 x `capacity: 2`. One instance with `capacity: 6` means one cache server and one registration. Each instance has its own cache server and `.runner` ([README, Caching][r-readme]). A high `capacity` with `container.network` empty can exhaust the daemon's address pool, because each concurrent job takes a subnet ([config.example.yaml][r-cfg]). Settings are free-form YAML (`settings = { runner.capacity = 2; ... }`, [L129-L148][nix-runner]) and the module appends only `cache.external_secret_file` handling.

#### 2g. Registration

- The module registers in `ExecStartPre` with `register --no-interactive --instance <url> --token-file <file> --name <name> --labels ...`, but only when `.runner` is missing, the label set differs from `.labels`, or the token hash differs from `.token-hash` ([L270-L306][nix-runner]). On a fresh host the two marker files do not exist, so each instance registers anew. Carrying over the old `.runner` files would also work only if `.labels`/`.token-hash` were seeded as well, which is not worth it.
- Old runner rows stay in the migrated database as offline ghosts (ids 1-17) and can be deleted in the admin UI.
- Tokens: "Each token can be used to create multiple runners, until it is replaced" ([quickstart][g-quickstart], [runner page][g-runner]). Scope them with `gitea actions generate-runner-token --scope aitopia` ([command-line][g-cli]). The module's `tokenFile` takes the raw token as the file content (the older `TOKEN=` env-file format is deprecated, [L95-L107][nix-runner]); with sops-nix that is one secret.
- Runner `url`: the docs say to avoid loopback, because job containers must reach it too ([design][g-design]). The current `https://git.nnik.dev` works from the same host today; whether it keeps working depends on how LAN DNS/hairpin is set up in the blocky and Caddy tickets.

### 3. What the existing workflows need

Read from `.gitea/workflows/` at HEAD of each repository (read-only `git show` inside the Gitea container).

| Workflow | Needs | Host executor | Podman backend |
| --- | --- | --- | --- |
| `demo`/`factory` `ci.yml` | `actions/checkout@v4`, `actions/setup-python@v5` (demo), `python3 -m venv` + pip | Possible with `nodejs`, `git`, `python3`, a loader for downloaded Pythons | Works in the `ubuntu-latest` image |
| `*/pr-title-check.yml` (3x) | `grep`, `printf`/`echo` only | Works if `grep` is added | Works |
| `battle-tracker` `ci.yml` (7 jobs) | `container: image: git.nnik.dev/aitopia/flutter-ci[-android]:latest`, `actions/checkout@v3`, `uses` fetched from github.com | **No** (job-level `container:`) | Needs podman to pull from the Gitea registry; works if images exist |
| `build-flutter-ci`, `build-flutter-android-ci` | `container: docker:dind`, `options: --privileged`, runs `dockerd &`, `docker build`, `docker push` | **No** | Needs privileged-equivalent nested dockerd, or a rewrite to the mounted socket |
| `deploy-web`, `sync-server-image` | Same dind pattern, plus a smoke test via `docker run`/`exec` and `just deploy` (`PORTAINER_WEBHOOK_URL`) | **No** | Same; the Portainer webhook has no target after the cutover |

Points that stand out:

- **Bootstrap.** `ci.yml` pulls `flutter-ci`/`flutter-android-ci` from Gitea's own container registry. Those two images are built by the dind workflows. If `packages` (6.5 GB) and its database rows are restored, CI works immediately. If not, the image build workflows must run first, and they need a working container backend.
- **`--privileged` is ignored.** With `container.privileged: false`, a workflow's `options: --privileged` is dropped with a warning, and the runner likewise drops "options that could escape the container (`--security-opt`, `--device`, `--cap-add`, `--pid`, ...)" from a workflow's own `container.options`; the runner-level `container.options` is exempt ([docker_run.go L623-L650][r-dockerrun], [config.example.yaml][r-cfg]). The live dind jobs therefore run with the capability set from the runner config. A podman replacement can express the same in `settings.container.options`, or set `container.privileged = true`. Whether `docker:dind` starts inside an unprivileged-user-namespace or rootful podman container with just those capabilities is untested; the module's own test does not cover it.
- **Portainer is retired** in the migration map. The "Redeploy via Portainer" step in `deploy-web`/`sync-server-image` has no target; what replaces it is for ticket 14 (Own apps).
- **Runner 5.0.0 behaviour changes** that touch these workflows: a job without `runs-on` now fails (all current ones declare it); `${NAME}` in config values is expanded ([5.0.0 post][g-blog-r5]).
- **Gitea 28.0.0 changes** that may touch them: job-level `if:` is "evaluated before matrix expansion and has a restricted set of contexts" (the 6 `if: ${{ !cancelled() }}` job conditions in `ci.yml` use only a status function, but are worth a test run), and `fail-fast` is enforced ([28.0.0 post][g-blog-28]).
- **`actions/checkout@v3` / `setup-python` downloads** go to github.com unless `[actions] DEFAULT_ACTIONS_URL = self` ([cheat sheet][g-cheat], [FAQ][g-faq]), done by the runner, not by the job.

### 4. Security trade-offs

| Setup | What a malicious or buggy workflow can reach | Notes |
| --- | --- | --- |
| Today: dind-rootless in a privileged container | The nested rootless daemon (UID 1000 in its own user namespace) and, since the outer container is privileged, whatever escapes that | The runner README's recommendation: "Jobs never get the host's Docker socket" ([README][r-readme]). |
| Rootful podman socket + `docker://` labels | Root on the Optiplex: the runner unit is in the `podman` group, and every job gets a proxied socket that does not restrict create parameters | `DynamicUser` does not help; the daemon is the privilege boundary. The proxy bounds *cleanup*, not *power*. |
| Rootful podman, `docker_host: "-"` (no socket in jobs) | Job containers are root containers with only the capabilities in `container.options`; no daemon access | Breaks any workflow that calls `docker` directly; the dind workflows still start their own `dockerd` and so need their caps. |
| Host executor (`:host`) | The `gitea-runner` dynamic user: read-only view of the filesystem, write to its state dir and `/tmp`, network access to every localhost service, Nix daemon | Smallest blast radius in the module, no container features. |
| Rootless podman by a static user (hand-written unit) | The static user, plus whatever user namespaces allow | Not supported by the module; extra work; nested dind may be harder. |

Context from Gitea's own docs: "If you're using a private Gitea instance for your company, you may not need to worry about security since you trust your colleagues"; the real threats are an unknown runner stealing code/secrets, and malicious scripts controlling a runner ([FAQ][g-faq]). Here registration is disabled (`DISABLE_REGISTRATION = true`), the organisation has a handful of users (`yannik` plus `bt-*` bot accounts), and fork-PR runs require approval ([FAQ][g-faq]). The risk model is "a compromised push or token from one of those accounts", not anonymous users.

### 5. Migrating Gitea from the Docker image to `services.gitea`

Module facts from [gitea.nix][nix-gitea] (nixos-unstable `f9a75f41be3a`):

- Options: `stateDir` (`/var/lib/gitea`), `customDir` (`${stateDir}/custom`), `repositoryRoot` (`${stateDir}/repositories`), `lfs.contentDir`, `user`/`group` (`gitea`; the module only creates the user and group when they are literally `gitea`, L986-L997), `database.*` (`type`, `socket`, `name`, `user`, `passwordFile`, `createDatabase`), free-form `settings`.
- With `database.createDatabase = true` (default) the module adds `ensureDatabases`/`ensureUsers` with `ensureDBOwnership`, connects over `/run/postgresql`, and **asserts** that the DB user equals the OS user and equals the DB name (L595-L606, L741-L751). With `createDatabase = false` (as the module's own assertion message advises for existing databases) none of this applies. The role/ownership and "do not start against an empty schema" topics belong to the database ticket ([db-migration research][db-research]).
- On every start, `preStart` copies the generated `app.ini` to `${customDir}/conf/app.ini`, then substitutes secrets from `${customDir}/conf/{secret_key,oauth2_jwt_secret,lfs_jwt_secret,internal_token}`, generating any that are missing (`gitea generate secret ...`). It then runs `gitea migrate`, `gitea admin regenerate hooks`, and `gitea admin regenerate keys` if `${stateDir}/.ssh/authorized_keys` exists (L816-L903).
- The unit is sandboxed (`ProtectSystem=strict`, `ProtectHome`, `PrivateUsers`, `CapabilityBoundingSet = ""`, `~@privileged`, `ReadWritePaths` limited to `stateDir`, `customDir`, `repositoryRoot`, `lfs.contentDir`, `dump.backupDir`; L911-L975). Any path outside those (for example a Data-disk path) has to be added through those options or an override.

Layout mapping, from the [Docker template][g-docker] and the live `app.ini`:

| Docker (`/data/...`) | Native NixOS | How |
| --- | --- | --- |
| `gitea/conf/app.ini` (`GITEA_CUSTOM=/data/gitea`) | generated into `${customDir}/conf/app.ini` | Translate into `services.gitea.settings`; do not copy the file |
| `gitea/{packages,attachments,avatars,repo-avatars,actions_log,home,jwt,queues,repo-archive,tmp,indexers,sessions}` (`APP_DATA_PATH=/data/gitea`) | `${stateDir}/data/...` by default (`APP_DATA_PATH` default is `AppWorkPath/data`; [cheat sheet][g-cheat]) | Move into `${stateDir}/data/`, or set `settings.server.APP_DATA_PATH` to the old layout. Sessions, indexers (bleve, rebuildable), `tmp` and `queues` can be dropped |
| `git/repositories` | `${repositoryRoot}` | Set `repositoryRoot`, or move |
| `git/lfs` | `lfs.contentDir` | Set or move |
| `git/.ssh/authorized_keys` (24 lines, `command=` lines call the container's gitea) | `${stateDir}/.ssh/authorized_keys` | `regenerate keys` rewrites the command paths on start; with user `gitea` the clone URL would be `gitea@...` unless `user = "git"` (then declare the `git` user and group yourself) |
| `ssh/ssh_host_*` (container sshd host keys) | none | Only relevant if host sshd or the built-in server should present the same host keys, to avoid client warnings |
| `app.ini` secrets | `custom/conf/{secret_key,internal_token,lfs_jwt_secret,oauth2_jwt_secret}` | Seed from the live `[security] SECRET_KEY`, `INTERNAL_TOKEN`, `[server] LFS_JWT_SECRET`, `[oauth2] JWT_SECRET` through sops-nix |

Notes:

- **`SECRET_KEY` is not optional to carry.** Gitea docs: "if you lost it, the data encrypted by it (like 2FA secret) can't be decrypted anymore" ([cheat sheet][g-cheat]). The 4 Actions secrets are also stored encrypted with it ([secret.go L79, L139, L180][g-secret]); without it the registry login in the dind workflows would fail. Gitea also supports `SECRET_KEY_URI = file:...` and `INTERNAL_TOKEN_URI`.
- **Git hooks.** The repos' hook scripts point at the container's `gitea` binary and `/data` paths. The Gitea docs say to run `gitea admin regenerate hooks` after changing the installation method, otherwise "repository `push` actions will fail" ([backup-and-restore][g-backup]). The NixOS `preStart` does this on every start.
- **Ownership.** The container runs as `git` (UID/GID 1000, `USER_UID`/`USER_GID` in the compose file, [with-docker][g-docker-doc]), and the volumes are owned by 1000:1000. They need `chown` to the module's user.
- **Config differences.** The module forbids `settings.server.DOMAIN` (assertion; also dropped upstream in 28.0.0, so use `ROOT_URL = https://git.nnik.dev/` only). Sessions use `PROVIDER = file` under `/data/gitea/sessions`; they can be dropped (users log in again). `LFS_START_SERVER` is set by `lfs.enable`. The module also pins `cron.update_checker.ENABLED = false` (live already has it off).
- **Gitea's own documented restore** is manual: put files in place, restore the database, regenerate hooks, run `doctor check` ([backup-and-restore][g-backup]). The migration from Docker is a "move paths and restore" operation, not a Gitea feature.
- **Version.** Gitea only supports upgrading forward ("`a.b.?` -> `a.c.?` already upgrades the database ... a backup should always be made before a database upgrade", [upgrade][g-upgrade]). The jump is `1.26.4` -> `28.3.0` (unstable) or `1.27.3` (nixos-26.05). Upstream's 28.0.0 post lists: git >= 2.25.0 required (NixOS passes `pkgs.git`), `DOMAIN` not read, registration off unless explicitly set (already `true`), WebSocket upgrade headers needed in the reverse proxy (Caddy handles this), Actions runs deleted after 400 days (`RUN_RETENTION_DAYS = 0` to keep; the oldest run is 4.5 months), and the stricter Actions evaluation above ([28.0.0 post][g-blog-28]). It does not state a minimum previous version or a runner compatibility matrix.
- **Database.** The live PostgreSQL 14 database (`gitea`, owner `gitea`, 132 MB, Gitea schema version 331) is covered by the database ticket ([db-migration research][db-research]); the point here is only that Gitea owns its schema and `gitea migrate` runs at every unit start, so a restore must complete before the first start.
- **Same-host runner dependency.** The runner module orders after `network-online.target` only; it does not order after `gitea.service` (and `Restart=on-failure` with 2 s covers Gitea restarts, L266-L268). Registration needs Gitea up, so the first start after a restore may need a retry.

## Options / trade-offs

**A. Rootful podman + `services.gitea-actions-runner`, keep `docker://` labels (closest to today).**

- Pro: existing `container:` jobs work unchanged. Same labels (`ubuntu-latest` -> `docker.gitea.com/runner-images`). Module and test exist. Podman socket activation costs nothing when idle. Cleanup via `container.sweep` / `autoPrune`.
- Con: root-equivalent runner and job socket (see 4). The dind workflows still need testing against podman. The image cache (about 22 GB for runner 1 today) moves to one podman store shared by all instances; it should be placed on the Data disk (`virtualisation.containers.storage.settings`, not checked here).
- Variant A1: copy today's `container.options` caps. Closest, least change, weakest (SYS_ADMIN + unconfined seccomp).
- Variant A2: `container.privileged = true`. Simplest and strongest-privileged.
- Variant A3: rewrite the four dind workflows to build against the mounted socket (no `dockerd` in the job). No special caps, but needs a Docker client in the job image and a repo change in `battle-tracker`.

**B. Host executor only, packages from Nix.**

- Pro: smallest blast radius with the module, no container runtime, no image cache, fastest start.
- Con: cannot run `battle-tracker` CI (7 jobs of `ci.yml` and the 4 dind workflows) without rewriting them to `nix develop`/host steps, and `flutter-ci` images exist for a reason (Flutter, Android SDK, FHS binaries). Needs `grep` and more in `hostPackages`, plus `nix-ld` for downloaded tool builds.

**C. Both labels on separate instances** (a `host`-label instance and a podman instance, as in the module's test).

- Pro: simple jobs (title checks, `demo`/`factory`) avoid the podman daemon; heavy jobs get containers. Pro: maps naturally to nix-provisioned `native` label.
- Con: two registrations, two label sets to keep in sync, repos must pick labels in `runs-on`. All current jobs say `ubuntu-latest`, so the workflows would need editing to benefit.

**D. Rootless podman by hand.**

- Pro: job containers are not host root.
- Con: not the module's path (`DynamicUser`/`NoNewPrivileges` conflict), nested dind and caps in rootless podman are unproven here, and it is more NixOS code to own.

**E. Move image builds off the runner** (Nix `dockerTools` + `skopeo`/registry push, or build elsewhere).

- Pro: removes the privileged dind jobs altogether.
- Con: rewrites `flutter.Dockerfile`, `flutter-android.Dockerfile`, `server/Dockerfile`, web packaging; much larger change than the migration needs. Probably a follow-up, not a prerequisite.

**Gitea-side choice (independent of the above):** which `nixpkgs` channel to land on. `nixos-unstable` gives Gitea 28.3.0 and runner 3.1.0; `nixos-26.05` gives 1.27.3 and runner 1.0.3 (an older runner than the live 4.0.0). Either way the runner is behind 4.0.0/5.4.1, and the Gitea version moves forward from 1.26.4 with no way back except the Rollback image or the database/data backups.

## Open questions

- Does `docker:dind` (privileged-equivalent) work inside a rootful podman job container on this kernel, with either today's capability list or `privileged = true`? Can `flutter-ci`/`flutter-android-ci` images be rebuilt through the podman compat `/build` API, or do the four dind workflows have to change? Needs a real test in the VM harness (the module's NixOS test only echoes strings).
- Is the runner proxy's lack of restrictions acceptable, or should jobs run with `docker_host: "-"` plus a rewrite of the workflows (A3 needs a client in the image)?
- Which runner version to run: nixpkgs' (3.1.0 on unstable) or a self-packaged 5.x (`override` of `gitea-actions-runner` with a newer tag). Runner 4.0.0/5.0.0 notes list no minimum Gitea version, so compatibility with Gitea 28.3.0 is assumed, not documented.
- Is a single `capacity = 6` instance acceptable instead of 3 x 2?
- Where should the podman store live (Data disk vs NVMe), and is the 22 GB image cache worth restoring or just re-pulled?
- LAN access to `git.nnik.dev` from the Optiplex itself: the runners and job containers use the public URL today. With blocky and Caddy on the same host, this needs a conscious DNS answer (or point `url` at a LAN-reachable address).
- Do SSH clone URLs stay `git@git.nnik.dev` on a different port than the host's sshd? Today the container sshd is published on `25580` and `SSH_PORT = 22` is shown in clone URLs. What the router forwards for 22 was not checked. Decide between host sshd + `user = "git"` and the built-in SSH server.
- What replaces the Portainer redeploy webhook in `deploy-web` and `sync-server-image` (ticket 14)?
- Should the 6.5 GB of container-registry packages be carried (needed to avoid rebuilding `flutter-ci` first), and should `RUN_RETENTION_DAYS = 0` be set before the upgrade?
- Which module `user`: `gitea` (module default, `gitea@host` clone URLs) or `git` (matches existing `authorized_keys` and clone URLs)?

## Sources

Repo and live server (read-only):

- `ssh optiplex`: `docker inspect` of `gitea`, `gitea-db-1`, `gitea_runners-factory_runner-{1,2,3}`; `/config.yaml` and `.runner` (token and uuid not recorded) inside the runner containers; `app.ini` (secrets not recorded); `psql` catalog queries on `action_runner`, `action_run`, `action_run_job`, `secret`, `package`, `repository`, `user`; workflow files via `git show HEAD:.gitea/workflows/*` in `/data/git/repositories/aitopia/*.git`.

nixpkgs @ `f9a75f41be3a74eab55d3a7679d34ad6cc0da977` (nixos-unstable, 2026-11-05):

- [nix-runner]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/modules/services/continuous-integration/gitea-actions-runner.nix>
- [nix-runner-test]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/tests/gitea-actions-runner.nix>
- [nix-runner-pkg]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/pkgs/by-name/gi/gitea-actions-runner/package.nix> (3.1.0; `nixos-26.05` has 1.0.3, `nixos-25.11` 0.2.13, the pinned `de0fe30` 0.2.11, checked with the same path on those refs)
- [nix-gitea]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/modules/services/misc/gitea.nix>; package: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/pkgs/by-name/gi/gitea/package.nix> (28.3.0; `nixos-26.05` has 1.27.3, `nixos-25.11` 1.25.5)
- [nix-podman]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/modules/virtualisation/podman/default.nix>
- [nix-containers]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/modules/virtualisation/containers.nix>
- [nix-nixconf]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/modules/config/nix.nix>
- [nix-ld]: <https://github.com/NixOS/nixpkgs/blob/f9a75f41be3a74eab55d3a7679d34ad6cc0da977/nixos/modules/programs/nix-ld.nix>

Gitea Runner @ `v5.4.1` (`bb6d793cb984`), <https://gitea.com/gitea/runner>:

- [r-readme]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/README.md>
- [r-cfg]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/internal/pkg/config/config.example.yaml>
- [r-daemon]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/internal/app/cmd/daemon.go#L372-L378>
- [r-rc]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/act/runner/run_context.go> (L389-L391, L1249-L1283)
- [r-proxy]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/act/container/docker_proxy.go>
- [r-dockerrun]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/act/container/docker_run.go> (L623-L650)
- [r-testdind]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/scripts/test-dind.sh>
- [r-k8s]: <https://gitea.com/gitea/runner/src/tag/v5.4.1/docs/kubernetes.md>

Gitea:

- [g-docker]: <https://github.com/go-gitea/gitea/blob/main/docker/root/etc/templates/app.ini> and <https://github.com/go-gitea/gitea/blob/main/Dockerfile> (`ENV USER=git`, `ENV GITEA_CUSTOM=/data/gitea`, `VOLUME ["/data"]`)
- [g-secret]: <https://github.com/go-gitea/gitea/blob/main/models/secret/secret.go>
- Docs repo <https://gitea.com/gitea/docs> @ `878c885`: [g-quickstart] `docs/usage/actions/quickstart.md`, [g-runner] `docs/usage/actions/runner.mdx`, [g-design] `docs/usage/actions/design.md`, [g-faq] `docs/usage/actions/faq.md`, [g-cheat] `docs/administration/config-cheat-sheet.md` (`SECRET_KEY`, `APP_DATA_PATH`, `[actions]`), [g-cli] `docs/administration/command-line.md` (`actions generate-runner-token`), [g-backup] `docs/administration/backup-and-restore.md`, [g-upgrade] `docs/installation/upgrade-from-gitea.md`, [g-docker-doc] `docs/installation/with-docker.md`.
- [g-blog-28]: <https://blog.gitea.com/release-of-28.0.0/>
- [g-blog-r5]: <https://blog.gitea.com/release-of-runner-5.0.0/>; also <https://blog.gitea.com/release-of-runner-4.0.0/>

Other:

- [sd-exec]: systemd `man/systemd.exec.xml`, `DynamicUser=`: <https://github.com/systemd/systemd/blob/main/man/systemd.exec.xml>
- [podman-svc]: <https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-service.1.md>
- [shortnames]: <https://github.com/containers/shortnames/blob/main/shortnames.conf>
- [db-research]: sibling findings `research/db-migration.md` on branch `research/db-migration` (ticket 10)
