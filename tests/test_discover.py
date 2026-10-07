import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "share"))

from discover import build, unescape  # noqa: E402

SAMPLE = """
=;enp42s0;IPv4;TPM191E;_googlecast._tcp;local;host.local;192.168.0.152;8009;"md=TPM191E" "fn=TV" "ca=264709" "rs=TV"
=;enp42s0;IPv4;TV;_androidtvremote2._tcp;local;Android.local;192.168.0.152;6466;"bt=34:F1:50:1E:CD:F5"
=;enp42s0;IPv4;Google-Nest-Hub;_googlecast._tcp;local;fuchsia.local;192.168.0.237;8009;"md=Google Nest Hub" "fn=Kitchen 2 Display" "ca=231941"
=;enp42s0;IPv4;Google-Nest-Mini;_googlecast._tcp;local;mini.local;192.168.0.50;8009;"md=Google Nest Mini" "fn=Speaker" "ca=4"
=;enp42s0;IPv4;amzn;_amzn-wplay._tcp;local;fire.local;192.168.0.144;38083;"n=Floricica's Fire TV"
=;enp42s0;IPv6;TPM191E;_googlecast._tcp;local;host.local;fe80::1;8009;"fn=TV"
"""


class DiscoverTest(unittest.TestCase):
    def test_merges_cast_and_marks_what_can_mirror(self) -> None:
        payload = build(SAMPLE, probe=lambda ip: ip == "192.168.0.144")
        by_id = {item["id"]: item for item in payload["receivers"]}

        tv = by_id["Chromecast:192.168.0.152"]
        self.assertEqual(tv["name"], "TV")
        self.assertEqual(tv["model"], "TPM191E")
        self.assertTrue(tv["canMirror"])
        self.assertEqual([item["name"] for item in tv["protocols"]], ["Chromecast", "Android TV Remote"])

        hub = by_id["Chromecast:192.168.0.237"]
        self.assertTrue(hub["canMirror"])
        self.assertEqual(hub["name"], "Kitchen 2 Display")

        speaker = by_id["Chromecast:192.168.0.50"]
        self.assertFalse(speaker["canMirror"])
        self.assertFalse(speaker["video"])
        self.assertIn("speaker", speaker["note"])

        fire = by_id["FireTV:192.168.0.144"]
        self.assertFalse(fire["canMirror"])
        self.assertEqual(fire["name"], "Floricica's Fire TV")
        self.assertIn("DIAL", [item["name"] for item in fire["protocols"]])
        self.assertIn("Netflix", fire["note"])

        self.assertNotIn("Chromecast:fe80::1", by_id)
        json.dumps(payload)

    def test_avahi_decimal_escapes_are_spaces(self) -> None:
        self.assertEqual(unescape(r"Google\032Inc\.\032Hub"), "Google Inc. Hub")
        self.assertEqual(unescape(r"caf\195\169"), "café")
        payload = build(
            '=;enp42s0;IPv4;Samsung\\0327\\032Series\\032\\04043\\041;_airplay._tcp;local;TIZEN.local;192.168.0.174;40998;"model=URU7100"\n',
            probe=lambda ip: False,
        )
        tv = payload["receivers"][0]
        self.assertEqual(tv["name"], "Samsung 7 Series (43)")
        self.assertEqual(tv["model"], "URU7100")
        self.assertNotIn("\x1a", tv["name"])


if __name__ == "__main__":
    unittest.main()
