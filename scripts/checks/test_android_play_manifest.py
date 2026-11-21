import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANDROID = "{http://schemas.android.com/apk/res/android}"


class AndroidPlayManifestTests(unittest.TestCase):
    def test_landscape_hardware_is_optional_for_steam_streaming(self):
        app_manifest = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").getroot()
        landscape = [
            feature for feature in app_manifest.findall("uses-feature")
            if feature.get(ANDROID + "name") == "android.hardware.screen.landscape"
        ]
        self.assertEqual(len(landscape), 1)
        self.assertEqual(landscape[0].get(ANDROID + "required"), "false")

        steam_manifest = ET.parse(ROOT / "android/steam/src/main/AndroidManifest.xml").getroot()
        steam_activity = next(
            activity for activity in steam_manifest.findall("application/activity")
            if activity.get(ANDROID + "name") == ".SteamStreamActivity"
        )
        self.assertEqual(steam_activity.get(ANDROID + "screenOrientation"), "sensorLandscape")


if __name__ == "__main__":
    unittest.main()
