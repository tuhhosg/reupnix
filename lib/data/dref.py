#!/usr/bin/env python3

from pathlib import Path
from plydata import *
from plydata.tidy import *
from plydata.cat_tools import *
import data
import sys
from scipy.stats.mstats import gmean# from scipy.stats import geom
from versuchung.tex import DatarefDict
import numpy as np
import osg

outDir = data._dir if len(sys.argv) < 2 else Path(sys.argv[1])

dref = DatarefDict(outDir / "dref.tex")
dref.clear()

base_systems = (
    data.systems
    >> group_by('variant')
    >> summarize(
        total_size='sum(st_size)',
        elf_size='sum(st_size * is_elf)',
        components='len(set(component))',
        files='sum(is_file)',
        directories='sum(is_dir)',
        symlinks='sum(mime_type == "os/symlink")',
    )
    >> rename_all(lambda x: 'store/' + x)
)

dref.pandas(base_systems.set_index(['store/variant']))


# TOP X Components
data.systems['files'] = 1
df = data.systems.groupby(['variant', 'component_slug']).agg(dict(st_size=sum, files=sum)).reset_index()

df = (df
 >> group_by('variant')
 >> arrange('-st_size')
 >> head(10)
 >> define(rank='range(0,10)')
)

dref.pandas(df.set_index(['rank','variant'])[['component_slug', 'st_size']],
            prefix='top-n')

top_files = (
    data.systems
    >> group_by('variant', 'component_slug')
    >> summarize(files="sum(files)")
    >> pivot_wider(names_from="variant", values_from="files")
    >> arrange('-Q("x64/baseline")')
    >> head(5)
    >> rename_all(lambda x: x + "/files")
)
dref.pandas(top_files.set_index('component_slug/files').T)

dref.pandas(data.oci_combined.set_index('Base Image'), 'oci-combined')

df = (data.oci_individual
      >> pivot_wider(names_from="service", values_from="size"))

dref.pandas(df.set_index("variant"), 'oci-individual')


dref.pandas(data.update_nix.set_index(['systemType', 'after', 'originalChunkingType'])[['comp_p']],
            'update')

for g, df in data.update_nix.groupby(['originalChunkingType']):
    x = osg.pandas.select_quantiles(df, q=[0,1], columns=['comp_p'],
                         q_labels=True, value_cols=['systemType', 'after', 'comp_p'], value_col='value')
    dref.pandas(x, f'update/{g}')

base_update=(data.update_nix
             >> group_by('systemType', 'after')
             >> summarize(file_s='file_s.values[0]/2**20'))

dref.pandas(base_update.set_index(['systemType', 'after']),
            'update/baseline')

dref.pandas(data.reboot_logs.describe().T,
            'reconf')

dref.flush()

