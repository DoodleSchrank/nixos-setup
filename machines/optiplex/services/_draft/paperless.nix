{
  services.paperless = {
    enable = true;
    dataDir = /srv/paperless;
    port = 25575;
    extraConfig = {
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_DBHOST = "/run/postgresql";
      PAPERLESS_CONSUMER_IGNORE_PATTERN = builtins.toJSON [".DS_STORE/*" "desktop.ini"];
      PAPERLESS_OCR_USER_ARGS = builtins.toJSON {
        optimize = 1;
        pdfa_image_compression = "lossless";
      };
    };
  };
}
