#!/usr/bin/env python3

import sys
from pathlib import Path
import os
import pandas as pd
import magic


if len(sys.argv) != 4: print(f"Usage: {sys.argv[0]} SYSTEM_ID NIX_STORE_DIR OUTPUT_PATH") ; sys.exit(-1)
_, systemId, nixStoreDir, outputPath = sys.argv ; nixStoreDir = Path(nixStoreDir) ; outputPath = Path(outputPath)


inodes = set()
def stat_file(path: Path):
    # Nix Store Deduplication
    stat = path.lstat()
    if stat.st_ino in inodes:
        return None
    inodes.add(stat.st_ino)

    d = dict(name=path,
             st_size = stat.st_size,
             )

    if path.is_symlink():
        d['mime_type'] = 'os/symlink'
        d['file_desc'] = 'Symlink'
    elif path.is_file():
        try:
            with open(path, 'rb') as fd:
                data = fd.read(2048)
            d['mime_type'] = magic.from_buffer(data, mime=True)
            d['file_desc'] = magic.from_buffer(data)
        except Exception as err:
            if path.suffix == '.lock': return None
            raise err
    elif path.is_dir():
        d['mime_type'] = 'os/directory'
        d['file_desc'] = 'Directory'
    else:
        assert False, path

    return d


def stat_component(component: Path):
    dfs: 'list[pd.DataFrame]' = []
    dfs.append(stat_file(component))
    if component.is_dir():
        for (root, dirs, files) in os.walk(component):
            for x in dirs + files:
                if d := stat_file(Path(root) / x):
                    dfs.append(d)
    df = pd.DataFrame(data=dfs)
    df['component'] = component.name
    return df


dfs: 'list[pd.DataFrame]' = []
if nixStoreDir.is_file():
    with open(nixStoreDir) as fd:
        for comp in fd.readlines():
            df = stat_component(nixStoreDir.parent/Path(comp.strip()).name)
            dfs.append(df)
else:
    for comp in nixStoreDir.iterdir():
        df = stat_component(comp)
        dfs.append(df)

df = pd.concat(dfs)
df['variant'] = systemId

df.to_csv(outputPath)

#df['files'] = 1
#print(df.groupby(['variant', 'mime_type']).agg(dict(st_size=sum, files=len)))
