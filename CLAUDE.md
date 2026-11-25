# haven

## Make changes directly on haven

haven builds from its own clone of this repo at `~/.config`. Edit that clone directly over SSH, not this one.

1. Check for the user's SSH control socket:

   ```sh
   ssh -O check -o ControlPath=/tmp/haven.sock raj@100.124.153.39
   ```

   If no master is running, open one:

   ```sh
   ssh -f -N -p 3439 -o ControlMaster=yes -o ControlPath=/tmp/haven.sock -o ControlPersist=yes raj@100.124.153.39
   ```

   If the check reports a master but commands through it fail, the master is stale. Ask the user to close it.

2. Run commands through the socket with `ssh -o ControlPath=/tmp/haven.sock raj@100.124.153.39 '<command>'`.
3. If `/home/raj` on haven is empty, the `raj` volume is locked. Ask the user to unlock it by logging in to haven.
4. Before editing, pull haven's clone so it matches `origin/main`.
5. Make the change in `~/.config`, then ask the user to rebuild on haven:

   ```sh
   sudo nixos-rebuild switch --flake ~/.config#haven
   ```
