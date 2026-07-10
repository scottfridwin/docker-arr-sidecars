import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.service import _build_release_track_id_map


class ServiceTrackMapTests(unittest.TestCase):
    def test_build_release_track_id_map_extracts_disc_track_and_ids(self):
        release_data = {
            "media": [
                {
                    "position": "1",
                    "tracks": [
                        {
                            "number": "1",
                            "id": "release-track-1",
                            "recording": {"id": "recording-1"},
                        },
                        {
                            "number": "2/10",
                            "id": "release-track-2",
                            "recording": {"id": "recording-2"},
                        },
                    ],
                },
                {
                    "position": "2",
                    "tracks": [
                        {
                            "position": 1,
                            "id": "release-track-3",
                            "recording": {"id": "recording-3"},
                        }
                    ],
                },
            ]
        }

        mapping = _build_release_track_id_map(release_data)

        self.assertEqual(mapping[(1, 1)], ("recording-1", "release-track-1"))
        self.assertEqual(mapping[(1, 2)], ("recording-2", "release-track-2"))
        self.assertEqual(mapping[(2, 1)], ("recording-3", "release-track-3"))


if __name__ == "__main__":
    unittest.main()
