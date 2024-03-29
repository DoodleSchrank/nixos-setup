{
  services.nginx = {
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    commonHttpConfig = ''
      # Add HSTS header with preloading to HTTPS requests.
      # Adding this header to HTTP requests is discouraged
      map $scheme $hsts_header {
          https   "max-age=31536000; includeSubdomains; preload";
      }
      add_header Strict-Transport-Security $hsts_header;

      # Enable CSP for your services.
      #add_header Content-Security-Policy "script-src 'self'; object-src 'none'; base-uri 'none';" always;

      # Minimize information leaked to other domains
      add_header 'Referrer-Policy' 'origin-when-cross-origin';

      # Disable embedding as a frame
      add_header X-Frame-Options DENY;

      # Prevent injection of code in other mime types (XSS Attacks)
      add_header X-Content-Type-Options nosniff;

      # Enable XSS protection of the browser.
      # May be unnecessary when CSP is configured properly (see above)
      add_header X-XSS-Protection "1; mode=block";

      # This might create errors
      proxy_cookie_path / "/; secure; HttpOnly; SameSite=strict";
    '';
    sslCiphers = "AES256+EECDH:AES256+EDH:!aNULL";

    virtualHosts = {
      "nnik.dev" = {
        serverAliases = ["www.nnik.dev" "nnik.dev"];
        listen = [
          {
            addr = "[::]";
            port = 443;
            ssl = true;
            extraParameters = ["ipv6only=on"];
          }
          {
            port = 443;
            ssl = true;
          }
          {
            addr = "[::]";
            port = 8448;
            ssl = true;
            extraParameters = ["ipv6only=on" "http3"];
          }
          {
            port = 8448;
            ssl = true;
            extraParameters = ["http3"];
          }
        ];
        addSSL = true;
        enableACME = true;
        locations."~ ^(/_matrix|/_synapse/client)" = {
          proxyPass = "http://localhost:8008";
          extraConfig =
            "proxy_set_header X-Forwarded-For $remote_addr;"
            + "proxy_set_header X-Forwarded-Proto $scheme;"
            + "proxy_set_header Host $host;"
            + "client_max_body_size 200M;"
            + "proxy_http_version 1.1;";
        };
      };
    };
  };
}
