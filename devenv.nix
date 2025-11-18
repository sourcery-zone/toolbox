{ pkgs, lib, config, inputs, ... }:

{
  packages = with pkgs; [ ];

  languages.zig.enable = true;
}
