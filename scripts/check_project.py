"""Standard-library checks usable on Windows and in macOS CI."""
import hashlib
import json
import plistlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def main():
    for name in ["App/Resources/Info.plist", "App/entitlements.plist", "PhoneYOLO.plist"]:
        plistlib.loads((ROOT/name).read_bytes())
    manifest=json.loads((ROOT/"Models/yolov8n.json").read_text(encoding="utf-8"))
    model=ROOT/"Models"/manifest["model"]
    assert hashlib.sha256(model.read_bytes()).hexdigest()==manifest["sha256"]
    assert manifest["minimum_ios"]==14 and len(manifest["classes"])==80
    assert (ROOT/"Models/bus.jpg").stat().st_size>10000
    for directory in ["Sources","App","scripts","Tests",".github"]:
        for file in (ROOT/directory).rglob("*"):
            if file.suffix not in {".h",".hpp",".cpp",".m",".mm",".py",".yml",".swift",".plist"}:continue
            data=file.read_bytes()
            assert not data.startswith(b"\xef\xbb\xbf"),str(file)
            assert b"\r\n" not in data,str(file)
            assert ("@@"+"NAME"+"@@") not in data.decode("utf-8"),str(file)
    print(f"PASS: plists, source encoding, bundled model SHA256 {manifest['sha256']}")

if __name__=="__main__":main()
