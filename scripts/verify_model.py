"""Check Core ML structure and generate a real raw-output regression fixture."""
import hashlib
import json
import os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault("YOLO_CONFIG_DIR", str(ROOT / ".cache" / "ultralytics"))

def main():
    import coremltools as ct
    import torch
    import cv2
    import numpy as np
    from ultralytics import YOLO
    from ultralytics.nn.modules import Detect
    from ultralytics.utils.nms import non_max_suppression
    path = ROOT / "Models/yolov8n.mlmodel"
    manifest = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
    assert hashlib.sha256(path.read_bytes()).hexdigest() == manifest["sha256"]
    spec = ct.utils.load_spec(str(path))
    assert spec.WhichOneof("Type") == "neuralNetwork" and spec.specificationVersion <= 5
    assert spec.description.input[0].type.imageType.width == 640
    assert spec.description.input[0].type.imageType.height == 640
    assert len(json.loads(spec.description.metadata.userDefined["phoneyolo.names"])) == 80
    assert len(spec.description.output) == 1
    model = YOLO(str(ROOT / ".cache/yolov8n.pt")).model.float().fuse().eval()
    for m in model.modules():
        if isinstance(m, Detect):
            m.export, m.dynamic, m.format = True, False, "coreml"
    image = cv2.imread(str(ROOT / "Models/bus.jpg"))
    h,w = image.shape[:2]
    ratio = min(640/w,640/h)
    resized = cv2.resize(image, (round(w*ratio), round(h*ratio)))
    canvas = np.full((640,640,3),114,np.uint8)
    y,x = (640-resized.shape[0])//2,(640-resized.shape[1])//2
    canvas[y:y+resized.shape[0],x:x+resized.shape[1]] = resized
    tensor = torch.from_numpy(canvas[:,:,::-1].transpose(2,0,1).copy()).float().unsqueeze(0)/255
    with torch.no_grad():
        raw = model(tensor)
    assert tuple(raw.shape) == (1,84,8400)
    detections = non_max_suppression(raw.clone(), conf_thres=.25, iou_thres=.45, max_det=100)[0].cpu().numpy()
    assert any(int(row[5])==5 for row in detections), "Test image should contain a bus"
    assert any(int(row[5])==0 for row in detections), "Test image should contain people"
    directory = ROOT / ".cache/fixtures"
    directory.mkdir(parents=True, exist_ok=True)
    raw.detach().cpu().numpy().astype("<f4").tofile(str(directory/"bus.raw"))
    rows = [str(len(detections))]
    for x1,y1,x2,y2,score,cls in detections:
        rows.append(f"{x1} {y1} {x2-x1} {y2-y1} {score} {int(cls)}")
    (directory/"bus.expected").write_text("\n".join(rows)+"\n",encoding="utf-8")
    print(json.dumps({"coreml_type":spec.WhichOneof("Type"),"specification":spec.specificationVersion,
        "bytes":path.stat().st_size,"raw_shape":list(raw.shape),"reference_detections":len(detections),
        "labels":[manifest['classes'][int(row[5])] for row in detections],
        "note":"Core ML inference requires macOS/iOS; reference inference here uses PyTorch."},indent=2))

if __name__ == "__main__":
    main()
