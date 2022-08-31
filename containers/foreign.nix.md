/*

#

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config:
dirname: inputs: let inherit (inputs.self) lib; in pkgs: let
in {

    rootFS = [
        # How to get a rootfs layer:
        # First, find or build an appropriate image:
        # $ printf 'FROM ubuntu:20.04 \nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-server busybox' | docker build --pull -t local/ubuntu-server -
        # Then (fetch and) unpack it and add it to the nix store (podman can also do this):
        # $ ( image=local/ubuntu-server ; set -eux ; id=$(docker container create ${image/_\//}) ; trap "docker rm --volumes $id" EXIT ; rm -rf ../images/$image ; mkdir -p ../images/$image ; cd ../images/$image ; docker export $id | pv | tar x ; echo "$(nix eval --impure --expr '"${./.}"'):$(nix hash path --type sha256 .)" )
        # If »$image« to remains constant or is reproducible, then (and only then) this will reproduce the same (content-addressed) store path.
        # If this store path does not exist locally (e.g. because it can't be reproduced), then both evaluation and building will fail, but only if the path is actually being evaluated.
        # The layer could also be specified with any of Nix(OS)' fetchers (if it is hosted somewhere nix can reach and authenticate against).
        # Adding layers as flake inputs is not a good idea, since those will always be fetched even when they are not being accessed, which would be the case for all layers from older builds when chaining previous builds as flake input.
        "/nix/store/3387hzbl34z2plj3cvfghp4jlvgc2jn5-ubuntu-server:sha256-PPVOPyQGbkgoFkERodVcEyTI84/rG4MhjIuPcjHll98="
        #"/nix/store/plqajm9ma7by4h0wmz35x6gkqgbwbzp5-android-setup:sha256-+MjVIiL36rQ9ldJa7HyOn3AXgSprZeWOCfKKU4knWa0=" # A path where the hashes match, but that doesn't exist. Creating it as empty dir does not make a difference.

        # This image's systemd starts just fine, but any »machinectl shell« results in »systemd-coredump[...]: [🡕] Process ... ((sh)) of user 0 dumped core.«
    #   (lib.th.extract-docker-image pkgs (pkgs.dockerTools.pullImage {
    #       imageName = "busybox"; finalImageTag = "1.34.1-glibc"; imageDigest = "sha256:5b1ae0bda2e3beb70cb3884c05c2c0d3d542db2fa4ce27fc191e84091361d6eb"; sha256 = "1nw8r3yl8bxzafaqi1gb2rf6f2b2hl39cdl7dgs6f467p38sh9dh";
    #   }))
    #   (lib.th.extract-docker-image pkgs (pkgs.dockerTools.pullImage {
    #       imageName = "jrei/systemd-ubuntu"; finalImageTag = "20.04"; imageDigest = "sha256:a54deb990d26b6bc7e3b2ab907a0dbb3e45f506a367794a4b6df545bfe41cfed"; sha256 = "0ywa0yrqgs2w5zk4f8rd42b8d6bdywniah6nnkhqmkpy2w8fdi78";
    #   }))

        (pkgs.runCommandLocal "layer-prepare-systemd" { } ''
            mkdir -p $out
            ln -sT /usr/lib/systemd/systemd $out/init

            mkdir -p $out/etc/systemd/system/
            printf '[Service]\nExecStart=/bin/busybox httpd -f -v -p 8001 -h /web-root/\n' > $out/etc/systemd/system/http.service
            mkdir -p $out/etc/systemd/system/multi-user.target.wants
            ln -sT ../http.service $out/etc/systemd/system/multi-user.target.wants/http.service
            mkdir -p $out/web-root/ ; printf "<!DOCTYPE html>\n<html><head></head><body>I'm not a NixOS container, but I pretend to be</body></html>\n" > $out/web-root/index.html
        '')
    ];


}
