/*

# Compare Container Sizes

... under different storage conditions and in different combinations of image variants.

Run this to get the plots and tables:
```bash
nix run '.#'check:container-sizes --keep-going -- --table=1,2 --plot=1,2
```


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs resize frame collect-deps du-deps run-in-vm;

    base-minimal  = override (unpinInputs inputs.self.nixosConfigurations."old:x64-minimal") {
        nixpkgs.overlays = [ (final: prev: { redis = prev.redis.overrideAttrs (old: { doCheck = false; }); }) ];
    };
    base-baseline = override (unpinInputs inputs.self.nixosConfigurations."old:x64-baseline") {
        nixpkgs.overlays = [ (final: prev: { redis = prev.redis.overrideAttrs (old: { doCheck = false; }); }) ];
    };
    fixUser = user: id: { users.users.${user} = { isSystemUser = true; uid = id; group = lib.mkDefault user; }; users.groups.${user}.gid = id; };

    get-image = attrs: lib.th.extract-docker-image pkgs (pkgs.dockerTools.pullImage attrs);

    nixos-nix = get-image {
        imageName = "nixos/nix"; finalImageName = "nix"; finalImageTag = "2.2.1";
        imageDigest = "sha256:85299d86263a3059cf19f419f9d286cc9f06d3c13146a8ebbb21b3437f598357";
        sha256 = "19fw0n3wmddahzr20mhdqv6jkjn1kanh6n2mrr08ai53dr8ph5n7";
    };

    # Selection criteria: on Docker hub, the first 15 "suggested" images that are "official", have 1B+ pulls, are directly usable services or language runtimes (i.e. not just bas images), and not deprecated (`openjdk`).
    # Picked the longest numerical version that was (in the README or the tags list) listed as the same as "latest" at 2022-08-18:
    # postgres      14.5-bullseye        (or -alpine)
    # python        3.10.6-bullseye      (or -alpine)    (or -slim-bullseye / -buster)
    # mongo         5.0.10-focal         (no variants)
    # traefik       2.8.3                (no variants)
    # mariadb       10.8.3-jammy         (no variants)
    # redis         7.0.4-bullseye       (or -alpine)
    # rabbitmq      3.10.7               (or -alpine)
    # node          18.7.0-bullseye      (or -alpine)    (or -bullseye-slim / -buster)
    # mysql         8.0.30-oracle        (or -debian)
    # golang        1.19.0-bullseye      (or -alpine)    (or -buster)
    # nginx         1.23.1               (or -alpine)
    # httpd         2.4.54-bullseye      (or -alpine)
    # wordpress     6.0.1-php7.4-apache  (no variants)
    # registry      2.8.1                (no variants)
    # memcached     1.6.16-bullseye      (or -alpine)

    images = {
        postgres = rec {
            default = bullseye;
            bullseye = get-image { imageName = "postgres"; finalImageTag = "14.5-bullseye"; imageDigest = "sha256:f8816ada742348e1adfcec5c2a180b675bf6e4a294e0feb68bd70179451e1242"; sha256 = "1ivic3yrblgpcf5i08fj4mn47hgv2snsysv2x20fkfjnqcizdb2r"; };
            alpine = get-image { imageName = "postgres"; finalImageTag = "14.5-alpine"; imageDigest = "sha256:322e9d80bbe0d19df45a2cfa262b50947683b4da283afdb6bee8e549aea87bf3"; sha256 = "0x7yhhv2bm7bx1p01m27v7jakxj84v1r2b0533qa4fz8b827nrkh"; };
            nixos = { pkgs, ...}: { services.postgresql.enable = true; };
        };
        python = rec {
            default = bullseye; slim = slim-bullseye; alt = buster;
            bullseye = get-image { imageName = "python"; finalImageTag = "3.10.6-bullseye"; imageDigest = "sha256:8846e26238945dc748151dc3e0f4e9a00bfd09ad2884edcc6e739f085ad9db3b"; sha256 = "1nnmmbz2vks84gj2hmml2ran9m6klqdxq4z2j7dhy496653z6yjq"; };
            alpine = get-image { imageName = "python"; finalImageTag = "3.10.6-alpine"; imageDigest = "sha256:0c46c7f15ee201a2e2dc3579dbc302f989a20b1283e67f884941e071372eb2cc"; sha256 = "1331gqj663a743fmwxf7d6p6vbzra79v05jii1cbvw4rl4znd0ca"; };
            slim-bullseye = get-image { imageName = "python"; finalImageTag = "3.10.6-slim-bullseye"; imageDigest = "sha256:59129c9fdea259c6a9b6d9c615c065c336aca680ee030fc3852211695a21c1cf"; sha256 = "189ik4acrxqa24aygmsv9q28fsx96dff2lspa0qjjd159q96g09k"; };
            buster = get-image { imageName = "python"; imageDigest = "sha256:ad6194844cade5e3d5220a6dc2bdb0e7983027ee96a92425884327225d4fafd2"; sha256 = "109yzngg5l6v69r29wls3ssc01h8lcsifaz5xyrlgnspvvb9mb5x"; finalImageTag = "3.10.6-buster"; };
            nixos = { pkgs, ...}: { environment.systemPackages = [ pkgs.python3Minimal ]; };
        };
        mongo = rec {
            default = get-image { imageName = "mongo"; finalImageTag = "5.0.10-focal"; imageDigest = "sha256:52dbb83b1f808c727f5f649b89eb1a0287c8f8d44f94f51b296bda258c570101"; sha256 = "05zgi4cnv1gnbr8zdqw49qhz71a5zmb7iwphg0yjbfi3sfhfjv9w"; };
            nixos = { pkgs, ...}: { services.mongodb.enable = true; } // (fixUser "mongodb" 999);
        };
        traefik = rec {
            default = get-image { imageName = "traefik"; finalImageTag = "2.8.3"; imageDigest = "sha256:ad8c1935c4b901e10b62b6868d6369218793c69e7a7ea9c1d036fdc2b919e38e"; sha256 = "0rih03j00vj4sj4bxq7lhfj81vpimv4cs7w7f8ml93fsrl2jgjsb"; };
            nixos = { pkgs, ...}: { services.traefik.enable = true; } // (fixUser "traefik" 998);
        };
        mariadb = rec {
            default = get-image { imageName = "mariadb"; finalImageTag = "10.8.3-jammy"; imageDigest = "sha256:0abf60f81588662e716c27c7f1b54a72b3bf879e0ca88fc393e1741970ec7f3f"; sha256 = "1331x7x2xramckp0qln64c0vh20a3nz5lc31177j7dqapp2j831r"; };
            nixos = { pkgs, ...}: { services.mysql = { enable = true; package = lib.mkForce pkgs.mariadb; }; environment.systemPackages = [ pkgs.mariadb ]; };
        };
        redis = rec {
            default = bullseye;
            bullseye = get-image { imageName = "redis"; finalImageTag = "7.0.4-bullseye"; imageDigest = "sha256:9bc34afe08ca30ef179404318cdebe6430ceda35a4ebe4b67d10789b17bdf7c4"; sha256 = "0l8prb6d3pqc7f78kzyc89mnjlq0672mv2d09v4yr73mb3khzbm8"; };
            alpine = get-image { imageName = "redis"; finalImageTag = "7.0.4-alpine"; imageDigest = "sha256:dc1b954f5a1db78e31b8870966294d2f93fa8a7fba5c1337a1ce4ec55f311bc3"; sha256 = "1s4w7akfay5sk82nwihz5j8r10pqr3ldfqq7a2yfg2a3525dzji8"; };
            nixos = { pkgs, ...}: { services.redis.servers."".enable = true; } // (fixUser "redis" 997);
        };
        rabbitmq = rec {
            default = get-image { imageName = "rabbitmq"; finalImageTag = "3.10.7"; imageDigest = "sha256:de9414a812a90aa122ac94f6b2ade20cf5466b8a6ab3ca5624c4e48691e06d27"; sha256 = "0kdrdx0cbcyczvqh047srk44lkbbnzrjyaaimn3gcgzxmj66h1sd"; };
            alpine = get-image { imageName = "rabbitmq"; finalImageTag = "3.10.7-alpine"; imageDigest = "sha256:45475a6657f08a33e01fb0dbe2e293257847dccdbf3a94b0a6334c6d082987b9"; sha256 = "1d7b4q4nhb4fdkpmxljhfp00hwnrzvd67gb41g79ar4aa242x6n6"; };
            nixos = { pkgs, ...}: { services.rabbitmq.enable = true; };
        };
        node = rec {
            default = bullseye; slim = bullseye-slim; alt = buster;
            bullseye = get-image { imageName = "node"; finalImageTag = "18.7.0-bullseye"; imageDigest = "sha256:a6f295c2354992f827693a2603c8b9b5b487db4da0714f5913a917ed588d6d41"; sha256 = "1w9aaapwqml0nal879yfzac81qz16d0b73bgqhyybxr34syixpws"; };
            alpine = get-image { imageName = "node"; finalImageTag = "18.7.0-alpine"; imageDigest = "sha256:02a5466bd5abde6cde29c16d83e2f5a10eec11c8dcefa667a2c9f88a7fa8b0b3"; sha256 = "155vp3dz880lbm3h9snwdcl5p4lq16acx4gxd6wv4w67ysnzyd7b"; };
            bullseye-slim = get-image { imageName = "node"; finalImageTag = "18.7.0-bullseye-slim"; imageDigest = "sha256:46f854a8f54b0460702602f45eca29aecc4c39135056e378fa7707a81da3744d"; sha256 = "1abahr24hgdlq83vlnsx90b98pgdv1spld7gpkliwa04z6aflc19"; };
            buster = get-image { imageName = "node"; finalImageTag = "18.7.0-buster"; imageDigest = "sha256:5a72c3a0c03daba722426247af63565f5fb932b93a22733288c63d79bd29819e"; sha256 = "1izf7bbs3vygrminfqw6b9m7m24kzzx9jigiicpiw6dbwczv526i"; };
            nixos = { pkgs, ...}: { environment.systemPackages = [ pkgs.nodejs-slim-18_x ]; }; # or nodejs-slim-18_x
        };
        mysql = rec {
            default = oracle; alt = debian;
            oracle = get-image { imageName = "mysql"; finalImageTag = "8.0.30-oracle"; imageDigest = "sha256:ce2ae3bd3e9f001435c4671cf073d1d5ae55d138b16927268474fc54ba09ed79"; sha256 = "0b2sspv5ijijsg95a866sh62hag0qjh3s725vc4lc9iriz137fg9"; };
            debian = get-image { imageName = "mysql"; finalImageTag = "8.0.30-debian"; imageDigest = "sha256:25685dab065bbd127542768e3a697eefbaebb697d29b704d902af3f9930e55cc"; sha256 = "0cz571jprmvkj0rvhn19z20nq3id1y5zv19as305zz3kgwpnyqds"; };
            nixos = { pkgs, ...}: { services.mysql = { enable = true; package = pkgs.mysql80; }; environment.systemPackages = [ pkgs.mysql80 ]; };
        };
        golang = rec {
            default = bullseye; alt = buster;
            bullseye = get-image { imageName = "golang"; finalImageTag = "1.19.0-bullseye"; imageDigest = "sha256:194242a6c45d50400b3ce00f14e6a510fbf414baefa8bf9c093e5f77cb94605f"; sha256 = "0hyvnbfs7vflf448frvf8fjlv39ypjzw44bv4hdngsq6nqdgmnf7"; };
            alpine = get-image { imageName = "golang"; finalImageTag = "1.19.0-alpine"; imageDigest = "sha256:0eb08c89ab1b0c638a9fe2780f7ae3ab18f6ecda2c76b908e09eb8073912045d"; sha256 = "16pb029jrgpiclyn4rgyk27rqbylm6d362ga7yw9432lamz997bg"; };
            buster = get-image { imageName = "golang"; finalImageTag = "1.19.0-buster"; imageDigest = "sha256:a7a23f1fba8390b1e038f017c85259c878f406301643653ec6e5b97e75668789"; sha256 = "11mx0skzaqc325j6hifdv8macicdd68q1c84z58w522rlrn96r2b"; };
        };
        nginx = rec {
            default = get-image { imageName = "nginx"; finalImageTag = "1.23.1"; imageDigest = "sha256:790711e34858c9b0741edffef6ed3d8199d8faa33f2870dea5db70f16384df79"; sha256 = "0bnxyhwbilbb95rmlyjmwzjjxrzsv6vqkzw3cr52ib7126i311vg"; };
            alpine = get-image { imageName = "nginx"; finalImageTag = "1.23.1-alpine"; imageDigest = "sha256:082f8c10bd47b6acc8ef15ae61ae45dd8fde0e9f389a8b5cb23c37408642bf5d"; sha256 = "0b6181nak6mxyvf76cijwh7ki5bh47qwyzz1wp6xsrxdffwa07yw"; };
            nixos = { pkgs, ...}: { services.nginx.enable = true; };
        };
        httpd = rec {
            default = bullseye;
            bullseye = get-image { imageName = "httpd"; finalImageTag = "2.4.54-bullseye"; imageDigest = "sha256:343452ec820a5d59eb3ab9aaa6201d193f91c3354f8c4f29705796d9353d4cc6"; sha256 = "1890brd3sfcrfg6c1a1i3nkh1pgbmdsjskzhx2gdsvmss5fxcl11"; };
            alpine = get-image { imageName = "httpd"; finalImageTag = "2.4.54-alpine"; imageDigest = "sha256:d7001e78101e7873db646e913694a89b54ff276eb4d8423eb2668393981a1dcf"; sha256 = "11hv3ln03aqmxii7jihbpdp7fxwmm5h0zkwk3dxl9kiyziczky7z"; };
            nixos = { pkgs, ...}: { services.httpd = { enable = true; adminAddr = "admin@example.org"; }; };
        };
        wordpress = rec {
            default = get-image { imageName = "wordpress"; finalImageTag = "6.0.1-php7.4-apache"; imageDigest = "sha256:461fb4294c0b885e375c5d94521442fce329cc02ef3f49a8001ea342d14ab71a"; sha256 = "0fjqfgcv7611841bq7bvi6hrpb0b166yfzk2p1b7kk4pcmp3jgkw"; };
            nixos = { pkgs, ...}: { services.wordpress.sites.example = { }; nixpkgs.overlays = [ (final: prev: { php = prev.php.override { packageOverrides = final: prev: { extensions = prev.extensions // {
                fileinfo = prev.extensions.fileinfo.overrideAttrs (attrs: { doCheck = false; }); # this avoids a build error in the package, but it also somehow causes an infinite recursion when included in a nixos-container
            }; }; }; }) ]; } // (fixUser "wordpress" 996);
        };
        registry = rec {
            default = get-image { imageName = "registry"; finalImageTag = "2.8.1"; imageDigest = "sha256:83bb78d7b28f1ac99c68133af32c93e9a1c149bcd3cb6e683a3ee56e312f1c96"; sha256 = "1y1frqp6xaic409fglas8gi2710plfcmxibxg6pmrab91l2kzd04"; };
            nixos = { pkgs, ...}: { services.dockerRegistry.enable = true; } // (fixUser "docker-registry" 995);
        };
        memcached = rec {
            default = bullseye;
            bullseye = get-image { imageName = "memcached"; finalImageTag = "1.6.16-bullseye"; imageDigest = "sha256:0afaa8e890393e089efc991b62ec98d3dd53e5da995abfa548e5df9c70722015"; sha256 = "138n2kmn2scalgmqs7mjfqhi4nrqyk1kyb5gl0zai9kprfwz2d3a"; };
            alpine = get-image { imageName = "memcached"; finalImageTag = "1.6.16-alpine"; imageDigest = "sha256:22fd822b2417986f627bd96bc687e85360200db73e8bc818fe6ffdfe1f24e413"; sha256 = "0k4c3jy55x42i1fqfl4bszhrcx7y16k9wxxpp19115001cs3vzyw"; };
            nixos = { pkgs, ...}: { services.memcached.enable = true; } // (fixUser "memcached" 994);
        };
    };

    select = func: lib.filter (_:_ != null) (map func (lib.attrValues images));
    sets = {
        default = select (_:_.default);
        bullseye = select (_:_.bullseye or null);
        alpine = select (_:_.alpine or null);
        slim = select (_:_.slim or _.default);
        alt = select (_:_.alt or _.default);
        "alpine+" = select (_:_.alpine or _.default);
    };

    tag-version = image: let match = builtins.match ''([1-9][^-]*).*'' image.image.imageTag; in builtins.head match;
    tag-suffix  = image: let match = builtins.match ''[.0-9]*[-](.*)'' image.image.imageTag; in if match == null then "(unnamed)" else builtins.head match;

    #du = paths: ''$( cat ${du-deps paths} )'';
    du = paths: ''$( du --apparent-size --block-size=1 --summarize ${collect-deps paths} | cut -f1 )'';

in { inherit images; script = ''
function sum-size {
    local sum=0 ; while IFS= read -r num ; do
        let sum+=$num
    done < <( cut -f 1 ) ; echo $sum
}

echo -n "\addplot coordinates {" | tee apparent layered store >/dev/null # plot 1
echo -n "\addplot coordinates {" | tee imgMax imgMin nixMini nixBase >/dev/null # plot 2


## Table 1: container image versions and types
echo "name,version,variants" >$out/oci-variants.csv
${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: vars: ''echo "${name},${tag-version vars.default},${tag-suffix vars.default}${if vars?alpine then " alpine" else ""}${if vars?slim then " ${tag-suffix vars.slim}" else ""}${if vars?alt then " alt=${tag-suffix vars.alt}" else ""} \\\\" >>$out/oci-variants.csv'') images)}


## Table 2: container image and NixOS install sizes
## Plot 2: table 2 as plot
baseMinSize=${du (toplevel base-minimal)}
baseBasSize=${du (toplevel base-baseline)}
echo "variant,service,size" >$out/oci-individual.csv
${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: vars: ''
    imgMin=$(( 10 ** 12 )) ; imgMax=0
    ${lib.concatMapStringsSep "\n" (image: ''
        size=$( <${image.info}/layers sum-size )
        if (( size < imgMin )) ; then imgMin=$size ; fi
        if (( size > imgMax )) ; then imgMax=$size ; fi
    '') (lib.attrValues (builtins.intersectAttrs { default = true; bullseye = true; alpine = true; slim = true; alt = true; } vars))}

    ${if vars?nixos then ''
        nixMini=$(( ${du (toplevel (override base-minimal  vars.nixos))} - $baseMinSize ))
        nixBase=$(( ${du (toplevel (override base-baseline vars.nixos))} - $baseBasSize ))
        echo -n " (${name},$imgMax)" >>imgMax ; echo -n " (${name},$imgMin)" >>imgMin ; echo -n " (${name}2,$nixMini)" >>nixMini ; echo -n " (${name}2,$nixBase)" >>nixBase
        echo "reconix diff,${name},$nixMini" >>$out/oci-individual.csv
        echo "nixos diff,${name},nixBase" >>$out/oci-individual.csv
    '' else ""}
    echo "largest,${name},$imgMax" >>$out/oci-individual.csv
    echo "smallest,${name},imgMix" >>$out/oci-individual.csv
'') images)}

''; disabled = '' # stuff that could be appended to »script«, but that we currently don't use

echo "minimal  NixOS with all apps:               $(( ${du (toplevel (override base-minimal  { imports = map (_:_.nixos or { }) (lib.attrValues images); }))} - $baseMinSize ))"
${if false then ''echo "minimal  NixOS with all apps in containers: $(( ${du (toplevel (override base-minimal  { imports = lib.mapAttrsToList (name: vars: if vars?nixos then { th.target.containers.containers.${name}.modules = [ vars.nixos ]; } else { }) images; }))} - $baseMinSize ))"'' else ""}
echo "baseline NixOS with all apps:               $(( ${du (toplevel (override base-baseline { imports = map (_:_.nixos or { }) (lib.attrValues images); }))} - $baseBasSize ))"

${lib.concatMapStringsSep "\n" (series: ''

    rm -f totals layers uniq
    ( ${frame "echo Image Type ${series}"} ) 1>&2
    ${lib.concatMapStringsSep "\n" (image: ''
        self=$( <${image.info}/layers sum-size )
        #echo "${image.name}: $self"
        printf "%s\t%s\n" "$self" "${image.name}" >>totals
        cat ${image.info}/layers >>layers
    '') sets.${series}}
    <layers LC_ALL=C sort -k2 | uniq -f 1 >uniq

    ## Plot 1: combined container storage consumption
    echo -n " (${series},$( <totals sum-size ))" >>apparent
    echo -n " (${series},$( <uniq sum-size ))" >>layered
    echo -n " (${series},${du (lib.concatStringsSep " " sets.${series})})" >>store

    ( ## stderr: more detailed image statistics
        #( set -x ; cat layers )
        #( set -x ; <layers LC_ALL=C sort -k2 | uniq -f1  )
        #( set -x ; cat uniq )
        #( set -x ; cat totals )

        echo "layers total:  $( <totals sum-size )"
        echo "layers merged: $( <uniq sum-size )"
        echo "store merged:  ${du (lib.concatStringsSep " " sets.${series})}"
    ) 1>&2

'') [ "default" "alt" "slim" "bullseye" "alpine" "alpine+" ]}

echo " };" | tee -a apparent layered store >/dev/null
cat apparent layered store >$out/fig-oci-combined.tex
echo '\legend{without sharing, with shared layers, with shared files}' >>$out/fig-oci-combined.tex

echo " };" | tee -a imgMax imgMin nixMini nixBase >/dev/null
cat imgMax imgMin nixMini nixBase >$out/fig-container-individual.tex
echo '\legend{largest image, smallest image, diff minimal NixOS, diff baseline NixOS}' >>$out/fig-container-individual.tex

''; }
