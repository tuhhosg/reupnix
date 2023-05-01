#!/usr/bin/env python3

import pandas as pd
import re
import sys
import numpy as np
from osg.pandas import read_directory

def parse(fn):
    data = []
    with open(fn) as fd:
        for line in fd.readlines():
            if not line.strip(): continue
            m = re.match('\[(\d\d):(\d\d):(\d\d).(\d\d\d)\] (.*)', line)
            if not m:
                print(line)
            h,m,s,ms,log = m.groups()
            ts = int(h) *3600 + int(m)*60+int(s) + int(ms)/1000.0
            data.append([ts, log])
    return pd.DataFrame(data=data,columns=['timestamp', 'msg'])

def categorize(msg):
    if 'Stopping session-2.scope' in msg:
        return 'poweroff_start'
    if 'reboot: Restarting system' in msg:
        return 'poweroff_stop'
    if 'U-Boot 2022.01' in msg:
        return 'uboot_start'
    if re.match('Retrieving file:.*initrd', msg):
        return 'load_initrd'
    if re.match('Retrieving file:.*Image', msg):
        return 'load_kernel'
    if 'Starting kernel ...' in msg:
        return 'uboot_stop'
    if 'NixOS Stage 1' in msg:
        return 'stage1_start'
    if 'NixOS Stage 2' in msg:
        return 'stage2_start'
    if 'Reached target multi-user.target' in msg:
        return 'reboot_stop'
    return np.nan

def condense(fn,df):
    data = {}
    for _,row in df[~df.event.isna()].iterrows():
        data[row.event] = row
    return dict(
        fn=fn,
        total=data['reboot_stop'].timestamp - data['poweroff_start'].timestamp,
        poweroff=data['poweroff_stop'].timestamp - data['poweroff_start'].timestamp,
        firmware=data['uboot_start'].timestamp - data['poweroff_stop'].timestamp,
        uboot=data['uboot_stop'].timestamp - data['uboot_start'].timestamp,
        nixos=data['reboot_stop'].timestamp - data['uboot_stop'].timestamp,
        kernel=data['load_kernel'].timestamp_next - data['load_kernel'].timestamp,
        initrd=data['load_initrd'].timestamp_next - data['load_initrd'].timestamp,
    )

def read_log(fn):
    df = parse(fn)
    df['event'] = df.msg.apply(categorize)
    df['timestamp_next'] = df.timestamp.shift(-1)
    return pd.DataFrame(data=[condense(fn,df)])

if __name__ == "__main__":
    df = read_directory(sys.argv[1], read=read_log)
    print(df)
