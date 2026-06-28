#!/usr/bin/env python3
"""
Download and convert MobileSAM to ONNX format.
Run this ONCE on any computer, then copy the .onnx file
into the Flutter project at: assets/models/mobile_sam_encoder.onnx

Usage:
    pip install onnx torch torchvision
    pip install git+https://github.com/ChaoningZhang/MobileSAM.git
    python download_mobilesam.py
"""

import urllib.request
import os

MODEL_URL = "https://github.com/ChaoningZhang/MobileSAM/raw/master/weights/mobile_sam.pt"
OUTPUT_ONNX = "mobile_sam_encoder.onnx"

def download_and_convert():
    print("Step 1: Downloading MobileSAM weights (~38MB)...")
    if not os.path.exists("mobile_sam.pt"):
        urllib.request.urlretrieve(MODEL_URL, "mobile_sam.pt",
            reporthook=lambda b, bs, t: print(f"  {min(100, int(b*bs*100/t))}%", end='\r'))
    print("\nDownload complete.")

    print("Step 2: Converting to ONNX...")
    try:
        import torch
        from mobile_sam import sam_model_registry, SamAutomaticMaskGenerator

        model = sam_model_registry["vit_t"](checkpoint="mobile_sam.pt")
        model.eval()

        # Export just the image encoder to ONNX
        dummy = torch.randn(1, 3, 1024, 1024)
        torch.onnx.export(
            model.image_encoder,
            dummy,
            OUTPUT_ONNX,
            opset_version=17,
            input_names=["image"],
            output_names=["image_embeddings"],
            dynamic_axes={"image": {0: "batch"}},
        )
        print(f"Saved: {OUTPUT_ONNX}")
        print(f"\nNow copy {OUTPUT_ONNX} to:")
        print("  flutter_project/assets/models/mobile_sam_encoder.onnx")

    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Run: pip install onnx torch torchvision")
        print("     pip install git+https://github.com/ChaoningZhang/MobileSAM.git")

if __name__ == "__main__":
    download_and_convert()
