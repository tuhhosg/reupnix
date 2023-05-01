#!/usr/bin/env python3

from pathlib import Path
import sys
#import numpy as np
import pandas as pd
from plotnine import *
from plydata import *
from plydata.tidy import *
from osg.pandas import reorder_by, mapvalues

import data

outDir = data._dir / '..' / 'fig' if len(sys.argv) < 2 else Path(sys.argv[1])

distributions = ['default', 'alt', 'slim', 'bullseye', 'alpine']#s, 'alpine+']
methods = ['Uncompressed', "Shared Layers", "Shared Files"]

df = (data.oci_combined
      >> pivot_longer(cols=select(*methods), names_to='Method',  values_to='Size')
      >> do(reorder_by('Method', methods))
      >> do(reorder_by('Base Image', distributions))
      >> group_by('Base Image')
      >> define(Size_Rel='Size/max(Size)'))

oci_combined = (ggplot(df, aes(x='Base Image', y='Size_Rel* 100', fill='Method'))
 + geom_col(position='dodge2')
 + scale_fill_manual(values = ['tab:blue', 'tab:red', 'tab:green'])
 + geom_text(aes(y=5, label='Size/2**30'), angle=90, position=position_dodge(width=0.89), format_string='{:.1f} GiB', va='bottom')
 + labs(y='Relative Size to Uncomb. [%]',x="")# fill='')
 + annotate("path", x=['default', 'default'], y=[75, 85], color="tab:red", arrow=arrow(length=0.05, type="closed", ends="first", angle=15))
 + annotate("text", x='default', y=85, label='Docker',size=9, ha='left', va='bottom', color='tab:red', nudge_x=-0.1)
 + annotate("path", x=['alt', 'alt'], y=[65, 85], position=position_nudge([0.29,0.29]), color="tab:green", arrow=arrow(length=0.05, type="closed", ends="first", angle=15))
 + annotate("text", x='alt', y=85, label='reUpNix',size=9, ha='left', va='bottom', color='tab:green', nudge_x=-0.1)
 + theme(
        figure_size=(6, 3),
        legend_position=(0.5,0.98),
        legend_title=element_blank(),
        legend_background=element_rect(fill='#fff0', color='#000', size=1),
        legend_box_margin=2,
        axis_text_x=element_text(rotation=45),
        panel_grid_major_x=element_blank(),
    )
)

save_as_pdf_pages([oci_combined], outDir / 'oci_combined.pdf')
