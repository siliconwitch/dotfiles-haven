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

  # raj volume, mounted as raj's home. Only its passphrase opens it, so it stays locked after boot
  # until `sudo unlock-raj`. It has no fileSystems entry, because systemd makes every raj login wait for one
  environment.etc.crypttab.text = ''
    raj /dev/disk/by-partlabel/raj none noauto
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
  # The router doesn't steer bands (steering crashes the 8265's firmware), so prefer 5 GHz here
  networking.wireless.iwd.settings.Rank.BandModifier5GHz = 2.0;
  # With power saving on, the router holds haven's downlink while the card sleeps: <1 MB/s and seconds of lag
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
    (writeShellScriptBin "unlock-raj" ''
      set -e
      systemctl start systemd-cryptsetup@raj.service
      mountpoint -q /home/raj || mount /dev/mapper/raj /home/raj
    '')
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
