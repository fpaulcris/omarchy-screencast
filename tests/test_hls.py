import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "share"))

from server import hls_name  # noqa: E402


class HlsPathTest(unittest.TestCase):
    def test_session_prefix_selects_the_playlist(self) -> None:
        token = "a" * 32
        self.assertEqual(hls_name(token, f"{token}/live.m3u8"), "live.m3u8")
        self.assertEqual(hls_name(token, f"{token}/seg_00001.ts"), "seg_00001.ts")

    def test_bare_playlist_and_wrong_prefix_are_hidden(self) -> None:
        token = "b" * 32
        self.assertEqual(hls_name(token, "live.m3u8"), "")
        self.assertEqual(hls_name(token, f"{'c' * 32}/live.m3u8"), "")
        self.assertEqual(hls_name("", f"{token}/live.m3u8"), "")
        self.assertEqual(hls_name(token, f"{token}/../server.py"), "")


if __name__ == "__main__":
    unittest.main()
