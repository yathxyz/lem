#!/usr/bin/env python3
"""Log xdg-open argv without opening a browser."""

import json
import os
import sys
from pathlib import Path


with Path(os.environ["LEM_YATH_ELFEED_OPEN_LOG"]).open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
