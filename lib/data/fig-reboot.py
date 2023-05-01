#!/usr/bin/env python3

from pathlib import Path
import sys
#import numpy as np
import pandas as pd
from plotnine import *
from plydata import *
from plydata.tidy import *
from osg.pandas import reorder_by, mapvalues
import numpy as np

import data

outDir = data._dir / '..' / 'fig' if len(sys.argv) < 2 else Path(sys.argv[1])

phases = ['poweroff', 'firmware', 'uboot', 'nixos']
phase_names = ['PowerOff', "RPi Firmw.", 'U-Boot', 'reUpNix']

means = (data.reboot_logs
  >> select(*phases)
  >> summarize_all('mean'))
print(means.iloc[0].to_list())

pdf = (means
  >> pivot_longer(cols=select(*phases),
                  names_to='component', values_to='duration')
  >> do(reorder_by('component', reversed(phases)))
  >> define(component_label=mapvalues('component', phases, phase_names))
  >> (ggplot(aes(y='duration', x=1))
      + geom_col(aes(y='duration', fill='component'), show_legend=False, width=0.5)
      + geom_text(aes(label='duration', x=1), format_string='{:.1f}',
                position=position_stack(vjust=0.5))
      + geom_text(aes(label='component_label', x=1.5),
                 position=position_stack(vjust=0.5))
      + coord_flip() + lims(x=[0.7,1.6])
      + labs(y='Boot Time [s]',x=None)
      + scale_fill_manual(['#e41a1c','#377eb8','#4daf4a','#984ea3'])
      + scale_y_continuous(breaks=[0]+means.iloc[0].cumsum().to_list())
      + theme_minimal()
       + theme(
         figure_size=(6,1),
         #legend_position=(0.,1),
         panel_grid_major_y=element_blank(),
         panel_grid_minor_y=element_blank(),
         axis_text_y=element_blank(),
         axis_text_x=element_text(margin=dict(t=-8)),
         axis_title_y=element_blank(),
         axis_ticks_major_y=element_blank(),
         # axis_ticks_minor_y=element_blank(),
         legend_title=element_blank(),
         legend_background=element_rect(fill='#fff0', color='#0000', size=1),
         #legend_box_margin=2,
       )
     )
)

save_as_pdf_pages([pdf], outDir / 'reboot.pdf')
