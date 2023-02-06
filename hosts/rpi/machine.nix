dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    suffix = builtins.elemAt (builtins.match ''rpi(-(.*))?'' name) 1;
in { imports = [ ({ ## Hardware

    system.stateVersion = "22.05";

    wip.fs.disks.devices.primary.size = 63864569856; #31657558016; #64021856256; #31914983424;

    networking.interfaces.eth0.ipv4.addresses = [ {
        address = "192.168.8.85"; prefixLength = 24;
    } ];
    networking.defaultGateway = "192.168.8.1";
    networking.nameservers = [ "1.1.1.1" ];

    th.hermetic-bootloader.loader = "uboot-extlinux";
    th.hermetic-bootloader.uboot.base = pkgs.ubootRaspberryPi4_64bit;
    th.hermetic-bootloader.uboot.mmcDev = 1;
    th.hermetic-bootloader.uboot.env = {
        # From u-boot/u-boot/include/configs/rpi.h:
     /* kernel_addr_r  = "0x00080000";
        scriptaddr     = "0x02400000";
        pxefile_addr_r = "0x02500000";
        fdt_addr_r     = "0x02600000";
        ramdisk_addr_r = "0x02700000"; */
        #         1MB  =    0x100000
        kernel_addr_r  = "0x00200000"; # (u-boot/u-boot/include/configs/rpi.h) suggests 0x00080000, but then uboot moves it here
        scriptaddr     = "0x03200000"; # +48MB
        pxefile_addr_r = "0x03300000";
        fdt_addr_r     = "0x03400000";
        ramdisk_addr_r = "0x03800000";
        fdtfile = "-"; # "broadcom/bcm2711-rpi-4-b.dtb"; # If it is not set here, then somewhere else actually sets the same value. If it is not set at all, uboot tries to guess it (and guesses wrong, also the path structure in »config.hardware.deviceTree.package« is not what u-boot expects). If the file fails to load (e.g. because it is set to »-«), u-boot assumes that there is a device tree at »fdt_addr=2eff8e00« already, where indeed the GPU firmware has put the device tree it created from the ».dtb« file and »config.txt«.
        /*
        setenv kernel_addr_r  0x00200000
        setenv scriptaddr     0x03200000
        setenv pxefile_addr_r 0x03300000
        setenv fdt_addr_r     0x03400000
        setenv ramdisk_addr_r 0x03800000
        sysboot mmc 0:1 fat ${scriptaddr} /extlinux/extlinux.conf
        */
    };
    hardware.deviceTree.filter = "bcm2711-rpi-4-b.dtb"; # bcm2711-rpi-cm4.dtb
    th.hermetic-bootloader.slots.size = "128M";
    th.hermetic-bootloader.extraFiles = {
        "config.txt" = pkgs.writeText "config.txt" (''
            avoid_warnings=1
            arm_64bit=1
            kernel=u-boot.bin
            enable_uart=1
        '');
        # (»gpu_mem=16« would enable the use of "cut down" (»_cd«-suffixed) GPU firmware (minimal GPU support))
        # »enable_uart=1« is also required for u-boot to use the UART (and work at all?).
        # TODO: Something is wrong with bluetooth, could disable it (»dtoverlay=disable-bt«), but that may affect serial console output as well.
        # TODO: Something is even more wrong with HDMI output. If HDMI is connected, it seems to work for a while, then something happens, and there are a number of timeouts stalling the boot. If HDMI is disconnected, booting works fine. Could try the »gpu_mem=16« thing.
        "u-boot.bin" = "${config.th.hermetic-bootloader.uboot.result}/u-boot.bin";
        # https://www.raspberrypi.com/documentation/computers/configuration.html#start-elf-start_x-elf-start_db-elf-start_cd-elf-start4-elf-start4x-elf-start4cd-elf-start4db-elf
        #"fixup4.dat" = "${pkgs.raspberrypifw}/share/raspberrypi/boot/fixup4.dat";
        #"start4.elf" = "${pkgs.raspberrypifw}/share/raspberrypi/boot/start4.elf";
        # The rPI4 does not need a »bootcode.bin« since it has the code in its eeprom.

        "bcm2711-rpi-4-b.dtb" = "${config.hardware.deviceTree.package}/broadcom/bcm2711-rpi-4-b.dtb";
    } // (lib.wip.mapMerge (name: {
        ${name} = "${pkgs.raspberrypifw}/share/raspberrypi/boot/${name}";
    }) [
        # TODO: only one pair (with 4) of these should ne necessary:
        "start.elf" "start_x.elf" "start_db.elf" "start_cd.elf" "start4.elf" "start4x.elf" "start4cd.elf" "start4db.elf"
        "fixup.dat" "fixup_x.dat" "fixup_db.dat" "fixup_cd.dat" "fixup4.dat" "fixup4x.dat" "fixup4cd.dat" "fixup4db.dat"
    ]);
    boot.kernelParams = [ "console=tty1" /* "console=ttyS0" */ /* "console=ttyAMA0" */ ]; # (With bluetooth present) »ttyS0« connects to the (mini) uart1 at pins 08+10, which needs the »enable_uart=1« (which may limit system performance) in »config.txt« to work. Without any »console=...«, initrd and the kernel log to uart1.

    th.minify.shrinkKernel.usedModules = ./minify.lsmod; # (this works fine when compiling natively / through qemu, but when cross-compiling, the ./dtbs/ dir is missing)

    #th.target.watchdog.enable = lib.mkForce false;


}) (lib.mkIf true { ## Temporary Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.wip.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.sha256-pass")}"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub";
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];


}) (lib.mkIf (suffix != "minimal") { ## Bloat Test Stuff

    th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    environment.systemPackages = [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];


})  ]; }
