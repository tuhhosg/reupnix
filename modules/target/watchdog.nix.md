/*

# System Responsiveness Watchdog

This module enables the systems hardware watchdog in u-boot (if applicable), during boot (from stage 1 onwards), and in systemd.

Additional software watchdog configuration (systemd monitoring additional system state) should also be implemented.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.target.watchdog;
in {

    options.th = { target.watchdog = {
        enable = lib.mkEnableOption "hardware and software watchdog functionality";
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        ## Bootloader:
        th.hermetic-bootloader.uboot.extraConfig = [
            "CONFIG_WDT=y" "CONFIG_WATCHDOG=y" # enable support for and start watchdog system; also start and pacify it by default
            "CONFIG_CMD_WDT=y" # enable »wdt« (watchdog timer) command: https://u-boot.readthedocs.io/en/latest/usage/cmd/wdt.html
            "CONFIG_WATCHDOG_TIMEOUT_MSECS=20000" # This should be enough to reach the initramfs. The default probably depends on the hardware and driver (here in u-boot, but also in Linux). The imx8mp's default is 60sin either case.
            # NOTE: There may be dome board-specific things that need to be set!
        ];

        ## During boot:
        # Ideally, the kernel (driver) would just keep the timeout started by the bootloader running, but that seems to be difficult (https://community.toradex.com/t/enable-watchdog-at-boot/5538/5). Instead, start it again as early as possible.
        boot.initrd.extraUtilsCommands = ''copy_bin_and_libs ${pkgs.util-linux}/sbin/wdctl'';
        boot.initrd.preDeviceCommands = ''
            # Re-enable watchdog ASAP with 30s timeout until systemd takes over:
            wdctl -s 30 1>/dev/null || echo "Failed to set watchdog timeout!" >&2
            if [ -e /dev/watchdog0 ] ; then echo "" > /dev/watchdog0 ; else echo "/dev/watchdog0 does not exist!" >&2 ; fi # (opening the device and not writing 'V' before closing it triggers the timeout)
        ''; # »preDeviceCommands« may be too early for some watchdog devices ...
        # Could pass »CONFIG_WATCHDOG_NOWAYOUT« to the kernel build.

        ## While running:
        systemd.watchdog.runtimeTime = "10s"; systemd.watchdog.rebootTime = "60s"; # Ensure that systemd (and thus the kernel) are responsive. Services may still do whatever.
        boot.kernelParams = [ "hung_task_panic=1" "hung_task_timeout_secs=30" ]; # Panic if a (kernel?) task is stuck for 30 seconds. (TODO: only the »hung_task_panic« applies)
        # TODO: watch network availability and systemd services


    }) ]);

}
