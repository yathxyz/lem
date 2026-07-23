#!/usr/bin/env python3
"""Log browser argv for the Notmuch-to-Salta acceptance test."""

import json
import os
import sys
from pathlib import Path


with Path(os.environ["LEM_YATH_NOTMUCH_OPEN_LOG"]).open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
