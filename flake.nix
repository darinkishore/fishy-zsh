{
  description = "fishy-zsh: make zsh's interactive UX behave exactly like fish";

  # Same nixpkgs revision as ~/src/nix, so plugin store paths match the real config.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";

  outputs = {nixpkgs, ...}: let
    systems = ["aarch64-darwin" "x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
  in {
    packages = forAll (pkgs: rec {
      # fish + the `__fishy` builtin: the completion/autosuggestion/history
      # "brain" that zsh drives. Only used as a server; the user's fish stays stock.
      fishy-fish = pkgs.fish.overrideAttrs (old: {
        pname = "fishy-fish";
        patches = (old.patches or []) ++ [./nix/fish-fishy-builtin.patch];
      });

      # Everything the dev zdotdir and the tmux harness need, at stable paths
      # under ./deps (made by `nix build .#deps -o deps`). No sudo, no activation.
      deps = pkgs.linkFarm "fishy-zsh-deps" {
        "bin/zsh" = "${pkgs.zsh}/bin/zsh";
        "bin/fish" = "${pkgs.fish}/bin/fish";
        "bin/fishy-fish" = "${fishy-fish}/bin/fish";
        "bin/tmux" = "${pkgs.tmux}/bin/tmux";
        "zsh-src" = pkgs.zsh.src;
        "fish-share" = "${pkgs.fish}/share/fish";
      };
    });
  };
}
