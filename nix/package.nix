{ lib, stdenv, koka, sqlite, openssl, curl, libargon2,
  pkg-config, kklib, runtimeLibs }:

# The annexwyrm derivation.
#
# Koka emits one C translation unit per Koka module into a per-build
# directory under `--builddir`. We add `csrc/` to the include path so
# the `extern import c file "..."` directives in `src/interp/*.kk`
# resolve, then declare the system libraries the C bridge needs via
# `--cclibs`. Koka invokes the C compiler itself; we just pass through.

stdenv.mkDerivation {
  pname = "annexwyrm";
  version = "0.1.0";

  src = lib.cleanSource ./..;

  nativeBuildInputs = [ koka pkg-config ];
  buildInputs = runtimeLibs;

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    mkdir -p build

    # Work around koka's buggy `resolveDot` (Common/File.hs): it does NOT
    # collapse *consecutive* `..`, so `extern import c file "../../csrc/X.c"`
    # from src/interp/ resolves to a residual `<root>/src/../csrc/X.c` that
    # koka's own readFile then rejects ("unable to read external file"). It only
    # surfaces on a from-source build (darwin substitutes annexwyrm from cachix;
    # the koka.org binary used by deploy.sh tolerates the residual `..`). A
    # SINGLE `..` collapses fine, so put the C bridges at src/csrc and rewrite
    # the imports one level shallower. (Fix koka's resolveDot to retire this.)
    cp -r csrc src/csrc
    sed -i 's|"\.\./\.\./csrc/|"../csrc/|g' src/interp/*.kk

    # ccincdir (C header search path, absolute) still points at the original
    # csrc — aw_bridge.h lives there.
    koka -O2 \
      --target=c \
      --include=src \
      --ccincdir="$(pwd)/csrc" \
      --builddir=build/.koka \
      --cclib="sqlite3;ssl;crypto;curl;argon2" \
      -o build/annexwyrm \
      src/annexwyrm.kk

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/annexwyrm
    # install -m555 (not a plain cp): koka's sandbox-emitted binary lands
    # mode 0644, and a bare cp carries that through, so the store path ends
    # up non-executable and the launchd serve agent dies with EACCES. Force
    # the executable bit here.
    install -m555 build/annexwyrm $out/bin/annexwyrm
    # Schema lives in the share dir; `annexwyrm init` reads it from there
    # by default but the path is also baked into the binary.
    cp sql/schema.sql $out/share/annexwyrm/
    cp -R static     $out/share/annexwyrm/
    cp Caddyfile.example $out/share/annexwyrm/
    runHook postInstall
  '';

  meta = {
    description = "annexwyrm — federated git-annex archive";
    homepage = "https://github.com/cognivore/annexwyrm";
    license = lib.licenses.agpl3Plus;
    mainProgram = "annexwyrm";
    platforms = lib.platforms.unix;
  };
}
