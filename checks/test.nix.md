/*

# Testing the Tests

## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs measure-installation nix-store-send run-in-vm;

    new = unpinInputs inputs.self.nixosConfigurations.    "x64-minimal";
    old = unpinInputs inputs.self.nixosConfigurations."old:x64-minimal";

    frame = script: ''
        echo "================="
        ${script}
        echo "================="
    '';

in ''

${run-in-vm new { } (let
    set-the-bar = { pre = "$ssh -- 'echo foo >/tmp/bar'"; };
    try-the-bar = { test = frame "if [[ $(cat /tmp/bar) == foo ]] ; then echo yay ; else echo 'oh no!' ; false ; fi "; };
in [
    (set-the-bar // try-the-bar)
    (set-the-bar // { test = "true"; })
    (try-the-bar)
    (frame "uname -a")
    (frame ''echo "this one fails" ; false'')
    (frame ''echo "this shouldn't run"'')
])}

''
