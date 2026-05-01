# SPDX-License-Identifier: GPL-3.0-only

from shared.python.autoimport.runner import main
from shared.python.autoimport.strategy import radarr_strategy


def run() -> None:
    main(radarr_strategy())


def main() -> None:
    run()
