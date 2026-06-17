{
  description = "gitgood.lua — Neovim PR review plugin (fugitive-style)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Build the plugin for a given pkgs, baking gh's absolute path into gh_cmd so
      # the plugin carries its own gh — no extra systemPackages needed.
      mkPlugin = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "gitgood.lua";
        version = "0.1.0";
        src = self;
        postPatch = ''
          substituteInPlace lua/gitgood/config.lua \
            --replace-fail 'gh_cmd = "gh"' 'gh_cmd = "${pkgs.lib.getExe pkgs.gh}"'
        '';
        doCheck = false;
        meta = {
          description = "Review pull requests in Neovim, vim-fugitive style";
          homepage = "https://github.com/jakeschurch/gitgood.lua";
          license = pkgs.lib.licenses.mit;
        };
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = mkPlugin pkgs;

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
      })
    // {
      # Overlay: pkgs.vimPlugins.gitgood-lua (gh baked in).
      overlays.default = final: _prev: {
        vimPlugins = (final.vimPlugins or { }) // {
          gitgood-lua = mkPlugin final;
        };
      };
    };
}
