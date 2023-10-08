{
  description = "A simple Scala app";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.devshell.url = "github:numtide/devshell";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-compat = {
    url = "github:edolstra/flake-compat";
    flake = false;
  };

  outputs = { self, flake-utils, devshell, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # remove unsupported platforms from this list
        supported-platforms = [ "jvm" "graal" "native" "node" ];

        supports-jvm = builtins.elem "jvm" supported-platforms;
        supports-native = builtins.elem "native" supported-platforms;
        supports-graal = builtins.elem "graal" supported-platforms;
        supports-node = builtins.elem "node" supported-platforms;

        scala-native-version = "0.4.15";

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ devshell.overlays.default ];
        };

        jdk = pkgs.jdk19_headless;
        graal-jdk = pkgs.graalvm-ce;
        sbt = pkgs.sbt.override { jre = jdk; };
        metals = pkgs.metals.override { jre = jdk; };
        scala-cli = pkgs.scala-cli.override { jre = jdk; };
        node = pkgs.nodejs;

        native-packages = [
          pkgs.clang
          pkgs.coreutils
          pkgs.llvmPackages.libcxxabi
          pkgs.openssl
          pkgs.s2n-tls
          pkgs.which
          pkgs.zlib
        ];

        build-packages = [ jdk scala-cli ]
          ++ (if (supports-native || supports-graal) then
            native-packages
          else
            [ ]);

        # fixed-output derivation: to nix'ify scala-cli,
        # we must hash the coursier caches created during the build
        coursier-cache = pkgs.stdenv.mkDerivation {
          name = "coursier-cache";
          src = ./src;

          buildInputs = build-packages;

          SCALA_CLI_HOME = "./scala-cli-home";
          COURSIER_CACHE = "./coursier-cache/v1";
          COURSIER_ARCHIVE_CACHE = "./coursier-cache/arc";
          COURSIER_JVM_CACHE = "./coursier-cache/jvm";

          # run the same build as our main derivation
          # to populate the cache with the correct set of dependencies
          buildPhase = ''
            mkdir scala-cli-home
            mkdir -p coursier-cache/v1
            mkdir -p coursier-cache/arc
            mkdir -p coursier-cache/jvm
            scala-cli compile . --java-home=${jdk} --server=false
            ${if (supports-native) then
              "scala-cli compile . --native --native-version ${scala-native-version} --java-home=${jdk} --server=false"
            else
              ""}
            ${if (supports-node) then
              "scala-cli compile . --js --js-module-kind common --java-home=${jdk} --server=false"
            else
              ""}
          '';

          installPhase = ''
            mkdir -p $out/coursier-cache
            cp -R ./coursier-cache $out
          '';

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          # NOTE: don't forget to update this when deps/platforms change!
          outputHash = "sha256-hagKQcBvFdrTwSOgrDp78lkgj73iybe9dmynGmjynKI=";
        };

        scala-native-app = native-mode:
          pkgs.stdenv.mkDerivation {
            name = "scala-native-app";
            src = ./src;
            buildInputs = build-packages ++ [ coursier-cache ];

            JAVA_HOME = "${jdk}";
            SCALA_CLI_HOME = "./scala-cli-home";
            COURSIER_CACHE = "${coursier-cache}/coursier-cache/v1";
            COURSIER_ARCHIVE_CACHE = "${coursier-cache}/coursier-cache/arc";
            COURSIER_JVM_CACHE = "${coursier-cache}/coursier-cache/jvm";

            buildPhase = ''
              mkdir scala-cli-home
              scala-cli --power \
                package . \
                --native \
                --native-version ${scala-native-version} \
                --native-mode ${native-mode} \
                --java-home=${jdk} \
                --server=false \
                -o app 
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp app $out/bin
            '';
          };

        scala-native-app-debug = scala-native-app "debug";
        scala-native-app-release-fast = scala-native-app "release-fast";
        scala-native-app-release-full = scala-native-app "release-full";
        scala-native-app-release-size = scala-native-app "release-size";

        jvm-app = pkgs.stdenv.mkDerivation {
          name = "jvm-app";
          src = ./src;
          buildInputs = build-packages ++ [ coursier-cache ];

          JAVA_HOME = "${jdk}";
          SCALA_CLI_HOME = "./scala-cli-home";
          COURSIER_CACHE = "${coursier-cache}/coursier-cache/v1";
          COURSIER_ARCHIVE_CACHE = "${coursier-cache}/coursier-cache/arc";
          COURSIER_JVM_CACHE = "${coursier-cache}/coursier-cache/jvm";

          buildPhase = ''
            mkdir scala-cli-home
            scala-cli --power \
              package . \
              --standalone \
              --java-home=${jdk} \
              --server=false \
              -o app 
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp app $out/bin
          '';
        };

        node-app = js-mode:
          pkgs.stdenv.mkDerivation {
            name = "scala-js-app";
            src = ./src;
            buildInputs = build-packages ++ [ node coursier-cache ];

            JAVA_HOME = "${jdk}";
            SCALA_CLI_HOME = "./scala-cli-home";
            COURSIER_CACHE = "${coursier-cache}/coursier-cache/v1";
            COURSIER_ARCHIVE_CACHE = "${coursier-cache}/coursier-cache/arc";
            COURSIER_JVM_CACHE = "${coursier-cache}/coursier-cache/jvm";

            buildPhase = ''
              mkdir scala-cli-home
              scala-cli --power \
                package . \
                --js \
                --js-module-kind common \
                --js-mode ${js-mode} \
                --java-home=${jdk} \
                --server=false \
                -o main.js
            '';

            # We wrap `main.js` by a simple wrapper script that
            # essentially invokes `node main.js` - is this a good idea?
            # Note: the shebang below will be patched by nix
            installPhase = ''
              mkdir -p $out/bin
              cp main.js $out/bin
              cat << EOF > app
              #!/usr/bin/env sh
              ${node}/bin/node $out/bin/main.js
              EOF
              chmod +x app
              cp app $out/bin
            '';
          };

        node-app-dev = node-app "dev";
        node-app-release = node-app "release";

        graal-native-image-app = pkgs.stdenv.mkDerivation {
          name = "graal-native-image-app";
          src = ./src;
          buildInputs = build-packages ++ [ graal-jdk coursier-cache ];

          JAVA_HOME = "${graal-jdk}";
          SCALA_CLI_HOME = "./scala-cli-home";
          COURSIER_CACHE = "${coursier-cache}/coursier-cache/v1";
          COURSIER_ARCHIVE_CACHE = "${coursier-cache}/coursier-cache/arc";
          COURSIER_JVM_CACHE = "${coursier-cache}/coursier-cache/jvm";

          buildPhase = ''
            mkdir scala-cli-home
            ls ${coursier-cache}
            scala-cli --power \
              package . \
              --native-image \
              --java-home ${graal-jdk} \
              --server=false \
              --graalvm-args --verbose \
              --graalvm-args --native-image-info \
              --graalvm-args --no-fallback \
              --graalvm-args --initialize-at-build-time=scala.runtime.Statics$$VM \
              --graalvm-args --initialize-at-build-time=scala.Symbol \
              --graalvm-args --initialize-at-build-time=scala.Symbol$$ \
              --graalvm-args -H:-CheckToolchain \
              --graalvm-args -H:+ReportExceptionStackTraces \
              --graalvm-args -H:-UseServiceLoaderFeature \
              -o app \
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp app $out/bin
          '';
        };

        devShell = pkgs.devshell.mkShell {
          name = "scala-dev-shell";
          commands =
            [ { package = scala-cli; } { package = sbt; } { package = node; } ];
          packages = build-packages ++ [ sbt metals ];
          env = [
            {
              name = "JAVA_HOME";
              value = "${jdk}";
            }
            {
              name = "LIBRARY_PATH";
              prefix = "$DEVSHELL_DIR/lib:${pkgs.openssl.out}/lib";
            }
            {
              name = "C_INCLUDE_PATH";
              prefix = "$DEVSHELL_DIR/include";
            }
            {
              name = "LLVM_BIN";
              value = "${pkgs.clang}/bin";
            }
          ];
        };

      in rec {
        devShells.default = devShell;

        packages = (if (supports-native) then rec {
          native-release-full = scala-native-app-release-full;
          native-release-fast = scala-native-app-release-fast;
          native-release-size = scala-native-app-release-size;
          native-debug = scala-native-app-debug;
          native = native-release-fast;
          default = native;
        } else
          { }) // (if (supports-node) then rec {
            node-release = node-app-release;
            node-dev = node-app-dev;
            node = node-release;
            default = node;
          } else
            { }) // (if (supports-graal) then rec {
              graal = graal-native-image-app;
              default = graal;
            } else
              { }) // (if (supports-jvm) then rec {
                jvm = jvm-app;
                default = jvm;
              } else
                { });

        apps = builtins.mapAttrs (name: value: {
          type = "app";
          program = "${value}/bin/app";
        }) packages;

      });
}
