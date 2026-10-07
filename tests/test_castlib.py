import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "share"))

from castlib import CastSession, decode_message, encode_message  # noqa: E402


class CastFrameTest(unittest.TestCase):
    def test_roundtrip_preserves_the_json_payload(self) -> None:
        payload = json.dumps({"type": "GET_STATUS", "requestId": 1, "note": "x" * 200})
        packet = encode_message("sender-0", "receiver-0", "urn:x-cast:com.google.cast.receiver", payload)
        size = int.from_bytes(packet[:4], "big")
        self.assertEqual(size, len(packet) - 4)
        message = decode_message(packet[4:])
        self.assertEqual(message["source"], "sender-0")
        self.assertEqual(message["dest"], "receiver-0")
        self.assertEqual(message["namespace"], "urn:x-cast:com.google.cast.receiver")
        self.assertEqual(json.loads(message["payload"]), json.loads(payload))

    def test_playback_failure_drains_a_rejected_stream(self) -> None:
        session = CastSession("127.0.0.1")
        session.media_messages.append({"type": "MEDIA_STATUS", "status": [{"playerState": "PLAYING"}]})
        session.media_messages.append(
            {"type": "MEDIA_STATUS", "status": [{"playerState": "IDLE", "idleReason": "ERROR"}]}
        )
        self.assertIn("ERROR", session.playback_failure())
        self.assertEqual(len(session.media_messages), 0)
        self.assertEqual(session.playback_failure(), "")


if __name__ == "__main__":
    unittest.main()
