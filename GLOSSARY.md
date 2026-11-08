# NixOS Setup

Declarative configuration for Yannik's machines (desktops, laptops, and the home server), built from one flake.

## Home server

**Optiplex**:
The home server, a Dell OptiPlex reachable as `optiplex`, hosting all self-hosted services.
_Avoid_: the server (ambiguous once more hosts exist), opti.plex (that's its LAN domain)

**System disk**:
The Optiplex's NVMe drive holding only the operating system; wiped and re-created during the cutover.
_Avoid_: root disk, boot disk

**Data disk**:
The Optiplex's 3.6 TB drive holding all State and the large files (torrents, cloud files); survives the cutover untouched.
_Avoid_: tbssd, storage disk

**State**:
Everything a service needs to survive a reinstall that isn't expressed in the Nix configuration: databases, uploads, keys, registrations.
_Avoid_: data (too broad), config

**State folder**:
The single, obviously named directory (`/state`) under which every Kept service keeps its State, one subdirectory per service. It lives on the Data disk, so wiping the System disk never touches State.
_Avoid_: persist (implies impermanence, which this setup does not use)

**Kept service**:
A service running on the Optiplex today that will run on the NixOS Optiplex after the cutover.

**Retired service**:
A service running (or lingering) on the Optiplex today that is deliberately not carried over; its State survives only in the rollback image.
_Avoid_: dropped, removed

**Own app**:
A kept service whose source Yannik maintains himself (e.g. battle-tracker), as opposed to third-party software.

## Migration

**Cutover**:
The single window in which the System disk is wiped, NixOS is installed, and State is restored.
_Avoid_: switch, migration day

**Rollback image**:
A full copy of the Arch System disk taken onto the Data disk immediately before the cutover, used to restore Arch if the cutover fails.
_Avoid_: backup (that's the ongoing backup system)

**Archive**:
A small folder on the Data disk holding System-disk files that are not State but are worth keeping after the Rollback image is gone.
_Avoid_: backup, Rollback image

**Backup**:
The ongoing, scheduled copy of State (and selected Data disk files) kept after the cutover.
