{
  description = "Current upstream Crystal; bundled macOS libraries keep releases portable";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      sources = builtins.fromJSON (builtins.readFile ./crystal.json);
      makeCrystal = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          darwin = pkgs.stdenv.hostPlatform.isDarwin;
          source = sources.assets.${if darwin then "darwin" else system};
          libraries = with pkgs; [ boehmgc pcre2 libevent openssl zlib ];
        in { crystal = pkgs.stdenvNoCC.mkDerivation {
          pname = "crystal-standalone";
          inherit (sources) version;
          src = pkgs.fetchurl { inherit (source) url sha256; };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          unpackPhase = ''
            tar --no-same-owner -xf $src --strip-components=${if darwin then "1" else "2"}
          '';
          dontConfigure = true;
          dontBuild = true;
          dontFixup = true;
          installPhase = ''
            mkdir -p $out
            cp -r . $out/
          '' + (if darwin then ''
            # The official macOS bundle includes static runtime libraries.
            patchShebangs $out/bin
          '' else ''
            # The Linux compiler is static; programs link Nix libraries locally.
            wrapProgram $out/bin/crystal \
              --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkg-config pkgs.clang ]} \
              --suffix CRYSTAL_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath libraries} \
              --suffix PKG_CONFIG_PATH : ${pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" libraries}
          '');
        }; };
    in { packages = builtins.listToAttrs (map (system: {
      name = system;
      value = makeCrystal system;
    }) [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]); };
}
