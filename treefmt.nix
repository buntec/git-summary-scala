{ pkgs, ... }: {
  projectRootFile = "flake.nix";
  programs.nixfmt.enable = true;
  programs.scalafmt.enable = true;
}
