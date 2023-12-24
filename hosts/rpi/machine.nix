dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    flags = lib.tail (lib.splitString "-" name); hasFlag = flag: builtins.elem flag flags;
in { imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "aarch64-linux";
    system.stateVersion = "22.05";

    setup.disks.devices.primary.size = 31914983424; #63864569856; #31657558016; #64021856256; #31914983424;

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
        fdtfile = "-"; # "broadcom/bcm2711-rpi-4-b.dtb"; # If »fdtfile« is not set here, then it seems to default to »broadcom/bcm2711-rpi-4-b.dtb«. If it is not set at all, uboot tries to guess it (and guesses wrong, also the path structure in »config.hardware.deviceTree.package« is not what u-boot expects). If the file fails to load (e.g. because it is set to »-«), u-boot assumes that there is a device tree at »fdt_addr=2eff8e00« already, where indeed the GPU firmware has put the device tree it created from the ».dtb« file and »config.txt«.
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
    #hardware.deviceTree.overlays = [ { name = "i2c-rtc"; dtboFile = "${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/i2c-rtc.dtbo"; } ]; # Doesn't do anything (with the »hardware.deviceTree.package« DTB).
    th.hermetic-bootloader.slots.size = "128M";
    th.hermetic-bootloader.extraFiles = (lib.th.copy-files pkgs "rpi-firmware-slice" ({
        "config.txt" = pkgs.writeText "config.txt" (''
            avoid_warnings=1
            arm_64bit=1
            kernel=u-boot.bin
            enable_uart=1
            disable_splash=1
            boot_delay=0
        '');
            # force_turbo=1 # could try this
            # gpu_mem=16 # these three options in combination reduce the GPUs capabilities (or something like that), but may also reduce boot time a bit
            # start_file=start4cd.elf
            # fixup_file=fixup4cd.dat
            #dtparam=i2c_vc=on # Doesn't do anything (with the »hardware.deviceTree.package« DTB).
            #dtoverlay=i2c-rtc,pcf85063a,i2c_csi_dsi,addr=0x51
        # (»gpu_mem=16« would enable the use of "cut down" (»_cd«-suffixed) GPU firmware (minimal GPU support))
        # »enable_uart=1« is also required for u-boot to use the UART (and work at all?).
        # TODO: Something is wrong with bluetooth, could disable it (»dtoverlay=disable-bt«, if that overlay exists), but that may affect serial console output as well.
        "u-boot.bin" = "${config.th.hermetic-bootloader.uboot.result}/u-boot.bin";
        "bcm2711-rpi-4-b.dtb" = "${config.hardware.deviceTree.package}/broadcom/bcm2711-rpi-4-b.dtb"; # This is from the kernel build (and also works for the CM4).

        # With these, the PI (CM4) does not boot:
        #"bcm2711-rpi-4-b.dtb" = "${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-4-b.dtb";
        #"bcm2711-rpi-cm4.dtb" = "${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-cm4.dtb";
        #"overlays/i2c-rtc.dtbo" = "${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/i2c-rtc.dtbo";

        # The rPI4 does not need a »bootcode.bin« since it has the code in its eeprom.
        # https://www.raspberrypi.com/documentation/computers/configuration.html#start-elf-start_x-elf-start_db-elf-start_cd-elf-start4-elf-start4x-elf-start4cd-elf-start4db-elf
    } // (lib.fun.mapMerge (name: {
        ${name} = "${pkgs.raspberrypifw}/share/raspberrypi/boot/${name}";
    }) [ # Only one pair (with 4) of these is necessary:
        /* "start.elf" "start_cd.elf" "start_x.elf" "start_db.elf" */ "start4.elf" /* "start4cd.elf" "start4x.elf" "start4db.elf" */
        /* "fixup.dat" "fixup_cd.dat" "fixup_x.dat" "fixup_db.dat" */ "fixup4.dat" /* "fixup4cd.dat" "fixup4x.dat" "fixup4db.dat" */
    ])));
    boot.kernelParams = [ "console=tty1" /* "console=ttyS0,115200" */ "console=ttyS1,115200" /* "console=ttyAMA0,115200" */ ]; # (With bluetooth present) »ttyS0« connects to the (mini) uart1 at pins 08+10, which needs the »enable_uart=1« (which may limit system performance) in »config.txt« to work. Without any »console=...«, initrd and the kernel log to uart1.

    th.minify.shrinkKernel.usedModules = ./minify.lsmod; # (this works fine when compiling natively / through qemu, but when cross-compiling, the ./dtbs/ dir is missing)

    #th.target.watchdog.enable = lib.mkForce false;


}) /* (lib.mkIf (hasFlag "minimal") { ## Super-minification

    # Just to prove that this can be installed very small disk (with a 640MiB disk, the »/system« partition gets ~360MiB):
    setup.disks.devices.primary.size = lib.mkForce "640M"; setup.disks.devices.primary.alignment = 8;
    th.target.fs.dataSize = "1K"; fileSystems."/data" = lib.mkForce { fsType = "tmpfs"; device = "tmpfs"; }; # don't really need /data
    #fileSystems."/system".formatArgs = lib.mkForce [ "-E" "nodiscard" ]; # (remove »-O inline_data«, which does not work for too small inodes used as a consequence of the tiny FS size, but irrelevant now that we use a fixed inode size)


}) */ (lib.mkIf true { ## Temporary Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.fun.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.${if (builtins.substring 0 5 inputs.nixpkgs.lib.version) == "22.05" then "sha256" else "yescrypt"}-pass")}"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub";
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];


}) (lib.mkIf (!hasFlag "minimal") { ## Bloat Test Stuff

    th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    environment.systemPackages = lib.mkIf ((flags == [ ]) || (hasFlag "debug")) [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];


})  ]; }
