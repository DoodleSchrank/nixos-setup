{
  services.blocky = {
    enable = true;
    settings = ''
      log:
        level: warn
      upstream:
        default:
          - 1.1.1.1
          - 1.0.0.1
          - 8.8.8.8
      upstreamTimeout: 5s
      customDNS:
        mapping:
          opti.plex: 192.168.178.20
      blocking:
        blackLists:
          ads:
            - https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
            - https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt
            - https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt
            - https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt
            - https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts
            - https://v.firebog.net/hosts/static/w3kbl.txt
            - https://raw.githubusercontent.com/matomo-org/referrer-spam-blacklist/master/spammers.txt
            - https://raw.githubusercontent.com/VeleSila/yhosts/master/hosts
            - https://winhelp2002.mvps.org/hosts.txt
            - https://v.firebog.net/hosts/neohostsbasic.txt
            - https://raw.githubusercontent.com/RooneyMcNibNug/pihole-stuff/master/SNAFU.txt
            - https://paulgb.github.io/BarbBlock/blacklists/hosts-file.txt
            - https://adaway.org/hosts.txt
            - https://v.firebog.net/hosts/AdguardDNS.txt
            - https://v.firebog.net/hosts/Admiral.txt
            - https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt
            - https://v.firebog.net/hosts/Easylist.txt
            - https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext
            - https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts
            - https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts
            - https://raw.githubusercontent.com/jdlingyu/ad-wars/master/hosts
            - https://v.firebog.net/hosts/Easyprivacy.txt
            - https://v.firebog.net/hosts/Prigent-Ads.txt
            - https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts
            - https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt
            - https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt
            - https://hostfiles.frogeye.fr/multiparty-trackers-hosts.txt
            - https://www.github.developerdan.com/hosts/lists/ads-and-tracking-extended.txt
            - https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/android-tracking.txt
            - https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt
            - https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/AmazonFireTV.txt
            - https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-blocklist.txt
            - https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt
            - https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt
            - https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt
            - https://v.firebog.net/hosts/Prigent-Crypto.txt
            - https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts
            - https://bitbucket.org/ethanr/dns-blacklists/raw/8575c9f96e5b4a1308f2f12394abd86d0927a4a0/bad_lists/Mandiant_APT1_Report_Appendix_D.txt
            - https://phishing.army/download/phishing_army_blocklist_extended.txt
            - https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt
            - https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt
            - https://raw.githubusercontent.com/Te-k/stalkerware-indicators/master/generated/hosts
            - https://urlhaus.abuse.ch/downloads/hostfile/
            - https://v.firebog.net/hosts/Prigent-Malware.txt
        clientGroupsBlock:
          default:
            - ads
        blockType: nxDomain
        refreshPeriod: 48h
        startStrategy: blocking
        processingConcurrency: 10
      caching:
        minTime: 5m
        maxTime: 30m
        prefetching: true
      hostsFile:
        filePath: /etc/hosts
        hostsTTL: 24h
    '';
  };
}
