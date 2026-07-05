{
  description = "Jesse — a trading framework for cryptocurrencies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, pyproject-nix, uv2nix, pyproject-build-systems, ... }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Prefer PyPI wheels: ray and jesse-rust are impractical to build from source.
      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      # sdist-only packages that don't declare their setuptools build dependency
      buildFixups = final: prev:
        lib.genAttrs [ "peewee" "simplejson" "starkbank-ecdsa" "timeloop" ] (name:
          prev.${name}.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ])
              ++ final.resolveBuildSystem { setuptools = [ ]; };
          }));

      pythonSetFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python312;
        in
        (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            buildFixups
          ]
        );
    in
    {
      packages = forAllSystems (system: rec {
        default = jesse;
        jesse = (pythonSetFor system).mkVirtualEnv "jesse-env" workspace.deps.default;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${(pythonSetFor system).mkVirtualEnv "jesse-env" workspace.deps.default}/bin/jesse";
        };
      });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [
              ((pythonSetFor system).mkVirtualEnv "jesse-dev-env" workspace.deps.default)
              pkgs.uv
            ];
            env.UV_NO_SYNC = "1";
          };
        });
    };
}
