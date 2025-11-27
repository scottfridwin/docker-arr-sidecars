#!/usr/bin/env python3
import sys
import os
from mutagen.id3 import (
    ID3,
    TXXX,
    TALB,
    TPE1,
    TPE2,
    ID3NoHeaderError
)

file_path = sys.argv[1]

# Read optional environment variables safely
album_title            = os.environ.get("ALBUM_TITLE")
mb_albumid             = os.environ.get("MB_ALBUMID")
mb_releasegroupid      = os.environ.get("MB_RELEASEGROUPID")
artist                 = os.environ.get("ARTIST")
album_artist           = os.environ.get("ALBUMARTIST")
mb_artistid            = os.environ.get("MUSICBRAINZ_ARTISTID")

try:
    tags = ID3(file_path)
except ID3NoHeaderError:
    tags = ID3()

#
# ─── REMOVE OLD VALUES ───────────────────────────────────────────────
#

# Remove old TXXX frames
for desc in (
    "MUSICBRAINZ_ALBUMID",
    "MUSICBRAINZ_RELEASEGROUPID",
    "MUSICBRAINZ_ARTISTID",
):
    try:
        tags.delall(f"TXXX:{desc}")
    except Exception:
        pass

# Remove standard frames we may overwrite
for frame in ("TALB", "TPE1", "TPE2"):
    try:
        tags.delall(frame)
    except Exception:
        pass


#
# ─── WRITE OPTIONAL TAGS ─────────────────────────────────────────────
#

# Album title
if album_title:
    tags.add(TALB(encoding=3, text=[album_title]))

# Artist (TPE1)
if artist:
    tags.add(TPE1(encoding=3, text=[artist]))

# Album Artist (TPE2)
if album_artist:
    tags.add(TPE2(encoding=3, text=[album_artist]))

# MB Album ID
if mb_albumid:
    tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_ALBUMID", text=[mb_albumid]))

# MB Release Group ID
if mb_releasegroupid:
    tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_RELEASEGROUPID", text=[mb_releasegroupid]))

# MB Artist ID
if mb_artistid:
    tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_ARTISTID", text=[mb_artistid]))


#
# ─── SAVE TAGS ───────────────────────────────────────────────────────
#
tags.save(file_path, v2_version=4)
