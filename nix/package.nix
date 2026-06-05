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

    koka -O2 \
      --target=c \
      --include=src \
      --ccincdir=csrc \
      --builddir=build/.koka \
      --cclib="sqlite3;ssl;crypto;curl;argon2" \
      -o build/annexwyrm \
      src/annexwyrm.kk

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/annexwyrm
    cp build/annexwyrm $out/bin/
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
