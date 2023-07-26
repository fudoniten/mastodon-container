{
  description = "Mastodon running in a container";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }: {
    nixosModules = rec {
      default = mastodonContainer;
      mastodonContainer = { ... }: {
        imports = [ arion.nixosModules.arion ./mastodon-container.nix ];
      };
    };
  };
}
