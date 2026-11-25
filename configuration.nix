{ config, pkgs, lib, ... }:

{
  # Nix base settings
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };

  # Boot & kernel. Lanzaboote replaces systemd-boot and signs every boot entry for Secure Boot
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # tv volume. The TPM releases its key while PCR 7 (Secure Boot state) matches, otherwise it asks for the passphrase
  boot.initrd.luks.devices.tv.crypttabExtraOpts = [ "tpm2-device=auto" ];

  # raj volume, mounted as raj's home. Only its passphrase opens it, so raj's first login after boot unlocks it
  environment.etc.crypttab.text = ''
    raj /dev/disk/by-partlabel/raj none noauto
  '';
  # The login shell starts in the locked directory, so it moves into the mounted home and restarts to load raj's config
  programs.zsh.loginShellInit = ''
    if [[ $USER == raj ]] && ! mountpoint -q /home/raj; then
      sudo systemctl start systemd-cryptsetup@raj.service &&
        sudo mount /dev/mapper/raj /home/raj &&
        cd ~ && exec zsh -l
    fi
  '';
  # While locked, /home/raj is this read-only directory on the tv volume, so nothing lands there unencrypted.
  # Boot only (!), because a rebuild would otherwise reset the mounted volume's ownership
  systemd.tmpfiles.rules = [ "d! /home/raj 0555 root root -" ];

  # Hardware & firmware
  hardware.enableAllFirmware = true;
  hardware.graphics.enable = true;
  hardware.bluetooth.enable = true;

  # Audio
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Networking
  networking.hostName = "haven";
  networking.wireless.iwd.enable = true;
  networking.wireless.iwd.settings.Rank.BandModifier5GHz = 2.0;
  networking.wireless.iwd.settings.DriverQuirks.PowerSaveDisable = "iwlwifi";
  services.tailscale = {
    enable = true;
    openFirewall = true;
  };
  # Per-link DNS, so Tailscale only answers for its own domain
  services.resolved.enable = true;

  # Swap
  zramSwap.enable = true;

  # SSH. Passwords stay on for emergency access from a borrowed device
  services.openssh = {
    enable = true;
    ports = [ 3439 ];
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
      AllowUsers = [ "raj" ];
      MaxAuthTries = 3;
      ClientAliveInterval = 15;
      ClientAliveCountMax = 3;
    };
  };

  # Localisation
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  # Fonts
  fonts.packages = with pkgs; [
    nerd-fonts.roboto-mono
    noto-fonts-color-emoji
  ];

  # TV desktop. tv logs in on boot and gets niri and foot configs from /etc, since raj's ~/.config is locked at boot
  programs.niri.enable = true;
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "${pkgs.niri}/bin/niri-session";
        user = "tv";
      };
      default_session = initial_session;
    };
  };
  environment.etc."niri/config.kdl".source = ./tv/niri/config.kdl;
  environment.etc."xdg/foot/foot.ini".source = ./tv/foot/foot.ini;

  # Projector power. niri's Mod+Escape starts this as tv, so it runs as root with its own ADB key and server
  systemd.services.projector-toggle = {
    path = [ pkgs.android-tools pkgs.iputils config.hardware.bluetooth.package ];
    environment = {
      HOME = "/var/lib/projector-toggle";
      ANDROID_SERIAL = "169.254.1.2:5555";
      ANDROID_ADB_SERVER_PORT = "5038"; # apart from any adb server raj runs
    };
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "projector-toggle";
    };
    script = ''
      # HDMI 1, which the projector labels "TV"
      show_haven() {
        for attempt in $(seq 10); do
          adb shell am start -a android.intent.action.VIEW -d content://android.media.tv/passthrough/com.droidlogic.tvinput%2F.services.Hdmi1InputService%2FHW5
          sleep 2
          if adb shell dumpsys activity activities | grep -m1 mResumedActivity | grep -q com.android.tv/; then
            return 0
          fi
        done

        echo "projector did not switch to HDMI 1" >&2
        return 1
      }

      # The projector's Ethernet only answers while it is on or in soft sleep
      if ping -c1 -W1 169.254.1.2; then
        adb connect $ANDROID_SERIAL
        timeout 5 adb wait-for-device

        if adb shell dumpsys power | grep -q mWakefulness=Asleep; then
          adb shell input keyevent KEYCODE_WAKEUP
          show_haven
          exit 0
        fi

        adb shell input keyevent KEYCODE_POWER # opens the power menu on Power off
        sleep 1
        adb shell input keyevent KEYCODE_POWER
        exit 0
      fi

      # The controller briefly disappears after an address change, and btmgmt exits 0 even when it fails
      set_address() {
        btmgmt power off
        btmgmt public-addr $1
        for attempt in $(seq 50); do
          if info=$(btmgmt info) && grep -q "addr $1" <<< "$info" && grep -q "current settings: powered" <<< "$info"; then
            return 0
          fi

          btmgmt power on
          sleep 0.1
        done

        echo "Bluetooth controller did not return with address $1" >&2
        return 1
      }

      hci() {
        read -ra reply <<< "$(hcitool -i hci0 cmd 0x08 "$@" | tail -n1)"
        [[ ''${reply[@]: -1} == 00 ]]
      }

      # When fully off, the projector wakes only for its paired remote's address and wake advertisement
      haven_address=84:5C:F3:AA:2F:CF
      trap 'set_address $haven_address' EXIT
      set_address 18:BF:1C:50:8A:D1
      hci 0x0006 20 00 20 00 00 00 00 00 00 00 00 00 00 07 00
      hci 0x0008 1f 02 01 05 03 ff 00 01 06 08 4d 49 20 52 43 03 02 12 18 04 0d 04 05 00 02 0a 00 04 fe 73 ce f6
      hci 0x000a 01
      sleep 10
      hci 0x000a 00
      set_address $haven_address
      trap - EXIT

      for attempt in $(seq 90); do
        if ping -c1 -W1 169.254.1.2 >/dev/null && adb connect $ANDROID_SERIAL >/dev/null &&
          timeout 5 adb wait-for-device && [[ $(adb shell getprop sys.boot_completed) == 1* ]]; then
          show_haven
          exit 0
        fi

        sleep 2
      done

      echo "projector did not boot after the wake advertisement" >&2
      exit 1
    '';
  };
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "projector-toggle.service" &&
          action.lookup("verb") == "start" &&
          subject.user == "tv") {
        return polkit.Result.YES;
      }
    });
  '';

  # Storage Box backup. A nightly copy of the box, keeping deleted and overwritten files for 30 days
  systemd.services.storagebox-backup = {
    startAt = "04:00";
    path = [ pkgs.rclone pkgs.openssh ];
    environment.RCLONE_SFTP_SSH = "ssh storagebox"; # host, user and key are in raj's ~/.ssh/config, outside this public repo
    unitConfig.ConditionPathIsMountPoint = "/home/raj"; # skips the run while the raj volume is locked
    serviceConfig = {
      Type = "oneshot";
      User = "raj";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    script = ''
      backup=/home/raj/storagebox
      rclone sync :sftp: "$backup/current" --backup-dir "$backup/deleted/$(date +%F-%H%M%S)" --exclude "/.zfs/**" --exclude "/.ssh/**"

      shopt -s nullglob
      cutoff=$(date -d "30 days ago" +%F)
      for folder in "$backup"/deleted/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*; do
        if [[ $(basename "$folder") < $cutoff ]]; then
          rm -rf "$folder"
        fi
      done

      touch "$backup/last-success" # read by raj's zsh prompt
    '';
  };

  # Games
  programs.steam.enable = true;
  programs.gamescope.enable = true;

  # Shell
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    autosuggestions.strategy = [ "history" "completion" ];
    syntaxHighlighting.enable = true;
    histFile = "$HOME/.local/state/zsh/history";
    # Plugins with no NixOS module of their own. mkAfter so they load after
    # syntax-highlighting (history-substring-search must come after it).
    interactiveShellInit = lib.mkAfter ''
      source /run/current-system/sw/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh
      source /run/current-system/sw/share/zsh/plugins/you-should-use/you-should-use.plugin.zsh
    '';
  };
  environment.sessionVariables.ZDOTDIR = "$HOME/.config/zsh";

  # Editor
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  # Users. raj is the admin and remote work user. tv has no password and only logs in through greetd
  users.users.raj = {
    isNormalUser = true;
    createHome = false; # the raj volume is the home
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbUyYSBFm1JuOP0dWsuy9P02o2fvzG3oUeI2rsupBmi raj@ipad"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG30AAEq/at4v6HPcINPIaYaiuF3UokvzRUZtw5Jr1TY raj@iphone"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINWhV+6HsbjeLTeoCvkrxqJNXKPD+hWXSi9p1raDWCe0 Lenovo Yoga SSH Key"
    ];
  };
  users.users.tv = {
    isNormalUser = true;
  };

  # Packages
  environment.systemPackages = with pkgs; [
    # TV
    android-tools                    # adb, for the projector
    chromium
    foot                             # terminal
    pulseaudio                       # pactl (talks to pipewire-pulse)
    xwayland-satellite               # X11 support, for Steam

    # Shell plugins
    zsh-completions
    zsh-history-substring-search
    zsh-you-should-use

    # Terminal apps & tools
    bluetui                          # Bluetooth TUI
    btop                             # system monitor
    claude-code
    eza                              # ls/tree
    fd                               # find alternative
    fzf                              # fuzzy finder
    gh                               # Github CLI
    git
    impala                           # Wi-Fi TUI
    jq                               # JSON processor
    netcat-openbsd                   # nc (zsh prompt)
    ripgrep                          # rg
    sbctl                            # Secure Boot keys
    trash-cli                        # rm alias
    unzip
    wiremix                          # PipeWire TUI mixer
    yazi                             # file manager
    zoxide                           # cd
    zip

    # Languages & LSPs
    clang                            # C/C++ toolchain
    clang-tools                      # clangd, clang-format
    gnumake                          # make
    go
    gopls                            # Go LSP
    lua-language-server              # Lua LSP
    nil                              # nix LSP
    nodejs                           # node + npm
    python3
    tree-sitter                      # Parser CLI for nvim-treesitter
  ];

  # Specific to projects & apps
  programs.direnv.enable = true;
  nixpkgs.overlays = [
    (final: prev: {
      # Prevent chrome bugging us for passwords
      chromium = prev.chromium.override {
        commandLineArgs = "--password-store=basic";
      };
    })
  ];

  system.stateVersion = "26.11";
}
