import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "share"))

from mirror import h264_level  # noqa: E402


class LevelTest(unittest.TestCase):
    def test_720p_stays_on_level_31(self) -> None:
        self.assertEqual(h264_level(1280, 720), "3.1")

    def test_1080p_needs_level_40(self) -> None:
        self.assertEqual(h264_level(1920, 1080), "4.0")

    def test_1440p_needs_level_50(self) -> None:
        self.assertEqual(h264_level(2560, 1440), "5.0")

    def test_2160p_needs_level_51(self) -> None:
        self.assertEqual(h264_level(3840, 2160), "5.1")


if __name__ == "__main__":
    unittest.main()
