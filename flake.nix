{
  description = "ZARGS: An aloof argument parser for Zig";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    eachSystem = let
      lp = nixpkgs.legacyPackages;
      zig = lp.x86_64-linux.zig.meta.platforms;
      nix = builtins.attrNames lp;
      systems = lib.intersectLists zig nix;
    in fn: lib.foldl' (
      acc: system: lib.recursiveUpdate
        acc
        (lib.mapAttrs (_: value: {${system} = value;}) (fn system))
    ) {} systems;
  in eachSystem (
    system: let
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          zig
          zls
        ];
      };
    }
  );
}
