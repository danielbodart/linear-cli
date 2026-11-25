{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  installShellFiles,
  versionCheckHook,
  libsecret,
}:

let
  # Written by scripts/update.sh, which cross-checks every hash in it against
  # the bytes of the tarball it names before it lands.
  pinned = builtins.fromJSON (builtins.readFile ./sources.json);

  source =
    pinned.sources.${stdenv.hostPlatform.system}
      or (throw "linear-cli: no release is published for ${stdenv.hostPlatform.system}");
in

stdenv.mkDerivation {
  pname = "linear-cli";
  inherit (pinned) version;

  # The tarball holds one directory, linear-<target triple>/, with the binary
  # and its licence files in it. The default unpack finds that directory.
  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    installShellFiles
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
    makeWrapper
  ];

  # A Rust binary that links glibc and libgcc_s, the unwinder Rust's panics
  # use. autoPatchelfHook finds glibc in the stdenv, but libgcc_s only in the
  # compiler's runtime libraries. On macOS it links only the system's own
  # libraries and frameworks, so there is nothing to patch.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 linear $out/bin/linear
    install -Dm644 -t $out/share/doc/linear-cli README.md CHANGELOG.md LICENSE THIRD_PARTY_LICENSES.md
    runHook postInstall
  '';

  # On Linux the CLI keeps API keys in the desktop's keyring by running
  # `secret-tool`, looked up on PATH. It is appended, not prepended, so a
  # secret-tool the user already has wins. macOS uses /usr/bin/security by
  # its full path, which needs nothing.
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    wrapProgram $out/bin/linear --suffix PATH : ${lib.makeBinPath [ libsecret ]}
  '';

  # The completions come from the binary itself, so they always match it.
  # They need no network and no login, only a HOME to not write to. On Linux
  # the binary cannot start until its interpreter is patched, which the hook
  # would otherwise only do in the fixup phase, after this.
  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    ${lib.optionalString stdenv.hostPlatform.isLinux "autoPatchelf $out/bin"}
    export HOME="$TMPDIR"
    installShellCompletion --cmd linear \
      --bash <($out/bin/linear completions bash) \
      --fish <($out/bin/linear completions fish) \
      --zsh <($out/bin/linear completions zsh)
  '';

  # `linear --version` needs no network and no login, so it runs in the build
  # sandbox. On Linux it exercises the patched interpreter and the whole
  # dynamic link. versionCheckHook gives it a throwaway HOME.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    description = "Linear issue tracker from the command line";
    homepage = "https://github.com/schpet/linear-cli";
    changelog = "https://github.com/schpet/linear-cli/releases/tag/v${pinned.version}";
    license = lib.licenses.isc;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "linear";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
