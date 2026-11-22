# haven

NixOS for the ASUS PN51-E1 under the projector. It is a media center for the couch and a remote work box over SSH.

## Layout

- **Nix defines the OS**: `configuration.nix` (+ machine-generated `hardware-configuration.nix`) describes the system and installs all packages.
- **raj's dotfiles**: `zsh/`, `git/` and `nvim/`. The repo is cloned as raj's `~/.config`, so they land in place without symlinking.
- **TV dotfiles**: `tv/niri/` and `tv/foot/`. Nix installs them into `/etc`, because raj's home is still locked when the TV logs in.

## Users and encryption

- **tv** logs in at boot and runs the TV desktop. It has no password, no sudo and no SSH access.
- **raj** is the admin and the only SSH user. Its home is the `raj` volume.

The disk has three partitions:

| Partition | Encryption | Unlocks |
| --- | --- | --- |
| `ESP` | None | - |
| `tv` | LUKS | At boot by the TPM, while Secure Boot is unchanged (PCR 7). The passphrase is the fallback. |
| `raj` | LUKS | Only by its passphrase, with `sudo unlock-raj` |

While the `raj` volume is locked, `/home/raj` is an empty read-only directory. SSH keys still work, because NixOS keeps them in `/etc/ssh/authorized_keys.d`.

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

A minimal-ISO install of this flake straight onto encrypted partitions, then Secure Boot and TPM unlocking.

1. In the BIOS (F2 or Del at power on):

    - **Advanced → Trusted Computing:** keep Security Device Support enabled and Pending Operation at None.
    - **Advanced → Restore AC Power Loss:** set both AC power loss items to Power On, so haven boots by itself after a power cut.
    - **Advanced → HDMI CEC Control:** leave it disabled, so switching the projector off can't shut haven down.
    - **Boot → Secure Boot:** set Factory Key Provision to Disabled first, or the firmware reinstalls its keys on the next boot. Then choose Reset To Setup Mode. In setup mode the firmware boots unsigned images, so the installer still starts.

    Press F10 to save.

2. Download the **Minimal ISO** from [NixOS](https://nixos.org/download/#nixos-iso), then write it to a USB stick:

    ```sh
    lsblk # To find the correct disk
    sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
    ```

3. Boot the stick and choose the installer with the latest kernel, not LTS. haven runs the latest kernel, so Wi-Fi in the installer behaves as it will after install. Then switch to superuser and check that the output shows `Secure Boot: disabled (setup)` and `TPM2 Support: yes`:

    ```sh
    sudo -i
    bootctl
    ```

4. Connect to Wi-Fi:

    ```sh
    nmcli device wifi connect "YOUR-NETWORK" --ask
    ```

5. Find the disk with `lsblk`, then partition it. The config finds the partitions by these names. Size `tv` for the Nix store and Steam games:

    ```sh
    parted -s /dev/nvme0n1 -- mklabel gpt mkpart ESP fat32 1MiB 1GiB set 1 esp on mkpart tv 1GiB 256GiB mkpart raj 256GiB 100%
    ```

6. Encrypt, format and mount the partitions. Use a different passphrase for each volume. The `tv` passphrase is the recovery passphrase for when the TPM refuses:

    ```sh
    cd /dev/disk/by-partlabel
    cryptsetup luksFormat tv
    cryptsetup luksFormat raj
    cryptsetup open tv tv
    cryptsetup open raj raj
    mkfs.ext4 -L tv /dev/mapper/tv
    mkfs.ext4 -L raj /dev/mapper/raj
    mkfs.fat -F32 -n boot ESP
    cryptsetup close raj
    mount /dev/mapper/tv /mnt
    mount -m ESP /mnt/boot
    ```

7. Clone this repo, generate the hardware config into it and create the Secure Boot keys. Flakes only see files git tracks, so the hardware config needs adding:

    ```sh
    git clone https://github.com/siliconwitch/dotfiles-haven /mnt/root/haven
    cd /mnt/root/haven
    nixos-generate-config --root /mnt --dir .
    git add -N hardware-configuration.nix
    nix-shell -p sbctl --run "sbctl create-keys"
    cp -a --parents /var/lib/sbctl /mnt
    ```

8. Install, then set raj's password before rebooting, because SSH accepts passwords. root gets no password; raj uses sudo:

    ```sh
    nixos-install --flake .#haven --no-root-passwd
    nixos-enter -c 'passwd raj'
    reboot
    ```

9. Type the `tv` passphrase at boot. The TV desktop starts on the first console. Press Ctrl+Alt+F2 for a text console, log in as raj and connect to Wi-Fi:

    ```sh
    iwctl station wlan0 connect "YOUR-NETWORK"
    ```

10. Check every boot file is signed, then enroll the keys. The `kernel-` files are expected to be unsigned. Enrolling takes the firmware out of setup mode, so from the next boot it only runs images signed with these keys:

    ```sh
    sudo sbctl verify
    sudo sbctl enroll-keys --microsoft
    sudo reboot
    ```

11. Type the `tv` passphrase again and log in as raj on Ctrl+Alt+F2. Confirm Secure Boot is on, then enroll the TPM. Do this after Secure Boot is on, because turning it on changes PCR 7:

    ```sh
    bootctl # Secure Boot: enabled (user)
    sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/tv
    ```

12. Unlock the `raj` volume, then move the config into place as raj's dotfiles:

    ```sh
    sudo unlock-raj
    sudo chown raj:users /home/raj
    sudo chmod 700 /home/raj

    sudo mv /root/haven /home/raj/.config
    sudo chown -R raj:users /home/raj/.config
    ```

13. Reboot. It should go straight to YouTube without asking for a passphrase. Sign in to YouTube and Steam on the TV.

14. From the laptop, SSH in as raj, unlock the `raj` volume and connect Tailscale:

    ```sh
    ssh -p 3439 raj@<haven's LAN address>
    sudo unlock-raj
    cd ~ && exec zsh -l
    sudo tailscale up
    ```

15. Create an SSH key for GitHub access, then commit the hardware config:

    ```sh
    ssh-keygen -t ed25519 -C "raj@haven"
    cat ~/.ssh/id_ed25519.pub # add at GitHub → Settings → SSH and GPG keys

    git -C ~/.config remote set-url origin git@github.com:siliconwitch/dotfiles-haven.git
    git -C ~/.config add hardware-configuration.nix
    git -C ~/.config commit -m "Add haven hardware config"
    git -C ~/.config push
    ```

16. Log in to Claude Code and GitHub:

    ```sh
    claude
    gh auth login
    ```

## Daily use

The `raj` volume is locked after every boot. Over SSH, unlock it and start a fresh shell so zsh loads raj's config:

```sh
sudo unlock-raj
cd ~ && exec zsh -l
```

To lock it again, close every shell using it, then:

```sh
sudo umount /home/raj
sudo systemctl stop systemd-cryptsetup@raj.service
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
