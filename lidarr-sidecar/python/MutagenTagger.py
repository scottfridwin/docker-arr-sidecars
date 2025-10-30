#!/usr/bin/env python3
import sys
import os
from mutagen.id3 import ID3, TXXX, TALB, ID3NoHeaderError

if len(sys.argv) < 5:
    print(
        "Usage: tag_mp3.py <file> <album_title> <mb_albumid> <mb_releasegroupid>",
        file=sys.stderr,
    )
    sys.exit(2)

file_path = sys.argv[1]
album_title = os.environ["ALBUM_TITLE"]
mb_albumid = os.environ["MB_ALBUMID"]
mb_releasegroupid = os.environ["MB_RELEASEGROUPID"]

try:
    tags = ID3(file_path)
except ID3NoHeaderError:
    tags = ID3()

# Remove previous custom MusicBrainz TXXX tags
for desc in ("MUSICBRAINZ_ALBUMID", "MUSICBRAINZ_RELEASEGROUPID"):
    try:
        tags.delall(f"TXXX:{desc}")
    except Exception:
        pass

# Remove any existing album (TALB) frames
try:
    tags.delall("TALB")
except Exception:
    pass

# Add new frames — text must be a list
if mb_albumid:
    tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_ALBUMID", text=[mb_albumid]))
if mb_releasegroupid:
    tags.add(
        TXXX(encoding=3, desc="MUSICBRAINZ_RELEASEGROUPID", text=[mb_releasegroupid])
    )

# Set album title
tags.add(TALB(encoding=3, text=[album_title]))

# Save as ID3v2.4
tags.save(v2_version=4)
