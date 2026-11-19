# haven

NixOS for the ASUS PN51-E1 under the projector. It is a media center for the couch and a remote work box over SSH.

## Layout

- **Nix defines the OS**: `configuration.nix` (+ machine-generated `hardware-configuration.nix`) describes the system and installs all packages.
- **raj's dotfiles**: `zsh/`, `git/`, `nvim/` and `herdr/`. The repo is cloned as raj's `~/.config`, so they land in place without symlinking.
- **TV dotfiles**: `tv/niri/` and `tv/foot/`. Nix installs them into `/etc`, because raj's home is still locked when the TV logs in.

## Users and encryption

- **tv** logs in at boot and runs the TV desktop. It has no password, no sudo and no SSH access.
- **raj** is the admin and the only SSH user. Its home is the work volume.

The disk has three partitions:

| Partition | Encryption | Unlocks |
| --- | --- | --- |
| `ESP` | None | - |
| `root` | LUKS | At boot by the TPM, while Secure Boot is unchanged (PCR 7). The passphrase is the fallback. |
| `work` | LUKS | Only by its passphrase, with `sudo systemctl start home-raj.mount` |

While the work volume is locked, `/home/raj` is an empty read-only directory. SSH keys still work, because NixOS keeps them in `/etc/ssh/authorized_keys.d`.

## TV desktop

niri with one fullscreen app per workspace:

| Key | Workspace |
| --- | --- |
| Mod+1 | YouTube TV interface |
| Mod+2 | Steam Big Picture |
| Mod+3 | Terminal and browser, side by side |

Mod+T opens a terminal, Mod+B a browser, and Mod+Shift+/ lists every key.

To upscale a game, set its Steam launch options to `gamescope -w 1280 -h 720 -f -F fsr -- %command%`.

## Install

A minimal-ISO install onto encrypted partitions, then a switch to this flake with Secure Boot and TPM unlocking.

1. In the BIOS, enable the firmware TPM and Secure Boot. Put Secure Boot into setup mode by erasing the existing Platform Key. In setup mode the firmware boots unsigned images, so the installer still starts. Some ASUS boards need `OS Type` set to "Windows UEFI Mode" for Secure Boot to turn on. Don't clear every Secure Boot key, because that also drops the forbidden signature database (dbx).

2. Download the **Minimal ISO** from [NixOS](https://nixos.org/download/#nixos-iso), then write it to a USB stick:

    ```sh
    lsblk # To find the correct disk
    sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
    ```

3. Boot the stick and switch to superuser:

    ```sh
    sudo -i
    ```

4. Partition the disk. The names become the partition labels the config refers to. Size `root` for the Nix store and Steam games:

    ```sh
    lsblk # to check which disk to wipe. e.g. nvme0n1
    wipefs -a /dev/nvme0n1

    parted /dev/nvme0n1 -- mklabel gpt
    parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1GiB
    parted /dev/nvme0n1 -- set 1 esp on
    parted /dev/nvme0n1 -- mkpart root 1GiB 128GiB
    parted /dev/nvme0n1 -- mkpart work 128GiB 100%
    ```

5. Set up encryption. Use a different passphrase for each volume. The `root` passphrase is the recovery passphrase for when the TPM refuses:

    ```sh
    cryptsetup luksFormat /dev/disk/by-partlabel/root
    cryptsetup luksFormat /dev/disk/by-partlabel/work

    cryptsetup open /dev/disk/by-partlabel/root cryptroot
    cryptsetup open /dev/disk/by-partlabel/work work

    mkfs.ext4 -L nixos /dev/mapper/cryptroot
    mkfs.ext4 -L work /dev/mapper/work
    mkfs.fat -F32 -n boot /dev/disk/by-partlabel/ESP

    cryptsetup close work

    mount /dev/disk/by-label/nixos /mnt
    mkdir /mnt/boot
    mount /dev/disk/by-label/boot /mnt/boot
    ```

6. Generate the base config and install. Set the root password when asked:

    ```sh
    nixos-generate-config --root /mnt
    nixos-install
    reboot
    ```

7. Log in as `root` and create the Secure Boot keys:

    ```sh
    nix-shell -p sbctl --run "sbctl create-keys"
    ```

8. Clone this repo and switch to it. Flakes only see files git tracks, so the generated hardware config needs adding:

    ```sh
    nix-shell -p git
    git clone https://github.com/siliconwitch/dotfiles-haven /root/haven
    cp /etc/nixos/hardware-configuration.nix /root/haven
    git -C /root/haven add --intent-to-add hardware-configuration.nix

    # Apply the config. This creates the raj and tv users
    nixos-rebuild switch --flake /root/haven#haven
    ```

9. Set raj's password before anything else, because SSH accepts passwords:

    ```sh
    passwd raj
    ```

10. Check every boot file is signed. The `kernel-` files are expected to be unsigned:

    ```sh
    sbctl verify
    ```

11. Enroll the keys. This takes the firmware out of setup mode, so from the next boot it only runs images signed with them:

    ```sh
    sbctl enroll-keys --microsoft
    reboot
    ```

12. Log in as `root` and confirm Secure Boot is on. It should say `Secure Boot: enabled (user)`:

    ```sh
    bootctl status
    ```

13. Enroll the TPM on the root volume. Do this after Secure Boot is on, because turning it on changes PCR 7:

    ```sh
    systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/root
    ```

14. Unlock the work volume, then move the config into place as raj's dotfiles:

    ```sh
    systemctl start home-raj.mount
    chown raj:users /home/raj
    chmod 700 /home/raj

    mv /root/haven /home/raj/.config
    chown -R raj:users /home/raj/.config
    ```

15. Reboot. It should go straight to YouTube without asking for a passphrase. Sign in to YouTube and Steam on the TV.

16. From the laptop, SSH in as raj, unlock the work volume and connect Tailscale:

    ```sh
    ssh -p 3439 raj@<haven's LAN address>
    sudo systemctl start home-raj.mount
    cd ~ && exec zsh -l
    sudo tailscale up
    ```

17. Create an SSH key for GitHub access:

    ```sh
    ssh-keygen -t ed25519 -C "raj@haven"
    cat ~/.ssh/id_ed25519.pub # add at GitHub → Settings → SSH and GPG keys
    ```

18. Log in to Claude Code and GitHub:

    ```sh
    claude
    gh auth login
    ```

19. Install the Herdr plugins. Herdr comes from Nix, but its plugins are git checkouts that Herdr keeps under `~/.config/herdr/plugins/`, outside this repo:

    ```sh
    herdr plugin install persiyanov/herdr-reviewr --yes
    herdr plugin install ChmaraX/herdr-nvim --yes
    ```

## Daily use

The work volume is locked after every boot. Over SSH, unlock it and start a fresh shell so zsh loads raj's config:

```sh
sudo systemctl start home-raj.mount
cd ~ && exec zsh -l
```

To lock it again, close every shell and Herdr session using it, then:

```sh
sudo systemctl stop systemd-cryptsetup@work.service
```

## Rebuilds

After setup, rebuild from raj's shell:

```sh
sudo nixos-rebuild switch --flake ~/.config#haven
```

## Documentation

- NixOS manual: https://nixos.org/manual/nixos/stable/
- Options: https://search.nixos.org/options
- Lanzaboote: https://github.com/nix-community/lanzaboote
- Niri: https://niri-wm.github.io/niri/
- Neovim: https://neovim.io/doc/user/
