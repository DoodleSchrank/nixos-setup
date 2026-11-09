# Dry run of rehearsal.sh without real secrets: the Porkbun credentials are dummies, so lego cannot
# issue a staging cert and that check is switched off.
{
  config,
  lib,
  ...
}: {
  optiplex.vmTest.offlineUnits = lib.mkIf config.services.caddy.enable {
    "acme-order-renew-nnik.dev.service" = "dry run: dummy Porkbun credentials";
  };
  optiplex.vmTest.checks.rehearsal-staging-cert.tiers = lib.mkIf config.services.caddy.enable (lib.mkForce []);
}
