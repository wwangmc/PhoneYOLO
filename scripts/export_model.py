"""Export YOLOv8 detect to the iOS 14 NeuralNetwork format (not ML Program)."""
import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault("YOLO_CONFIG_DIR", str(ROOT / ".cache" / "ultralytics"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", default=str(ROOT / ".cache" / "yolov8n.pt"))
    parser.add_argument("--output", type=Path, default=ROOT / "Models" / "yolov8n.mlmodel")
    parser.add_argument("--size", type=int, default=640)
    args = parser.parse_args()
    import torch
    import coremltools as ct
    from ultralytics import YOLO
    from ultralytics.nn.modules import Detect

    args.output.parent.mkdir(parents=True, exist_ok=True)
    Path(args.weights).parent.mkdir(parents=True, exist_ok=True)
    yolo = YOLO(args.weights)
    if yolo.task != "detect":
        raise ValueError("Only YOLOv8 object detection models are supported")
    network = yolo.model.cpu().float().fuse().eval()
    for parameter in network.parameters():
        parameter.requires_grad = False
    for module in network.modules():
        if isinstance(module, Detect):
            module.export, module.dynamic, module.format = True, False, "coreml"
    sample = torch.zeros(1, 3, args.size, args.size)
    with torch.no_grad():
        raw = network(sample)
        if not isinstance(raw, torch.Tensor) or raw.ndim != 3 or raw.shape[1] != len(yolo.names)+4:
            raise ValueError("Expected YOLOv8 detect raw output [1, 4+classes, N]")
        traced = torch.jit.trace(network, sample, strict=False)
    model = ct.convert(
        traced, convert_to="neuralnetwork", minimum_deployment_target=ct.target.iOS14,
        inputs=[ct.ImageType(name="image", shape=sample.shape, scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="predictions")],
    )
    names = [yolo.names[i] for i in range(len(yolo.names))]
    model.user_defined_metadata.update({"phoneyolo.names": json.dumps(names),
        "phoneyolo.format": "yolov8_raw", "phoneyolo.input_size": str(args.size)})
    model.short_description = "YOLOv8 detect, RGB letterbox 114, raw xywh pixels + class probabilities"
    model.author = "Ultralytics (weights); PhoneYOLO (conversion)"
    model.license = "Ultralytics AGPL-3.0 or commercial license: https://www.ultralytics.com/license"
    spec = model.get_spec()
    spec.description.output[0].type.multiArrayType.shape[:] = list(raw.shape)
    model = ct.models.MLModel(spec, skip_model_load=True)
    model.save(str(args.output))
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    manifest = {"model": args.output.name, "sha256": digest, "input_size": args.size,
                "format": "yolov8_raw", "minimum_ios": 14, "classes": names,
                "weights": Path(args.weights).name,
                "source": ("https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt"
                           if Path(args.weights).name=="yolov8n.pt" else "user-supplied checkpoint"),
                "torch": torch.__version__, "coremltools": ct.__version__}
    args.output.with_suffix(".json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"path": str(args.output), "sha256": digest, "bytes": args.output.stat().st_size}))


if __name__ == "__main__":
    main()
