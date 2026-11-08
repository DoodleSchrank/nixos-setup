# Scaleway: off-site Backup target

The Optiplex's restic Backup goes to one Scaleway Object Storage bucket. This directory holds the OpenTofu config that creates it. Why Scaleway and why this shape: see the wayfinder tickets *Choose the S3 provider* and *Backup strategy* under `.scratch/optiplex-nixos-migration/`.

## What exists

| Thing | Name / value | Managed by |
|---|---|---|
| Scaleway account | Yannik's, 2FA on, payment method on file | by hand |
| Budget alert | Billing → Budget alerts (about €2/month) | by hand (the provider has no resource for it) |
| Project | `optiplex-backup` (`a9b4d35e-10c0-44ec-97b5-5776d913895b`), holds nothing but the bucket | `main.tf` |
| Bucket | `nnik-optiplex-restic`, region `fr-par`, private, unversioned; aborts incomplete uploads after 1 day; `prevent_destroy` | `main.tf` |
| IAM application | `optiplex-restic`; policy `ObjectStorageFullAccess` on project `optiplex-backup` only | `main.tf` |
| API key of that application | used by restic on the Optiplex | `main.tf` (secret in the state) |

- S3 endpoint: `https://s3.fr-par.scw.cloud`
- restic repository URL: `s3:https://s3.fr-par.scw.cloud/nnik-optiplex-restic`

## Where the secrets are

| Secret | Lives in | Copies |
|---|---|---|
| State passphrase (`TF_VAR_state_passphrase`) | nowhere in the repo | Vaultwarden, printout |
| Bucket key (access key + secret key) | `secrets/optiplex/restic.yaml` (sops) and the encrypted state | Vaultwarden, printout |
| restic repository password | `secrets/optiplex/restic.yaml` (sops) | Vaultwarden, printout |
| Bootstrap API key (your own user) | nowhere; short-lived, made per session | none |

`secrets/optiplex/restic.yaml` has these keys: `repository_password`, `s3_endpoint`, `s3_region`, `s3_bucket`, `s3_access_key_id`, `s3_secret_access_key`. How sops is set up: `secrets/README.md`.

**Without the restic repository password, the Backup cannot be read.** Nobody, Scaleway included, can recover it.

## Running OpenTofu

Requires OpenTofu ≥ 1.8 (the encryption block uses a variable). Plain Terraform cannot read this state.

```sh
cd infra/scaleway
export TF_VAR_state_passphrase='…'                 # from Vaultwarden
# Console → IAM → API keys → generate one for your own user, expiring in ~1 day
export SCW_ACCESS_KEY='…' SCW_SECRET_KEY='…'
export SCW_DEFAULT_ORGANIZATION_ID='…'             # Console → Organization settings
tofu init
tofu plan                                          # should say "No changes"
```

`terraform.tfstate` and `.terraform.lock.hcl` are committed. The state is encrypted (`aes_gcm`, `pbkdf2` passphrase, `enforced = true`). **Never rename** `key_provider "pbkdf2" "main"` or `method "aes_gcm" "main"`: the state would no longer decrypt.

## Recipes

### Rotate the bucket key

```sh
tofu apply -replace=scaleway_iam_api_key.restic
tofu output -raw access_key; echo
tofu output -raw secret_key; echo
cd ../../secrets && sops optiplex/restic.yaml          # replace s3_access_key_id / s3_secret_access_key
```

Then deploy the Optiplex and update Vaultwarden and the printout.

### State lost or passphrase lost

The cloud resources survive; only the bookkeeping is gone.
1. Move the old state files away.
2. Set a new passphrase.
3. Re-adopt the resources (IDs are in the console):
   ```sh
   tofu import scaleway_account_project.backup <project-id>
   tofu import scaleway_object_bucket.restic fr-par/nnik-optiplex-restic
   tofu import scaleway_iam_application.restic <application-id>
   tofu import scaleway_iam_policy.restic <policy-id>
   ```
4. The API key cannot be imported with its secret, so delete the old key in the console and create a fresh one with `tofu apply`. Then put it into sops as under *Rotate the bucket key*.

### Rebuild from nothing (new account)

1. Sign up, turn on 2FA, add a payment method, set the budget alert.
2. Run the commands under *Running OpenTofu*, with `tofu apply` instead of `plan`. Before that, delete the committed state; it belongs to the old account.
3. Bucket names are global across all Scaleway customers, and a deleted name can stay blocked for a while. If the name is taken, change `name` in `main.tf` and in `secrets/optiplex/restic.yaml`.
4. Put the key and a repository password into `secrets/optiplex/restic.yaml`.
5. Initialise the repository from the Optiplex (`restic init`), unless you are restoring an existing one.

### Restore without the Optiplex (disaster recovery)

From any machine with restic, using the values from Vaultwarden or the printout:

```sh
export AWS_ACCESS_KEY_ID='…' AWS_SECRET_ACCESS_KEY='…' AWS_DEFAULT_REGION=fr-par
export RESTIC_REPOSITORY='s3:https://s3.fr-par.scw.cloud/nnik-optiplex-restic'
export RESTIC_PASSWORD='…'
restic snapshots
restic restore latest --target ./restore
```

## Gotchas

- **Storage class.** At Scaleway, the S3 class `STANDARD` means Multi-AZ, which costs twice as much. One Zone is `ONEZONE_IA`. The bucket has no default class, so restic must set it on every upload: `-o s3.storage-class=ONEZONE_IA` (NixOS: `services.restic.backups.<name>.extraOptions`). Check under Object Storage → bucket → objects that new objects show "One Zone".
- **Cost expectations.** About 60 GB stored is about €0.50/month. The weekly `restic check --read-data-subset` reads about 26 GB/month, which stays inside Scaleway's 75 GB of free monthly downloads.
- **`prevent_destroy`** is set on the bucket. `tofu destroy` refuses until you remove it, on purpose.
- **Bootstrap key.** Give it a short expiry, or delete it after use. It has full rights to the account.
