# haven

## Commit and push before asking for a rebuild

haven builds from its own clone of this repo at `~/.config`. A change made anywhere else reaches haven only after it is pushed.

When a requested change needs a rebuild, commit and push it before giving the user these steps to run on haven:

```sh
git -C ~/.config pull
sudo nixos-rebuild switch --flake ~/.config#haven
```

If the change doesn't work, fix it in a new commit and push that too.

Don't try to edit haven's clone over SSH. Commands run over SSH can't unlock the `raj` volume, so `/home/raj` is empty to them.
