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

    # A UTF-8 locale is REQUIRED. koka reads each `extern import c file
    # "../../csrc/X.c"` via Haskell readFile, which decodes with the locale
    # encoding; our C bridges contain UTF-8 (em-dashes in comments), so under a
    # nix build's default C/POSIX locale readFile throws and koka reports
    # "unable to read external file" for every bridge. (darwin only ever
    # substitutes annexwyrm from cachix; deploy.sh works because Ubuntu has a
    # UTF-8 locale.) C.UTF-8 is built into glibc, so no locale archive needed.
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8

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
