{
  description =
    "git-summary displays a concise summary of repo statuses for all git repos under a given root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    devshell.url = "github:numtide/devshell";
    typelevel-nix.url = "github:typelevel/typelevel-nix";
    nix-utils.url = "github:buntec/nix-utils";
  };

  outputs = { self, devshell, nixpkgs, nix-utils, typelevel-nix, ... }:
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

    in {

      devShells = eachSystem (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ devshell.overlays.default ];
          };
        in {
          default = pkgs.devshell.mkShell {
            inherit name;
            imports = [ typelevel-nix.typelevelShell ];
            typelevelShell = {
              jdk.package = pkgs.jdk;
              nodejs.enable = true;
              native.enable = true;
              native.libraries = [ pkgs.zlib pkgs.s2n-tls pkgs.openssl ];
            };
            packages = with pkgs; [ coreutils which ];
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
