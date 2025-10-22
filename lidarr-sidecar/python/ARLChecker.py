import os
import sys
import logging
from datetime import datetime
from colorama import Fore, init
from requests import Session

# ----------------------------
# Configuration
# ----------------------------
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:83.0) Gecko/20100101 Firefox/110.0"
)

# Initialize logging
init(autoreset=True)
version = "2.0"
logging.basicConfig(
    format=f"ARLChecker.py :: v{version} :: %(levelname)s :: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    level=logging.INFO,
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("ARLChecker")


# ----------------------------
# Deezer Login Checker
# ----------------------------
class DeezerPlatformProvider:
    BASE_URL = "http://www.deezer.com"
    API_PATH = "/ajax/gw-light.php"
    SESSION_DATA = {
        "api_token": "null",
        "api_version": "1.0",
        "input": "3",
        "method": "deezer.getUserData",
    }

    def __init__(self):
        self.session = Session()
        self.session.headers.update({"User-Agent": USER_AGENT})

    def login(self, token: str) -> bool:
        """Check if ARL token is valid by performing a login attempt."""
        try:
            res = self.session.post(
                self.BASE_URL + self.API_PATH,
                cookies={"arl": token.strip('"')},
                data=self.SESSION_DATA,
            )
            res.raise_for_status()
            data = res.json()
        except Exception as e:
            log.error(Fore.RED + f"Error connecting to Deezer: {e}" + Fore.RESET)
            return False

        if "error" in data and data["error"]:
            log.error(
                Fore.RED + f"Deezer API returned error: {data['error']}" + Fore.RESET
            )
            return False

        user_id = data.get("results", {}).get("USER", {}).get("USER_ID", 0)
        if user_id == 0:
            log.error(Fore.RED + "ARL token invalid or expired" + Fore.RESET)
            return False

        log.info(Fore.GREEN + "ARL token is valid" + Fore.RESET)
        return True


# ----------------------------
# ARL File Operations
# ----------------------------
def read_arl() -> str:
    """Read ARL token from the file defined by environment variable."""
    arl_file = os.environ.get("AUDIO_DEEMIX_ARL_FILE")
    if not arl_file or not os.path.isfile(arl_file):
        log.error("ARL file not found. Set AUDIO_DEEMIX_ARL_FILE correctly.")
        return None
    with open(arl_file, "r", encoding="utf-8") as f:
        return f.read().strip().strip('"')


def write_arl(new_token: str) -> bool:
    """Write new ARL token to the environment-specified file."""
    arl_file = os.environ.get("AUDIO_DEEMIX_ARL_FILE")
    if not arl_file:
        log.error("AUDIO_DEEMIX_ARL_FILE environment variable not set")
        return False
    with open(arl_file, "w", encoding="utf-8") as f:
        f.write(new_token.strip('"') + "\n")
    log.info(f"New ARL token written to {arl_file}")
    return True


# ----------------------------
# Token Check Wrapper
# ----------------------------
def check_token(token: str) -> bool:
    """Validate the ARL token via Deezer API."""
    log.info(f"Checking ARL token")
    deezer = DeezerPlatformProvider()
    return deezer.login(token)


# ----------------------------
# Main
# ----------------------------
def main():
    arl = read_arl()
    if not arl:
        log.error("No ARL token available")
        exit(1)

    if not check_token(arl):
        log.error("ARL token invalid or expired")
        exit(2)

    log.info("ARL token check complete. No issues found.")


if __name__ == "__main__":
    main()
