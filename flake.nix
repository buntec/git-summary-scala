{
  description =
    "git-summary displays a concise status summary for all git repos under a given root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    nix-utils.url = "github:buntec/nix-utils";
  };

  nixConfig = {
    extra-trusted-public-keys =
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = inputs@{ self, nixpkgs, devenv, nix-utils, treefmt-nix, ... }:
    let
      inherit (nixpkgs.lib) genAttrs;

      name = "git-summary";

      version = if (self ? rev) then self.rev else "dirty";

      mkApp = drv: {
        type = "app";
        program = "${drv}/bin/${name}";
      };

      eachSystem = genAttrs [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      buildScalaApp = pkgs: pkgs.callPackage nix-utils.lib.mkBuildScalaApp { };

      mkPackages = pkgs:
        builtins.removeAttrs (buildScalaApp pkgs {
          inherit version;
          src = ./src;
          pname = name;
          supported-platforms = [ "jvm" "native" ];
          depsHash = "sha256-+hSz3top9VNfKPye5jFzXutrjsj5NV+J1EKtSyVu+cw=";
        }) [ "native-debug" "native-release-full" "native-release-size" ];

      treefmtEval = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in treefmt-nix.lib.evalModule pkgs ./treefmt.nix);

    in {

      formatter = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in treefmtEval.${pkgs.system}.config.build.wrapper);

      devShells = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              ({ pkgs, config, ... }: {
                packages = with pkgs; [
                  clang
                  coreutils
                  llvmPackages.libcxxabi
                  nodejs
                  openssl
                  s2n-tls
                  which
                  zlib
                ];
                languages = {
                  java.enable = true;
                  java.jdk.package = pkgs.jdk;
                  scala.enable = true;
                  nix.enable = true;
                };
              })
            ];
          };
        });

      packages = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in mkPackages pkgs);

      apps = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in builtins.mapAttrs (_: value: (mkApp value)) (mkPackages pkgs));

      overlays = {
        default = final: _: { ${name} = (mkPackages final).jvm; };
        native = final: _: {
          ${name} = (mkPackages final).native-release-fast;
        };
      };

      checks = self.packages;

    };

}
