{
  description = "gitgood.lua — Neovim PR review plugin (fugitive-style)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "gitgood-dev";
          packages = with pkgs; [
            neovim # 0.10+ runtime for testing
            gh # provider backend
            lua-language-server # diagnostics / .luarc.json
            stylua # formatter
          ];
          shellHook = ''
            echo "gitgood.lua dev shell — run tests with:"
            echo "  nvim --headless --clean -u NONE --cmd 'set rtp+=\$PWD' -c '...'"
          '';
        };
      });
}
