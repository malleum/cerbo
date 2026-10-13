{
  lib,
  stdenv,
  writers,
  symlinkJoin,
  makeWrapper,
  pulseaudio,
  jq,
}: let
  bare = writers.writePython3Bin "cerbo" {
    flakeIgnore = ["E501" "E731" "W503"];
  } (builtins.readFile ../cerbo.py);
in
  # pactl and jq are what the model reaches for first; --suffix so anything
  # already on the user's PATH wins.
  symlinkJoin {
    name = "cerbo";
    paths = [bare];
    nativeBuildInputs = [makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/cerbo \
        --suffix PATH : ${lib.makeBinPath ([jq] ++ lib.optional stdenv.hostPlatform.isLinux pulseaudio)}
    '';
    meta = {
      description = "Ask a local model to do something in the shell";
      license = lib.licenses.mit;
      mainProgram = "cerbo";
      platforms = lib.platforms.unix;
    };
  }
