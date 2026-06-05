{
  description = "annexwyrm — federated git-annex archive (Koka).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Exposed at top-level (not per-system) so the nixvana home-manager
      # flake can reference it the same way it references
      # `zensurance.homeManagerModules.default`.
      homeManagerModules.default = import ./nix/home-manager-module.nix self;
    in
    (flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # kklib is the Koka C runtime. nixpkgs builds it as a separate
        # derivation but only exposes it via `koka.buildInputs`; we pluck
        # it back out by pname. Multi-output: `.out` carries the static
        # library, `.dev` carries the headers.
        kklib = pkgs.lib.findFirst
          (p: (p.pname or "") == "kklib")
          (throw "kklib not found in koka.buildInputs — nixpkgs layout changed")
          pkgs.koka.buildInputs;

        # Runtime libraries the C bridge links against.
        runtimeLibs = with pkgs; [
          sqlite
          openssl
          curl
          libargon2
        ];
      in
      {
        packages.default = pkgs.callPackage ./nix/package.nix {
          inherit kklib runtimeLibs;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Toolchain
            koka
            just
            pkg-config
            # NB: do NOT add `clang` here. The standalone `pkgs.clang` package
            # (a newer LLVM, e.g. clang-wrapper-21.1.8) is not wired to the
            # macOS SDK the way the darwin stdenv's own cc-wrapper (21.1.2) is,
            # so it can't resolve <time.h>/time_t and the build dies with
            # "unknown type name 'time_t'" + implicit-declaration errors on the
            # csrc bridge. Adding it also overrides NIX_CC via its setup hook,
            # shadowing the working stdenv compiler that `nix build .#default`
            # uses. Letting koka pick up the stdenv `cc` keeps dev and Nix
            # builds on the same, SDK-integrated compiler.
            # Federation / storage runtime — required at *run* time, not
            # build, but we want them on PATH in the dev shell so the
            # daemon can call them.
            rclone
            git-annex
            git-annex-remote-rclone
            caddy
            sqlite                  # for `sqlite3` CLI, schema inspection
            # E2E test deps
            python3                 # minimal PDF generator (no extra pkgs)
            netcat                  # wait-for-socket polling in run.sh
            # Misc dev affordances
            jq
            curl
          ] ++ runtimeLibs;

          # Stable handles the Justfile and CI can rely on, so the build
          # commands don't have to re-derive nix store paths.
          shellHook = ''
            export ANNEXWYRM_KKLIB_LIB="${kklib.out}/lib"
            export ANNEXWYRM_KKLIB_INCLUDE="${kklib.dev}/include"
            export ANNEXWYRM_SQLITE_LIB="${pkgs.sqlite.out}/lib"
            export ANNEXWYRM_OPENSSL_LIB="${pkgs.openssl.out}/lib"
            export ANNEXWYRM_OPENSSL_INCLUDE="${pkgs.openssl.dev}/include"
            export ANNEXWYRM_CURL_LIB="${pkgs.curl.out}/lib"
            export ANNEXWYRM_CURL_INCLUDE="${pkgs.curl.dev}/include"
            export ANNEXWYRM_ARGON2_LIB="${pkgs.libargon2}/lib"
            export ANNEXWYRM_ARGON2_INCLUDE="${pkgs.libargon2}/include"
          '';
        };
      }
    )) // { inherit homeManagerModules; };
}
