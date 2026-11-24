{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    minikube
    kubectl
    istioctl
    jq
    iptables
  ];
}
