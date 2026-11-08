# Off-site restic Backup target for the Optiplex (Scaleway Object Storage, fr-par).
#
# Creates a dedicated project holding only the backup bucket, plus an IAM
# application whose API key can reach nothing outside that project.
#
# Usage (OpenTofu >= 1.8, needs variables inside the encryption block):
#   export TF_VAR_state_passphrase=...   # from Vaultwarden, >= 16 chars
#   export SCW_ACCESS_KEY=... SCW_SECRET_KEY=...   # short-lived bootstrap key of your own user
#   export SCW_DEFAULT_ORGANIZATION_ID=...
#   tofu init && tofu apply
#   tofu output -raw secret_key   # -> secrets/optiplex/restic.yaml via sops
#
# The state holds the bucket key's secret, so it is encrypted (see below) and
# committed; without the passphrase it cannot be read or changed.
#
# restic must upload with `-o s3.storage-class=ONEZONE_IA`: at Scaleway the
# default class STANDARD is Multi-AZ at twice the price.

variable "state_passphrase" {
  type      = string
  sensitive = true
}

terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
  }

  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }
    state {
      method   = method.aes_gcm.main
      enforced = true
    }
    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}

provider "scaleway" {
  region = "fr-par"
  zone   = "fr-par-1"
}

resource "scaleway_account_project" "backup" {
  name        = "optiplex-backup"
  description = "Off-site restic Backup of the Optiplex"
}

resource "scaleway_object_bucket" "restic" {
  name       = "nnik-optiplex-restic"
  region     = "fr-par"
  project_id = scaleway_account_project.backup.id

  # Interrupted uploads would otherwise keep costing storage.
  lifecycle_rule {
    id                                     = "abort-incomplete-uploads"
    enabled                                = true
    abort_incomplete_multipart_upload_days = 1
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "scaleway_iam_application" "restic" {
  name        = "optiplex-restic"
  description = "restic on the Optiplex"
}

resource "scaleway_iam_policy" "restic" {
  name           = "optiplex-restic-backup-bucket"
  application_id = scaleway_iam_application.restic.id

  rule {
    project_ids          = [scaleway_account_project.backup.id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }
}

resource "scaleway_iam_api_key" "restic" {
  application_id     = scaleway_iam_application.restic.id
  default_project_id = scaleway_account_project.backup.id
  description        = "restic on the Optiplex"
}

output "bucket" {
  value = scaleway_object_bucket.restic.name
}

output "endpoint" {
  value = "s3.fr-par.scw.cloud"
}

output "region" {
  value = scaleway_object_bucket.restic.region
}

output "access_key" {
  value = scaleway_iam_api_key.restic.access_key
}

output "secret_key" {
  value     = scaleway_iam_api_key.restic.secret_key
  sensitive = true
}
