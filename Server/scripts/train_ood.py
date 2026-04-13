import argparse
from pathlib import Path

from ultralytics import YOLO


def main():
    parser = argparse.ArgumentParser(description="Fine-tune YOLO on OOD dataset")
    parser.add_argument("--model", default="yolo12x.pt", help="Base model to fine-tune")
    parser.add_argument("--data", default="datasets/ood/data.yaml", help="Path to data.yaml")
    parser.add_argument("--epochs", type=int, default=100, help="Training epochs")
    parser.add_argument("--batch", type=int, default=8, help="Batch size")
    parser.add_argument("--imgsz", type=int, default=640, help="Image size")
    parser.add_argument("--name", default="ood", help="Run name")
    args = parser.parse_args()

    data_path = Path(args.data)
    if not data_path.exists():
        print(f"ERROR: Dataset not found at {data_path}")
        print()
        print("Download the OOD dataset from Roboflow:")
        print("  https://universe.roboflow.com/fpn/ood-pbnro")
        print()
        print("Export in 'YOLOv8' format and extract to datasets/ood/")
        return

    model = YOLO(args.model)
    model.train(
        data=str(data_path),
        epochs=args.epochs,
        batch=args.batch,
        imgsz=args.imgsz,
        name=args.name,
        patience=20,
        save=True,
        plots=True,
    )

    print()
    print(f"Training complete! Best model saved to: runs/detect/{args.name}/weights/best.pt")
    print(f"Update your .env:  YOLO_MODEL=runs/detect/{args.name}/weights/best.pt")


if __name__ == "__main__":
    main()
