#!/usr/bin/env python3
"""Log one browser argv vector without opening a browser."""

import json
import os
import sys
from pathlib import Path


with Path(os.environ["LEM_YATH_DEVDOCS_OPEN_LOG"]).open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
