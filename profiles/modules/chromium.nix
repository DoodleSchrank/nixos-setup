{pkgs, config, ...}: {
  nixpkgs.config.packageOverrides = pkgs: {
    chromium = pkgs.chromium.override {
      enableWideVine = true;
      commandLineArgs = [
        "--enable-features=VaapiVideoDecodeLinuxGL"
        "--ignore-gpu-blocklist"
        "--enable-zero-copy"
      ];
    };
  };
  programs.chromium = {
    enable = true;
    #environment.sessionVariables.NIXOS_OZONE_WL = "1";
    extensions = [
      "eimadpbcbfnmbkopoojfekhnkhdbieeh" # better darkmode
      "aapbdbdomjkkjkaonfhkkikfgjllcleb" # translate

      "cjpalhdlnbpafiamejdnhcphjbkeiagm" # ublock origin
      "lckanjgmijmafbedllaakclkaicjfmnk" # clearurl
      "fhcgjolkccmbidfldomjliifgaodjagh" # cookie autodelete
      "gcbommkclmclpchllfjekcdonpmejbdp" # https everywhere (currently borked?)
      "fihnjjcciajhdojfnbdddfaoknhalnja" # no cookies pls
      "pkehgijcmpdhfbdbbnkijodmdjhbjlgp" # privacy badger c:
      "ogfcmafjalglgifnmanfmnieipoejdcf" # umatrix
      "gbobdaaeaihkghbokihkofcbndhmbdpd" # unshorten link
      "dbepggeogbaibhgnhhndojpepiihcmeb" # vimium

      "cahpmepdjiejandeladmhfpapeagobnp" # advanced image search
      "nngceckbapebfimnlniiiahkandclblb" # bitwarden
      "egmanfnfgmljjmdncfoeghfmflhlmhpj" # letterboxd streaming
      "oocalimimngaihdkbihfgmpkcpnmlaoa" # teleparty
      "gmmnidkpkgiohfdoenhpghbilmeeagjj" # sci hub steals
      "mnjggcdmjocbbbhaepdhchncahnbgone" # sponsorblock for yt/inv
      "ailoabdmgclmfmhdagmlohpjlbpffblp" # surfshark vpn
    ];

    commandLineArgs = ["--enable-features=UseOzonePlatform" "--ozone-platform=wayland"];
  };
}
