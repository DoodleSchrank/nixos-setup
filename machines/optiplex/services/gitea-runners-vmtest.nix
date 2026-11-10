# VM checks of the runner VMs (the optiplex.vmTest seam, see machines/optiplex/vm-test.nix). Imported from
# gitea-runners.nix; the checks are only data outside the tests.
#
# What the hermetic test does (it boots the two microVMs inside the test VM, so it needs nested KVM: the
# PC's kvm_amd/kvm_intel `nested=1`):
#   - the VMs start with the dummy tokens of the test mirror, the check then generates the real tokens on the
#     test Gitea exactly as the Cutover does (`optiplex-gitea actions generate-runner-token [--scope aitopia]`),
#     puts them where sops-nix put the dummies and restarts the VMs, which register;
#   - jobs: ubuntu-latest in aitopia -> trusted VM, shared of another user -> untrusted VM, ubuntu-latest of
#     another user stays queued; a docker:dind job builds and pushes an image to git.nnik.dev and a container:
#     job pulls it again;
#   - the firewall from inside an untrusted job; the weekly wipe.
#
# Test-mode differences from production (all in this file): the VMs are small (2 vCPU, 1.5 GB, 6 GiB cache),
# their images live in /var/lib/runner-vm-test (the Data disk of the test is 1 GB), the job images are stand-ins
# built by Nix (docker.gitea.com is not reachable: no internet) and the VMs trust the test CA (pebble's random
# root, handed in as a second systemd credential).
#
# Not testable here: the real runner-images, `uses:` actions from github.com (actions/checkout) and so the
# `factory` / `battle-tracker` ci.yml themselves.
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  rcfg = config.optiplex.runnerVms;
  data = import ../runner-vms/vms.nix;
  inherit (data) vms;

  # no real disks = the hermetic VM test (tests/optiplex/overlay-hermetic.nix sets this; the rehearsal and
  # the real host have the disko layout)
  testMode = !config.disko.enableConfig;

  testStateDir = "/var/lib/runner-vm-test";
  caCert = pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"; # pebble's WFE certificate CA
  caHost = "/run/gitea-runners-test/ca.pem"; # pebble's root, fetched at boot (it is random per start)

  # --- the stand-in images --------------------------------------------------------------------------
  # What the job container needs for `run:` steps: bash, coreutils, curl. Same names as the real labels use.
  runnerImage = pkgs.dockerTools.buildLayeredImage {
    name = "docker.gitea.com/runner-images";
    tag = "ubuntu-latest";
    contents = with pkgs; [bashInteractive coreutils curl gnugrep gnused findutils cacert glibc.bin dockerTools.fakeNss];
    extraCommands = "mkdir -m 1777 tmp";
    config.Env = ["PATH=/bin" "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"];
  };
  # busybox rootfs that the dind job turns into the image it pushes (the flutter-ci stand-in)
  busyboxRoot = pkgs.runCommand "busybox-rootfs.tar" {} ''
    mkdir -p root/bin
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox root/bin/busybox
    for a in $(root/bin/busybox --list); do ln -sf busybox root/bin/$a; done
    tar -C root -cf $out .
  '';
  # `docker:dind`: dockerd and the docker CLI. Podman resolves the short name docker:dind to docker.io/library/docker.
  dindImage = pkgs.dockerTools.buildLayeredImage {
    name = "docker.io/library/docker";
    tag = "dind";
    contents = with pkgs; [bashInteractive coreutils docker cacert dockerTools.fakeNss iptables gnugrep procps];
    extraCommands = "mkdir -m 1777 tmp; mkdir -p var/lib var/run; cp ${busyboxRoot} rootfs.tar";
    config.Env = ["PATH=/bin" "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"];
  };

  # --- the guests (both VMs) -----------------------------------------------------------------------
  guestTest = {
    config,
    lib,
    pkgs,
    ...
  }: {
    microvm.credentialFiles.CA_CERT = caHost;

    # trust the test CA: a bundle (system CAs + the test root) for the runner and the job containers, and the
    # certs.d entry that podman uses when it pulls from git.nnik.dev
    systemd.services.test-runner-ca = {
      description = "Trust the test CA";
      wantedBy = ["multi-user.target"];
      before = ["gitea-runner-main.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d /run/runner-ca
        cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /run/credentials/@system/CA_CERT > /run/runner-ca/ca-bundle.crt
        cp /run/credentials/@system/CA_CERT /run/runner-ca/ca.pem
        chmod 0644 /run/runner-ca/*
      '';
    };
    environment.etc."containers/certs.d/git.nnik.dev/ca.crt".source = "/run/runner-ca/ca.pem";

    # the job images: loaded into the podman store on cache.img at every boot (the weekly wipe empties it)
    systemd.services.test-load-images = {
      description = "Load the stand-in job images";
      wantedBy = ["multi-user.target"];
      before = ["gitea-runner-main.service"];
      after = ["systemd-tmpfiles-setup.service"];
      path = [pkgs.podman];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        podman load -i ${runnerImage}
        podman tag docker.gitea.com/runner-images:ubuntu-latest docker.gitea.com/runner-images:ubuntu-24.04
        ${lib.optionalString (config.networking.hostName == vms.trusted.name) "podman load -i ${dindImage}"}
      '';
    };
    systemd.services.gitea-runner-main = {
      after = ["test-load-images.service" "test-runner-ca.service"];
      requires = ["test-load-images.service" "test-runner-ca.service"];
      environment.SSL_CERT_FILE = "/run/runner-ca/ca-bundle.crt";
    };
    runnerVm.extraSettings = {
      # the 6 GiB test cache disk is below the production floor (5120 MiB free), which would pause the runner
      health_check.min_free_disk_space_mb = 256;
      runner.envs = {
        SSL_CERT_FILE = "/etc/test-ca/ca-bundle.crt";
        GIT_SSL_CAINFO = "/etc/test-ca/ca-bundle.crt";
      };
      container.volumes = [
        "/run/runner-ca/ca-bundle.crt:/etc/test-ca/ca-bundle.crt:ro"
        "/run/runner-ca/ca.pem:/etc/docker/certs.d/git.nnik.dev/ca.crt:ro"
      ];
    };
  };

  # --- the checks -----------------------------------------------------------------------------------
  fixturePass = "fixture-pass-1234"; # the Yannik account of the gitea fixture
  otherPass = "other-pass-1234";
  psql = "runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d gitea -tAc";
in {
  config = lib.mkMerge [
    {
      optiplex.vmTest.checks.gitea-runners-eval = {
        phase = "restore";
        script = ''
          # restoreMode: declared, not started; the host side exists
          for vm in ("runner-trusted", "runner-untrusted"):
              optiplex.fail(f"systemctl is-active microvm@{vm}.service")
              optiplex.fail(f"systemctl list-dependencies --plain microvms.target | grep -q microvm@{vm}")
          optiplex.fail("systemctl cat gitea-runner-untrusted-wipe.service")
          assert optiplex.succeed("id -u microvm").strip() == "970"
          # the nft tables are there from the start, whatever the VMs do
          rules = optiplex.succeed("nft list table inet optiplex-runner-vms")
          print(rules)
        '';
      };
    }
    {
      optiplex.vmTest.checks.gitea-runners = {
        script = ''
          import base64, json, re, shlex, time

          def rv_main():
              ca = "${caHost}"
              psql = "${psql}"

              def sql(q):
                  return optiplex.succeed(psql + " " + shlex.quote(q)).strip()

              def api(method, path, user, pw, body=None):
                  cmd = (f"curl -fsS -u {user}:{pw} -X {method} -H 'Content-Type: application/json' --cacert {ca} "
                         f"--resolve git.nnik.dev:443:192.168.178.20 https://git.nnik.dev{path}")
                  if body is not None:
                      cmd += " -d " + shlex.quote(json.dumps(body))
                  return optiplex.succeed(cmd)

              def vm_logs(vm):
                  return optiplex.execute(f"journalctl -u microvm@{vm}.service --no-pager -n 80 -o cat")[1]

              # ---- Gitea, the test CA and the two VMs are up ----------------------------------------
              optiplex.wait_for_unit("gitea.service")
              optiplex.wait_until_succeeds(f"test -s {ca}", timeout=120)
              optiplex.wait_until_succeeds(f"curl -fsS --cacert {ca} --resolve git.nnik.dev:443:192.168.178.20 https://git.nnik.dev/api/healthz", timeout=180)
              for vm in ("runner-trusted", "runner-untrusted"):
                  optiplex.wait_for_unit(f"microvm@{vm}.service")

              # host side as decided
              props = optiplex.succeed("systemctl show -p OnFailure -p RequiresMountsFor -p User -p Group -p TimeoutStopUSec microvm@runner-trusted.service")
              print(props)
              assert "notify-failure@%n.service" in props or "notify-failure@microvm@runner-trusted.service" in props, props
              assert "/state" in props and "User=microvm" in props and "Group=kvm" in props, props
              for k in ("trusted", "untrusted"):
                  for img in ("runner.img", "cache.img"):
                      owner = optiplex.succeed(f"stat -c '%U:%G %s' ${testStateDir}/{k}/{img}").strip()
                      assert owner.startswith("microvm:kvm "), (k, img, owner)
                      used = int(optiplex.succeed(f"du -k ${testStateDir}/{k}/{img} | cut -f1"))
                      size = int(owner.split()[1]) // 1024
                      print(f"{k}/{img}: {size} KiB, {used} KiB on disk")
                      assert used < size * 9 // 10, (k, img, used, size)  # sparse
              optiplex.wait_until_succeeds("ip -4 -br addr show vm-trusted | grep -q '10.100.1.1/24' && ip -4 -br addr show vm-untrusted | grep -q '10.100.2.1/24'", timeout=60)
              assert optiplex.succeed("sysctl -n net.ipv4.ip_forward").strip() == "1"

              # ---- nft: the ruleset as specified ----------------------------------------------------
              rules = optiplex.succeed("nft list table inet optiplex-runner-vms")
              nat = optiplex.succeed("nft list table ip optiplex-runner-nat")
              print(rules, nat)
              for needle in ('"vm-trusted"', '"vm-untrusted"', "ct state established,related accept", "tcp dport 443 accept", "th dport 53 accept",
                             "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
                             "224.0.0.0/3", "vm -> vm", "vm -> internet", "vm -> host: anything but 443 and 53"):
                  assert needle in rules, needle
              assert "masquerade" in nat and "iifname" in nat, nat
              # no NixOS NAT module accept-all in front of the filters
              assert "from internal interfaces" not in optiplex.succeed("nft list ruleset"), "networking.nat forward accept is on"

              # ---- tokens: as the Cutover does it ---------------------------------------------------
              def token(args):
                  out = optiplex.succeed("optiplex-gitea actions generate-runner-token " + args).strip().splitlines()[-1].strip()
                  assert len(out) >= 30 and " " not in out, out
                  return out
              ttok = token("--scope aitopia")
              utok = token("")
              assert ttok != utok
              for k, tok in (("trusted", ttok), ("untrusted", utok)):
                  optiplex.succeed(f"printf %s {tok} > /run/secrets/gitea-runners/{k}_token")
                  assert optiplex.succeed(f"stat -L -c '%U %a' /run/secrets/gitea-runners/{k}_token").strip() == "microvm 400"
              optiplex.succeed("systemctl restart microvm@runner-trusted.service microvm@runner-untrusted.service")
              try:
                  optiplex.wait_until_succeeds(psql + " " + shlex.quote("select count(*) from action_runner where name in ('runner-trusted','runner-untrusted') and last_online > 0") + " | grep -qx 2", timeout=240)
              except Exception:
                  print(vm_logs("runner-trusted")); print(vm_logs("runner-untrusted"))
                  print(sql("select * from action_runner"))
                  raise
              print(optiplex.succeed(psql + " " + shlex.quote("select id, name, owner_id, repo_id, agent_labels, version from action_runner order by id")))
              org_id = sql("select id from \"user\" where lower_name = 'aitopia'")
              tr = json.loads(optiplex.succeed("runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d gitea -tAc " + shlex.quote("select row_to_json(r) from (select owner_id, repo_id, agent_labels from action_runner where name = 'runner-trusted') r")))
              ur = json.loads(optiplex.succeed("runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d gitea -tAc " + shlex.quote("select row_to_json(r) from (select owner_id, repo_id, agent_labels from action_runner where name = 'runner-untrusted') r")))
              def label_names(r):
                  labels = r["agent_labels"]
                  labels = json.loads(labels) if isinstance(labels, str) else labels
                  return sorted(l.split(":")[0] for l in labels)
              assert (str(tr["owner_id"]), tr["repo_id"]) == (org_id, 0), (tr, org_id)
              assert label_names(tr) == ["ubuntu-24.04", "ubuntu-latest"], tr
              assert (ur["owner_id"], ur["repo_id"]) == (0, 0), ur
              assert label_names(ur) == ["shared", "shared-24.04"], ur
              runner_ids = sql("select string_agg(id || ':' || name, ',' order by id) from action_runner")

              # ---- accounts, repos, workflows ---------------------------------------------------------
              optiplex.succeed("optiplex-gitea admin user create --username Other --password ${otherPass} --email other@example.com --must-change-password=false")
              api("POST", "/api/v1/user/repos", "Other", "${otherPass}", {"name": "playground", "auto_init": True, "default_branch": "main", "readme": "Default"})
              ADMIN = ("Yannik", "${fixturePass}")
              OTHER = ("Other", "${otherPass}")

              def push_workflow(owner, repo, who, branch, yml):
                  api("POST", f"/api/v1/repos/{owner}/{repo}/contents/.gitea/workflows/{branch}.yml", who[0], who[1],
                      {"content": base64.b64encode(yml.encode()).decode(), "message": f"workflow {branch}", "branch": "main", "new_branch": branch})

              def job_state(owner, repo, job):
                  q = ("select j.status || '|' || coalesce(r.name, '-') || '|' || coalesce(j.task_id, 0) from action_run_job j "
                       "join repository rp on rp.id = j.repo_id left join action_task t on t.id = j.task_id left join action_runner r on r.id = t.runner_id "
                       f"where lower(rp.owner_name) = lower('{owner}') and rp.name = '{repo}' and j.job_id = '{job}' order by j.id desc limit 1")
                  return sql(q)

              def job_log(owner, repo, job):
                  task = job_state(owner, repo, job).split("|")[2]
                  return optiplex.execute(
                      f"f=$(find /state/gitea/data/actions_log -name '{task}.log*' | head -n1); "
                      "case $f in *.zst) ${pkgs.zstd}/bin/zstd -dc $f;; *) cat $f;; esac")[1]

              def wait_job(owner, repo, job, timeout=420):
                  # 1 = success; 2 failure, 3 cancelled, 4 skipped end the wait with the log
                  end = time.time() + timeout
                  while time.time() < end:
                      st = job_state(owner, repo, job).split("|")
                      if st[0] == "1":
                          return st
                      if st[0] in ("2", "3", "4"):
                          print(job_log(owner, repo, job)); print(vm_logs("runner-trusted")); print(vm_logs("runner-untrusted"))
                          raise Exception(f"job {job} ended as {st}")
                      time.sleep(3)
                  print(vm_logs("runner-trusted")); print(vm_logs("runner-untrusted"))
                  raise Exception(f"timeout waiting for {owner}/{repo} {job}: {job_state(owner, repo, job)}")

              def workflow(branch, runs_on, script, extra=()):
                  lines = ["name: " + branch, "on:", "  push:", f"    branches: [{branch}]", "jobs:", f"  {branch.replace('-', '_')}:", f"    runs-on: {runs_on}"]
                  lines += ["    " + l for l in extra]
                  lines += ["    steps:", "      - run: |"] + ["          " + l for l in script.strip("\n").splitlines()]
                  return "\n".join(lines) + "\n"

              def run(owner, repo, who, branch, runs_on, script, extra=()):
                  push_workflow(owner, repo, who, branch, workflow(branch, runs_on, script, extra))
                  return wait_job(owner, repo, branch.replace("-", "_"))

              # A job nobody may take: ubuntu-latest of a non-aitopia user. It must still be queued at the end.
              push_workflow("Other", "playground", OTHER, "t-queued", workflow("t-queued", "ubuntu-latest", "echo must-never-run"))

              # ubuntu-latest in an aitopia repo -> the trusted VM
              st = run("AItopia", "demo", ADMIN, "t-trusted", "ubuntu-latest", 'echo "hello from the trusted job on $(hostname)"')
              assert st[1] == "runner-trusted", st
              assert "hello from the trusted job" in job_log("AItopia", "demo", "t_trusted")

              # runs-on: shared of another user -> the untrusted VM
              st = run("Other", "playground", OTHER, "t-shared", "shared", 'echo "hello from the shared job on $(hostname)"')
              assert st[1] == "runner-untrusted", st
              assert "hello from the shared job" in job_log("Other", "playground", "t_shared")

              # ---- the firewall, from inside an untrusted job ----------------------------------------------
              # (the client nodes have the default NixOS firewall: open it, the host's drops are what is tested)
              outside.succeed("systemctl stop firewall")
              lan.succeed("systemctl stop firewall")
              outside.succeed("systemd-run --unit=probe-http python3 -m http.server 8000 --bind 203.0.113.10 --directory /tmp")
              lan.succeed("systemd-run --unit=probe-http python3 -m http.server 8000 --directory /tmp")
              outside.wait_until_succeeds("curl -fsS -m 3 http://203.0.113.10:8000/ >/dev/null")
              lan.wait_until_succeeds("curl -fsS -m 3 http://192.168.178.50:8000/ >/dev/null")
              optiplex.succeed("curl -fsS -m 5 http://203.0.113.10:8000/ >/dev/null")  # (control: the host itself reaches it)
              fw_script = """
              p() { n=$1; if timeout 4 bash -c "echo > /dev/tcp/$2/$3" 2>/dev/null; then echo "PROBE $n open"; else echo "PROBE $n blocked"; fi; }
              p internet 203.0.113.10 8000
              p host-443 192.168.178.20 443
              p host-bridge-443 10.100.2.1 443
              p host-25580 192.168.178.20 25580
              p host-25560 192.168.178.20 25560
              p host-80 192.168.178.20 80
              p host-bridge-25580 10.100.2.1 25580
              p lan-host 192.168.178.50 8000
              p router 192.168.178.1 80
              p trusted-vm 10.100.1.2 39999
              p transmission 192.168.178.20 80
              echo "PROBE dns-git $(curl -sS -m 10 -v -o /dev/null https://git.nnik.dev/api/healthz 2>&1 | grep -o 'Trying [^ ]*' | tr '\\n' ' ')"
              echo "PROBE dns-transmission $(curl -sS -m 5 -v -o /dev/null http://transmission.opti.plex/ 2>&1 | grep -o 'Trying [^ ]*' | tr '\\n' ' ')"
              if curl -fsS -m 10 https://git.nnik.dev/api/healthz > /dev/null; then echo "PROBE https-git ok"; else echo "PROBE https-git FAILED"; fi
              if curl -fsS -m 10 http://203.0.113.10:8000/ > /dev/null; then echo "PROBE http-internet ok"; else echo "PROBE http-internet FAILED"; fi
              if curl -sS -m 5 http://transmission.opti.plex/ > /dev/null 2>&1; then echo "PROBE http-transmission REACHED"; else echo "PROBE http-transmission blocked"; fi
              """
              run("Other", "playground", OTHER, "t-fw", "shared", fw_script)
              probes = {}
              fw_log = job_log("Other", "playground", "t_fw")
              print(fw_log)
              for line in fw_log.splitlines():
                  m = re.search(r"Z PROBE ([a-z0-9-]+) (\S.*)$", line)
                  if m:
                      probes[m.group(1)] = m.group(2).strip()
              print(probes)
              assert probes["internet"] == "open", probes
              assert probes["host-443"] == "open" and probes["host-bridge-443"] == "open", probes
              assert probes["https-git"] == "ok" and probes["http-internet"] == "ok", probes
              assert "192.168.178.20:443" in probes["dns-git"] and "192.168.178.20:80" in probes["dns-transmission"], probes
              for k in ("host-25580", "host-25560", "host-80", "host-bridge-25580", "lan-host", "router", "trusted-vm", "transmission", "http-transmission"):
                  assert probes[k] == "blocked", (k, probes)
              # ... and the drops are the VM rules (counters), not luck
              fwd = json.loads(optiplex.succeed("nft -j list chain inet optiplex-runner-vms forward"))["nftables"]
              inp = json.loads(optiplex.succeed("nft -j list chain inet optiplex-runner-vms input"))["nftables"]
              def counted(items, comment):
                  for it in items:
                      r = it.get("rule")
                      if r and r.get("comment") == comment:
                          return [e["counter"]["packets"] for e in r["expr"] if "counter" in e][0]
                  raise Exception(comment)
              assert counted(fwd, "vm -> LAN, router, private and reserved ranges") > 0
              assert counted(fwd, "vm -> vm") > 0
              assert counted(inp, "vm -> host: anything but 443 and 53") > 0
              # the other side: a VM address is no address in the LAN rule of 25580, only a drop
              rules = optiplex.succeed("nft list ruleset")
              assert not [l for l in rules.splitlines() if "25580" in l and "vm-" in l and "accept" in l], rules

              # ---- docker:dind, the build-flutter-ci pattern, in the trusted VM ------------------------------
              # (the real workflows start `dockerd &` with the default socket; the runner also mounts the VM's podman socket at
              # /var/run/docker.sock into every job container, so which daemon answers is part of what this shows)
              dind_script = """
              set -eu
              export DOCKER_BUILDKIT=0
              ls -l /var/run/docker.sock || true
              dockerd --storage-driver=vfs --iptables=false --ip6tables=false --bridge=none > /tmp/dockerd.log 2>&1 &
              sleep 5
              for i in $(seq 90); do docker info > /dev/null 2>&1 && break; sleep 1; done
              docker info > /dev/null || { cat /tmp/dockerd.log; exit 1; }
              echo "DOCKERINFO $(docker info --format '{{.ServerVersion}} {{.Driver}} {{.OperatingSystem}}')"
              tail -n 3 /tmp/dockerd.log
              mkdir /tmp/ctx
              cp /rootfs.tar /tmp/ctx/
              printf 'FROM scratch\\nADD rootfs.tar /\\nCMD ["/bin/sh"]\\n' > /tmp/ctx/Dockerfile
              docker build -t git.nnik.dev/aitopia/flutter-ci:test /tmp/ctx
              echo ${fixturePass} | docker login git.nnik.dev -u Yannik --password-stdin
              docker push git.nnik.dev/aitopia/flutter-ci:test
              echo dind-push-done
              """
              st = run("AItopia", "demo", ADMIN, "t-dind", "ubuntu-latest", dind_script,
                       extra=["container:", "  image: docker:dind", "  options: --privileged"])
              assert st[1] == "runner-trusted", st
              dind_log = job_log("AItopia", "demo", "t_dind")
              print(dind_log)
              assert "dind-push-done" in dind_log
              # a real nested dockerd (own socket, so the mounted podman socket is not in the way): privileged = true is what
              # lets it run containers, with no capability list
              dind2_script = """
              set -eu
              dockerd --host=unix:///tmp/dind.sock --storage-driver=vfs --iptables=false --ip6tables=false --bridge=none > /tmp/dockerd2.log 2>&1 &
              export DOCKER_HOST=unix:///tmp/dind.sock
              for i in $(seq 90); do docker info > /dev/null 2>&1 && break; sleep 1; done
              docker info > /dev/null || { cat /tmp/dockerd2.log; exit 1; }
              echo "DOCKERINFO2 $(docker info --format '{{.ServerVersion}} {{.Driver}}')"
              mkdir /tmp/ctx2
              cp /rootfs.tar /tmp/ctx2/
              printf 'FROM scratch\\nADD rootfs.tar /\\n' > /tmp/ctx2/Dockerfile
              DOCKER_BUILDKIT=0 docker build -t nested /tmp/ctx2
              docker run --rm --network none nested /bin/echo nested-container-ran
              """
              run("AItopia", "demo", ADMIN, "t-dind2", "ubuntu-latest", dind2_script,
                  extra=["container:", "  image: docker:dind", "  options: --privileged"])
              dind2_log = job_log("AItopia", "demo", "t_dind2")
              print(dind2_log)
              assert "nested-container-ran" in dind2_log and "DOCKERINFO2 " in dind2_log
              pk = api("GET", "/api/v1/packages/AItopia?type=container", *ADMIN)
              assert "flutter-ci" in pk, pk

              # a container: job pulling that image from git.nnik.dev (the battle-tracker ci.yml pattern)
              st = run("AItopia", "demo", ADMIN, "t-container", "ubuntu-latest", "echo container-job-ok",
                       extra=["container:", "  image: git.nnik.dev/aitopia/flutter-ci:test", "defaults:", "  run:", "    shell: sh"])
              assert st[1] == "runner-trusted", st
              assert "container-job-ok" in job_log("AItopia", "demo", "t_container")

              # ---- the queued job is still queued, nothing ran it ----------------------------------------
              q = job_state("Other", "playground", "t_queued").split("|")
              assert q == ["5", "-", "0"], q

              # ---- the weekly wipe: cache.img is new, runner.img and the runner id are not ---------------------
              img = "${testStateDir}/untrusted"
              # (birth time, not the inode number: ext4 hands the freed inode to the new file)
              ino = lambda f: optiplex.succeed(f"stat -c %w {img}/{f}").strip()
              c0, r0 = ino("cache.img"), ino("runner.img")
              online0 = sql("select last_online from action_runner where name = 'runner-untrusted'")
              optiplex.succeed("systemctl list-timers gitea-runner-untrusted-wipe.timer --no-legend | grep -q gitea-runner-untrusted-wipe")
              optiplex.succeed("systemctl start gitea-runner-untrusted-wipe.service")
              assert ino("cache.img") != c0 and ino("runner.img") == r0, (c0, r0, ino("cache.img"), ino("runner.img"))
              optiplex.succeed("systemctl is-active microvm@runner-untrusted.service")
              optiplex.wait_until_succeeds(psql + " " + shlex.quote(f"select last_online > {online0} from action_runner where name = 'runner-untrusted'") + " | grep -qx t", timeout=240)
              assert sql("select string_agg(id || ':' || name, ',' order by id) from action_runner") == runner_ids  # no new ghost row
              st = run("Other", "playground", OTHER, "t-post-wipe", "shared", 'echo "after the wipe on $(hostname)"')
              assert st[1] == "runner-untrusted", st

              # leave the clients and the memory as the checks that follow expect them
              outside.succeed("systemctl stop probe-http; systemctl start firewall")
              lan.succeed("systemctl stop probe-http; systemctl start firewall")
              optiplex.succeed("systemctl stop microvm@runner-trusted.service microvm@runner-untrusted.service")

          rv_main()
          '';
      };
    }
    (lib.mkIf testMode {
      optiplex.runnerVms = {
        stateDir = testStateDir;
        testSizes = {
          vcpu = 2;
          mem = 1536;
          runnerMiB = 64;
          cacheMiB = 6144;
        };
        extraGuestModules = [guestTest];
      };

      # the two VMs run inside the test VM next to every other service: the harness default (6 GB, 4 cores) is too small
      # (the option only exists in the qemu test VMs, so it is guarded by the option declaration, not by testMode)
    })
    (lib.optionalAttrs (options.virtualisation ? memorySize) {
      virtualisation.memorySize = lib.mkIf testMode (lib.mkOverride 500 9216);
      virtualisation.cores = lib.mkIf testMode (lib.mkOverride 500 6);
    })
    (lib.mkIf testMode {
      # pebble's root changes on every start: fetch it before the VMs start, they get it as a credential
      systemd.services = lib.mkMerge [
        {
          gitea-runners-test-ca = {
            description = "Fetch the test CA root for the runner VMs";
            wantedBy = ["multi-user.target"];
            before = map (v: "microvm@${v.name}.service") (lib.attrValues vms);
            path = [pkgs.curl pkgs.coreutils];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              install -d -m 0755 /run/gitea-runners-test
              for i in $(seq 120); do
                if curl -fsS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /run/gitea-runners-test/ca.pem; then
                  chmod 0644 /run/gitea-runners-test/ca.pem
                  exit 0
                fi
                sleep 1
              done
              exit 1
            '';
          };
        }
        (lib.mapAttrs' (_: v:
          lib.nameValuePair "microvm@${v.name}" {
            requires = ["gitea-runners-test-ca.service"];
            after = ["gitea-runners-test-ca.service"];
          })
        vms)
      ];
    })
  ];
}
