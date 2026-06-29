# Koka toolchain built from cognivore/koka `dev` — the reconciled fork: v3.2.4
# line + the evv-crossdepth SIGSEGV fix + unsafe-reopen + the issue-#894 codegen
# backport + ParcReuse/yield-context fixes + the kk_bytes_join_with element
# refcount-leak fix (bb9e2fba). See docs/koka-repros/KOKA_EVV_CROSSDEPTH_FIX.md
# and ~/Journals/crazy-bugs/2026-06-26-koka-string-join-refcount-leak.md.
#
# This is nixpkgs' pkgs/by-name/ko/koka/package.nix (at the locked nixpkgs
# rev) with two changes: `src` points at the patched fork (builtins.fetchGit,
# rev-pinned, no hash dance, submodules for kklib/mimalloc), and `version` is
# DERIVED from the fork's package.yaml (NOT hardcoded) so stdlib + kklib always
# install under the share/koka/v<version> dir the built compiler looks in.
# To bump the toolchain, change ONLY `rev` below.
# See ~/Journals/koka-toolchain-bumping-methodology/.
{
  lib,
  stdenv,
  pkgsHostTarget,
  haskellPackages,
  cmake,
  makeWrapper,
}:

let
  src = builtins.fetchGit {
    url = "https://github.com/cognivore/koka.git";
    ref = "dev";
    rev = "bb9e2fbad7f19a000cf7f21a2da3a419fb1f1084";
    submodules = true;
  };

  # DERIVE the version from the koka source's package.yaml — NEVER hardcode it.
  # koka installs its stdlib AND kklib under share/koka/v<version>, and the
  # compiled binary looks them up by the version baked in from package.yaml. A
  # hardcoded mismatch (nix said 3.2.4 while dev source is 3.2.7) installs them
  # to the wrong dir -> "could not find module: std/core" + "kklib.h: No such
  # file". Parsing from source means a toolchain bump is JUST changing `rev`
  # above. Fails loud if it can't parse (never silently wrong).
  version =
    let
      lines = lib.splitString "\n" (builtins.readFile "${src}/package.yaml");
      hits = lib.filter (m: m != null)
        (map (l: builtins.match "version:[[:space:]]+([0-9.]+).*" l) lines);
    in
    if hits == [ ] then throw "koka-patched.nix: cannot parse version from ${src}/package.yaml"
    else lib.head (lib.head hits);

  kklib = stdenv.mkDerivation {
    pname = "kklib";
    inherit version;
    src = "${src}/kklib";
    nativeBuildInputs = [ cmake ];
    outputs = [
      "out"
      "dev"
    ];
    postInstall = ''
      mkdir -p ''${!outputDev}/share/koka/v${version}
      cp -a ../../kklib ''${!outputDev}/share/koka/v${version}
    '';
  };

  inherit (pkgsHostTarget.targetPackages.stdenv) cc;
  runtimeDeps = [
    cc
    cc.bintools.bintools
    pkgsHostTarget.gnumake
    pkgsHostTarget.cmake
  ];
in
haskellPackages.mkDerivation {
  pname = "koka";
  inherit version src;

  isLibrary = false;
  isExecutable = true;

  buildTools = [ makeWrapper ];

  libraryToolDepends = with haskellPackages; [
    hpack
  ];

  executableHaskellDepends = with haskellPackages; [
    FloatingHex
    aeson
    array
    async
    base
    bytestring
    co-log-core
    containers
    directory
    hashable
    isocline
    lens
    lsp_2_8_0_0
    mtl
    network
    network-simple
    parsec
    process
    stm
    text
    text-rope
    time
    kklib
  ];

  executableToolDepends = with haskellPackages; [
    alex
  ];

  postInstall = ''
    mkdir -p $out/share/koka/v${version}
    cp -a lib $out/share/koka/v${version}
    ln -s ${kklib.dev}/share/koka/v${version}/kklib $out/share/koka/v${version}
    wrapProgram "$out/bin/koka" \
      --set CC "${lib.getBin cc}/bin/${cc.targetPrefix}cc" \
      --prefix PATH : "${lib.makeSearchPath "bin" runtimeDeps}"
  '';

  doHaddock = false;

  doCheck = false;

  prePatch = "hpack";

  description = "Koka language compiler and interpreter (onehr-patched: evv-crossdepth fix)";
  homepage = "https://github.com/cognivore/koka";
  license = lib.licenses.asl20;
}
