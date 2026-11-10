---
status: accepted
---

# Native NixOS everywhere, with container exceptions only where upstream supports nothing else

The Optiplex runs every Kept service natively under NixOS, with no Docker daemon. The one exception is a service whose upstream supports nothing but containers: Seafile runs from upstream's image via podman (`virtualisation.oci-containers`), because upstream dropped non-Docker support for the community edition in 13, nixpkgs removed `services.seafile` in 25.11, and the only native route is an unreviewed, self-maintained nixpkgs PR (#523494).

## Considered options

- **Vendor the unmerged package and module** (rejected): it would make Yannik the maintainer of a package that lags upstream, for the sake of a purely native deployment.
- **Replace Seafile** with Nextcloud, ownCloud Infinite Scale or Syncthing (rejected): it needs a `seaf-fsck` export and loses version history, public share links and the client setup.

## Consequences

- Podman is on the host for Seafile only. The Gitea Actions runners do not use the host's podman. They run in two `microvm.nix` VMs, split by trust, each with its own podman, so job containers never share the host's container runtime (Gitea runner backend and trust model).
- Container-only services still keep their State under `/state/<service>` and use the shared native database server where the image allows it.
- The same exception is available to any other container-only service (elabFTW was considered in ticket 18 and retired instead); extend this ADR rather than adding silent exceptions.
