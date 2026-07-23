#!/usr/bin/env python3
"""Log one Citar desktop-open argv vector without launching an application."""

import json
import os
import sys
from pathlib import Path


with Path(os.environ["LEM_YATH_CITAR_OPEN_LOG"]).open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
