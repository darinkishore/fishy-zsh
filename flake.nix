{
  description = "fishy-zsh: make zsh's interactive UX behave exactly like fish";

  inputs = {
    # Same nixpkgs revision as ~/src/nix, so plugin store paths match the real config.
    nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
    # zsh master, pinned: zle italic/faint (upstream 51280, not in any release yet).
    # Drop this pin for the first zsh release that contains it.
    zsh-src = {
      url = "github:zsh-users/zsh/30e8be913521523d226789e53a4a2202dabff61c";
      flake = false;
    };
  };

  outputs = {
    nixpkgs,
    zsh-src,
    ...
  }: let
    systems = ["aarch64-darwin" "x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
  in {
    packages = forAll (pkgs: let
      inherit (pkgs) lib stdenv;
      # nixpkgs marks yodl Linux-only, but it builds on Darwin once its
      # hardcoded `gcc` resolves to the toolchain. Needed for zsh's docs from git.
      gccShim = pkgs.writeShellScriptBin "gcc" ''exec ${stdenv.cc}/bin/cc "$@"'';
      unixOnDarwin = drv:
        drv.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ lib.optional stdenv.isDarwin gccShim;
          meta = old.meta // {platforms = lib.platforms.unix;};
        });
      icmake = unixOnDarwin pkgs.icmake;
      yodl = unixOnDarwin (pkgs.yodl.override {inherit icmake;});
      zshVersion = "5.9.999.3-test"; # Config/version.mk at the pinned commit
    in rec {
      # fish + the `__fishy` builtin: the completion/autosuggestion/history
      # "brain" that zsh drives. Only used as a server; the user's fish stays stock.
      fishy-fish = pkgs.fish.overrideAttrs (old: {
        pname = "fishy-fish";
        patches = (old.patches or []) ++ [./nix/fish-fishy-builtin.patch];
      });

      # zsh master (pinned) built exactly like nixpkgs' zsh, from git.
      fishy-zsh = pkgs.zsh.overrideAttrs (old: {
        pname = "fishy-zsh";
        version = zshVersion;
        src = zsh-src;
        # zle_display: display-only insertions/replacements (continuation indent,
        # case-flipped suggestion display). Not upstream.
        patches = (old.patches or []) ++ [./nix/zsh-fishy-zle-display.patch];
        # yodl renders the docs; col (util-linux) is needed for run-help files.
        nativeBuildInputs = old.nativeBuildInputs ++ [yodl pkgs.unixtools.col];
        # A git checkout has no generated configure / docs; zsh's own bootstrap.
        preAutoreconf = "./Util/preconfig";
        postInstall = builtins.replaceStrings ["zsh-5.9.2"] ["zsh-${zshVersion}"] old.postInstall;
      });

      # Everything the dev zdotdir and the harness need, at stable paths under
      # ./deps (made by `nix build .#deps -o deps`). No sudo, no activation.
      deps = pkgs.linkFarm "fishy-zsh-deps" {
        "bin/zsh" = "${fishy-zsh}/bin/zsh";
        "bin/zsh-stock" = "${pkgs.zsh}/bin/zsh";
        "bin/fish" = "${pkgs.fish}/bin/fish";
        "bin/fishy-fish" = "${fishy-fish}/bin/fish";
        "fish-share" = "${pkgs.fish}/share/fish";
      };
    });
  };
}
