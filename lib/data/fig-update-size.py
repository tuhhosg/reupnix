#!/usr/bin/env python3

from pathlib import Path
import sys
#import numpy as np
import pandas as pd
from plotnine import *
from plydata import *
from osg.pandas import reorder_by, mapvalues

import data

outDir = data._dir / '..' / 'fig' if len(sys.argv) < 2 else Path(sys.argv[1])

L = labeller(cols=lambda x: data.facet_labels[x])

print(set(data.update_nix.chunkingType.astype('category')))

cb2_red = ['#bdc9e1','#74a9cf','']
cb2_blue = ['#fdcc8a','#fc8d59','#d7301f']

cat = data.update_nix_cat

df: pd.DataFrame = (data.update_nix
      >> define(
          systemType=mapvalues('systemType',
                               'minimal noKernel withMqtt withOci'.split(),
                               "Base System|Base w/o Kernel|MQTT/Nix|MQTT/OCI".split('|')),
          changeType=mapvalues('after',
                               'clb new app'.split(),
                               'Update Libc|75 Days|Version Update'.split("|"))
      )
      #>> define(usesBSdiff=lambda df: list(map(lambda t: t.startswith('bsd+'), df['chunkingType'])))
      #>> define(chunkingType=lambda df: df['chunkingType'].map(lambda t: t.replace('bsd+ ')))
      #>> define(transferWeight='comp_p*(time_U+time_S)')
      #>> define(transferWeight='time_M')
      >> define(
          label_va=if_else('transferWeight < 15','"bottom"', '"top"'),
          label=if_else('transferWeight <1','transferWeight.round(2)', 'transferWeight.round(1)'),
      )
     )

base_update=(df
             >> group_by('systemType', 'changeType')
             >> summarize(file_s='file_s.values[0]/2**20'))

transfer = (ggplot(df, aes(x='chunkingType', y='transferWeight', fill='chunkingType'))
 + geom_col(position='dodge2')
 + scale_fill_manual(values={(x[1] or x[0]): x[2] for x in cat})
 + facet_grid('changeType ~ systemType')#, scales='free')
 + labs(x='', y='Remaining Transfer Size [%]', fill='Chunking')
 + geom_text(aes(va='label_va', label='label'), angle=90, position=position_dodge(width=0.9), size=7,
             format_string=" {} ")
 + guides(fill=guide_legend(nrow=2))
 + geom_label(aes(x='"FD+R+4K+BSD(Block)"',y=34,label='file_s'), data=base_update,
              format_string="{:.1f} MiB",size=7,inherit_aes=False,va='top',ha='right',
             )
 + theme(
     legend_position=(0.5,1),
     axis_text_x=element_blank(),
     axis_ticks_major_x=element_blank(),
     legend_title=element_blank(),
     legend_background=element_rect(fill='#fff0', color='#0000', size=1),
     legend_box_margin=2,
 )
)

#save_as_pdf_pages([transfer], data._dir / __import__('os').path.basename(__file__).replace('.py', '.pdf'))
save_as_pdf_pages([transfer], outDir / 'update-size.pdf')

