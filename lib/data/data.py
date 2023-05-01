
import sys
import pandas as pd
from pathlib import Path
from plydata import *
from osg.pandas import *
from parse_logs import read_log

_dir = Path(__file__).parent if len(sys.argv) < 2 else Path(sys.argv[1]) # Well. This is ugly. Should have used an env var instead ...

update_nix_cat = """
none|FD|#0570b0
64|FD+64|#74a9cf
4k|FD+4K|#bdc9e1
refs|FD+R|#d7301f
refs+64|FD+R+64|#fc8d59
refs+4k|FD+R+4K|#fdcc8a
bsd-nar+none|BSD(Comp)|#238b45
bsd+none|FD+BSD(File)|#66c2a4
bsd+refs+4k|FD+R+4K+BSD(Chunk)|#b2e2e2
"""
update_nix_cat = [line.strip().split("|") for line in update_nix_cat.strip().split("\n")]


update_nix: pd.DataFrame = pd.read_csv(_dir / 'nix_store_send.csv')
update_nix = (
    update_nix
    >> define(transferWeight='comp_p')
    >> define(
        originalChunkingType='chunkingType',
        chunkingType=mapvalues('chunkingType', [x[0] for x in update_nix_cat], [x[1] or x[0] for x in update_nix_cat])
    )
    >> query('~chunkingType.isna()')
)

systems: pd.DataFrame = read_directory(_dir / 'systems')
systems = (systems >> define(
    is_elf='file_desc.str.contains("ELF") | file_desc.str.contains("Linux kernel")',
    is_file='~mime_type.isin(["os/directory", "os/symlink"])',
    is_dir='mime_type.isin(["os/directory"])',
    is_symlink='mime_type.isin(["os/symlink"])',
))
systems['files'] = 1
systems['component_slug'] = systems.component.transform(lambda x: x.split("-", 1)[1])
systems['component_slug'] = systems.component_slug.str.replace("raspberry", "r")
#for pat in "-bin -2.34-210 -1.20220331 -78.15.0 -2.37.4".split():
for pat in "-bin -210".split():
    systems['component_slug'] = systems.component_slug.str.replace(pat, "", regex=False)

#
#y = [6390883977.900553, 4727900552.486188, 3606353591.1602216, 6332872928.176796, 4631215469.61326, 3944751381.2154694, 4805248618.784531, 4147790055.248619, 3364640883.9779005, 3683701657.458564, 2301104972.3756914, 1682320441.9889507, 1053867403.3149176, 986187845.3038673, 879834254.1436462, 3325966850.8287296, 3287292817.679558, 3055248618.784531]
#distributions = ['default', 'alt', 'slim', 'bullseye', 'alpine', 'alpine+']
#data = [[distributions[i // 3]] + y[i:i+3] for i in range(0, len(y), 3)]
#methods = ['Uncompressed', "Shared Layers", "Shared Files"]

#df = pd.DataFrame(data=data,columns=['Base Image'] + methods)
# df.to_csv('/tmp/test.csv',index=False)
oci_combined = pd.read_csv(_dir/'oci-combined.csv')
oci_individual = pd.read_csv(_dir/'oci-individual.csv')

reboot_logs : pd.DataFrame = read_directory(_dir / 'logs', read=read_log)
