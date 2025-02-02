{
  description = "uplc-benchmark";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    pre-commit-hooks-nix = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-stable.follows = "nixpkgs";
    };
    hci-effects = {
      url = "github:hercules-ci/hercules-ci-effects";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
    };
  };
  outputs = inputs:
    let
      flakeModules = {
        haskell = ./nix/haskell;
        utils = ./nix/utils;
      };
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } ({ self, ... }: {
      imports = [
        inputs.pre-commit-hooks-nix.flakeModule
        inputs.hci-effects.flakeModule
        ./.
      ] ++ (builtins.attrValues flakeModules);

      # `nix flake show --impure` hack
      systems =
        if builtins.hasAttr "currentSystem" builtins
        then [ builtins.currentSystem ]
        else inputs.nixpkgs.lib.systems.flakeExposed;

      herculesCI.ciSystems = [ "x86_64-linux" ];

      flake.flakeModules = flakeModules;

      perSystem =
        { config
        , pkgs
        , lib
        , system
        , self'
        , ...
        }: {
          _module.args.pkgs = import self.inputs.nixpkgs {
            inherit system;
            config.allowBroken = true;
          };

          pre-commit.settings = {
            hooks = {
              deadnix.enable = true;
              # TODO: Enable in separate PR, causes mass changes.
              # fourmolu.enable = true;
              nixpkgs-fmt.enable = true;
            };

            tools = {
              fourmolu = lib.mkForce (pkgs.callPackage ./nix/fourmolu {
                mkHaskellPackage = config.libHaskell.mkPackage;
              });
            };
          };

          devShells = {
            default = pkgs.mkShell {
              shellHook = config.pre-commit.installationScript;

              inputsFrom = [
                self'.devShells.purus
              ];
            };
          };
        };
    });
}
