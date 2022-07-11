dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    #suffix = builtins.head (builtins.match ''target-(.*)'' name);
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in { imports = [ ({ ## Hardware

    system.stateVersion = "22.05";

    wip.fs.disks.devices.primary.size = 31914983424; #31657558016; #64021856256; #63864569856;

    ## Firmware/bootloader:
    th.hermetic-bootloader.loader = "uboot-extlinux";
    th.hermetic-bootloader.uboot.base = pkgs.uboot-imx.override { platform = lib.toLower config.nxp.imx8-boot.soc; };
    th.hermetic-bootloader.uboot.mmcDev = 1;
    th.hermetic-bootloader.uboot.env = config.nxp.imx8-boot.uboot.envVars;
    nxp.imx8-boot.uboot.package = config.th.hermetic-bootloader.uboot.result;
    nxp.imx8-boot.enable = true; nxp.imx8-boot.soc = "iMX8MP";
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "firmware-imx" ];
    boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
    wip.fs.boot.enable = lib.mkForce false;
    # The i.MX expects the boot image starting at sector 64. The multiple copies of the GPT would usually conflict with that, so move them:
    th.hermetic-bootloader.extraGptOffset = 3 * 1024 * 2; # (3M in sectors)
    wip.fs.disks.partitions."bootloader-${hash}" = lib.mkForce null;

    th.minify.shrinkKernel.baseKernel = pkgs.linux-imx_v8;
    #th.minify.shrinkKernel.usedModules = ./minify.lsmod; # TODO

    ## Networking:
    networking.interfaces.eth0.ipv4.addresses = [ {
        address = "192.168.8.86"; prefixLength = 24;
    } ];
    networking.defaultGateway = "192.168.8.1";
    networking.nameservers = [ "1.1.1.1" ];


}) (lib.mkIf true { ## Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.wip.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.sha256-pass")}"; # .password = "root";

    boot.kernelParams = lib.mkForce [ /* "console=ttymxc1" */ "boot.shell_on_fail" ]; # the initrd shell will use the last »console=« ; »mkForce« to remove »boot.panic_on_fail«

    wip.services.dropbear.rootKeys = [ ''${lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub"}'' ];
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];


}) (lib.mkIf true { ## Bloat Test Stuff

    #th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    #environment.systemPackages = [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];

    boot.kernelPackages = lib.mkForce pkgs.linuxPackages; # building the i.MX kernel on x64 is quite time consuming, might want to remove this later and then rebuild the proper kernel on the board


})  ]; }
