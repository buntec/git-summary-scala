# git-summary

A simple command-line tool that displays a concise status summary of all git repos under a
given root (which defaults to the current working directory).

The tool is written in Scala and heavily inspired
by this [bash script](https://github.com/MirkoLedda/git-summary) of the same name.

If you have [nix](https://nixos.org/download.html) installed and [flakes enabled](https://nixos.wiki/wiki/Flakes#Enable_flakes):

```shell
nix run github:buntec/git-summary-scala#native

# or
nix run github:buntec/git-summary-scala#jvm

# or
nix run github:buntec/git-summary-scala#graal

# or
nix run github:buntec/git-summary-scala#node
```

The flake also contains an appropriate dev shell:
```
nix develop
```
