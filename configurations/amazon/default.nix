# An EC2 image. Build `.#amazon.amazonImage`, then run
# `nix run .#amazon.uploadAmazonImage -- --bucket <bucket> --region <region>`
# to register it as an AMI. Root login is with the SSH key chosen at launch.
{ config, ... }:
{
  nixpkgs.hostPlatform = "x86_64-freebsd";

  imports = [ ../../modules/virtualisation/amazon-image.nix ];

  # For trying the same system locally with `.#amazon.vm`.
  virtualisation.vmVariant.virtualisation.diskImage = "./${config.system.name}.qcow2";
}
