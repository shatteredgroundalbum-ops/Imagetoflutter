#!/usr/bin/env python3
"""
Image to Flutter Layer Separator — FastAPI Backend
===================================================
Receives an image, segments it with SAM (or classical fallback),
applies Shapely precision geometry analysis to every object,
generates sprite sheet + Flutter code with CAD-grade positional data.

Install:
    pip install fastapi uvicorn python-multipart pillow numpy opencv-python-headless shapely
    pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
    pip install segment-anything
    pip install rembg   # optional

Run:
    uvicorn app:app --reload --port 8000
"""

import io
import os
import base64
import json
import math
import uuid
import zipfile
import tempfile
import traceback
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
from PIL import Image
from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.responses import JSONResponse, FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

# ---------------------------------------------------------------------------
# Shapely — precision geometry
# ---------------------------------------------------------------------------
try:
    from shapely.geometry import Polygon, MultiPolygon, Point, LineString
    from shapely.ops import unary_union
    import shapely.affinity as affinity
    SHAPELY_AVAILABLE = True
except ImportError:
    SHAPELY_AVAILABLE = False

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
app = FastAPI(title="Image to Flutter Layer Separator")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

WORK_DIR = Path(tempfile.gettempdir()) / "flutter_layers"
WORK_DIR.mkdir(exist_ok=True)

app.mount("/static", StaticFiles(directory=str(WORK_DIR)), name="static")

UI_PATH = Path(__file__).parent / "static" / "index.html"


@app.get("/", response_class=HTMLResponse)
async def serve_ui():
    if UI_PATH.exists():
        return HTMLResponse(content=UI_PATH.read_text())
    return HTMLResponse("<h1>UI not found — place index.html in static/</h1>")


# ---------------------------------------------------------------------------
# Segmentation — SAM preferred, classical fallback
# ---------------------------------------------------------------------------

def try_sam(img_rgb: np.ndarray, confidence: float = 0.85):
    """Try SAM segmentation. Returns list of mask dicts or None."""
    try:
        from segment_anything import sam_model_registry, SamAutomaticMaskGenerator
        model_path = Path(__file__).parent / "sam_vit_b_01ec64.pth"
        if not model_path.exists():
            return None
        sam = sam_model_registry["vit_b"](checkpoint=str(model_path))
        generator = SamAutomaticMaskGenerator(
            sam,
            pred_iou_thresh=confidence,
            stability_score_thresh=0.90,
            min_mask_region_area=500,
        )
        return generator.generate(img_rgb)
    except Exception:
        return None


def try_rembg(img_pil: Image.Image):
    """Try rembg background removal. Returns RGBA numpy array or None."""
    try:
        from rembg import remove
        result = remove(img_pil)
        return np.array(result)
    except Exception:
        return None


def classical_segment(
    img_bgra: np.ndarray,
    min_area: int = 500,
    blur_k: int = 5,
    canny_lo: int = 30,
    canny_hi: int = 120,
    morph_k: int = 7,
) -> list:
    """Classical edge-detect fallback."""
    gray = cv2.cvtColor(img_bgra, cv2.COLOR_BGRA2GRAY)
    blurred = cv2.GaussianBlur(gray, (blur_k | 1, blur_k | 1), 0)
    edges = cv2.Canny(blurred, canny_lo, canny_hi)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (morph_k, morph_k))
    closed = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, kernel, iterations=3)
    dilated = cv2.dilate(closed, kernel, iterations=2)
    num_labels, labels = cv2.connectedComponents(dilated)

    masks = []
    for lbl in range(1, num_labels):
        m = (labels == lbl).astype(np.uint8) * 255
        area = int(cv2.countNonZero(m))
        if area < min_area:
            continue
        contours, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            continue
        c = max(contours, key=cv2.contourArea)
        filled = np.zeros_like(m)
        cv2.drawContours(filled, [c], -1, 255, cv2.FILLED)
        masks.append({
            "segmentation": filled > 0,
            "area": area,
            "bbox": list(cv2.boundingRect(c)),
        })
    masks.sort(key=lambda x: x["area"], reverse=True)
    return masks


# ---------------------------------------------------------------------------
# Precision Geometry — Shapely CAD layer
# ---------------------------------------------------------------------------

def extract_precise_contour(mask_uint8: np.ndarray, epsilon_factor: float = 0.002) -> list:
    """
    Extract a simplified, precise polygon contour from a binary mask.
    Uses Douglas-Peucker simplification (same algorithm used in CAD/GIS tools).
    Returns a list of (x, y) coordinate pairs.
    """
    contours, _ = cv2.findContours(mask_uint8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return []
    c = max(contours, key=cv2.contourArea)
    perimeter = cv2.arcLength(c, True)
    epsilon = epsilon_factor * perimeter
    approx = cv2.approxPolyDP(c, epsilon, True)
    return [(int(p[0][0]), int(p[0][1])) for p in approx]


def compute_geometry(
    contour_points: list,
    mask_uint8: np.ndarray,
    img_w: int,
    img_h: int,
) -> dict:
    """
    Run full Shapely precision geometry analysis on an object.

    Returns a geometry dict containing:
      - centroid: precise center point
      - area_px: exact pixel area from Shapely (more accurate than cv2)
      - perimeter_px: precise perimeter length
      - bounding_box: tight axis-aligned bounding box
      - convex_hull: convex hull polygon points
      - is_convex: whether the shape is convex
      - aspect_ratio: width / height
      - solidity: area / convex_hull_area (1.0 = perfectly solid, no holes)
      - compactness: how circular the shape is (1.0 = perfect circle)
      - orientation_deg: angle of the major axis in degrees
      - anchor_points: precise top/bottom/left/right/center anchor points
      - normalized: all key measurements as 0.0–1.0 fractions of image size
      - contour_svg_path: the outline as an SVG path string (d attribute)
      - contour_flutter: the outline as a Flutter Path() code string
    """
    if not SHAPELY_AVAILABLE or len(contour_points) < 3:
        return _geometry_fallback(mask_uint8, img_w, img_h)

    try:
        poly = Polygon(contour_points)
        if not poly.is_valid:
            poly = poly.buffer(0)  # fix self-intersections
        if poly.is_empty:
            return _geometry_fallback(mask_uint8, img_w, img_h)

        # Core measurements
        centroid = poly.centroid
        area = poly.area
        perimeter = poly.length
        bounds = poly.bounds  # (minx, miny, maxx, maxy)
        minx, miny, maxx, maxy = bounds
        width = maxx - minx
        height = maxy - miny

        # Convex hull
        hull = poly.convex_hull
        hull_area = hull.area if hull.area > 0 else 1.0
        hull_coords = list(hull.exterior.coords) if hasattr(hull, 'exterior') else contour_points

        # Shape descriptors
        is_convex = abs(area - hull_area) < (hull_area * 0.02)  # within 2%
        aspect_ratio = round(width / height, 4) if height > 0 else 1.0
        solidity = round(area / hull_area, 4)
        compactness = round((4 * math.pi * area) / (perimeter ** 2), 4) if perimeter > 0 else 0.0

        # Orientation — fit an ellipse via OpenCV for major axis angle
        orientation_deg = 0.0
        if len(contour_points) >= 5:
            pts = np.array(contour_points, dtype=np.float32)
            try:
                (_, _), (_, _), angle = cv2.fitEllipse(pts)
                orientation_deg = round(float(angle), 2)
            except Exception:
                pass

        # Precise anchor points
        anchors = {
            "center":       [round(centroid.x, 2), round(centroid.y, 2)],
            "top_center":   [round(centroid.x, 2), round(miny, 2)],
            "bottom_center":[round(centroid.x, 2), round(maxy, 2)],
            "left_center":  [round(minx, 2), round(centroid.y, 2)],
            "right_center": [round(maxx, 2), round(centroid.y, 2)],
            "top_left":     [round(minx, 2), round(miny, 2)],
            "top_right":    [round(maxx, 2), round(miny, 2)],
            "bottom_left":  [round(minx, 2), round(maxy, 2)],
            "bottom_right": [round(maxx, 2), round(maxy, 2)],
        }

        # Normalized measurements (0.0–1.0 relative to image size)
        normalized = {
            "x":        round(minx / img_w, 6),
            "y":        round(miny / img_h, 6),
            "width":    round(width / img_w, 6),
            "height":   round(height / img_h, 6),
            "centroid_x": round(centroid.x / img_w, 6),
            "centroid_y": round(centroid.y / img_h, 6),
            "area":     round(area / (img_w * img_h), 6),
        }

        # SVG path string from the precise contour
        svg_path = _contour_to_svg(contour_points)

        # Flutter Path() code
        flutter_path = _contour_to_flutter_path(contour_points)

        return {
            "centroid": [round(centroid.x, 2), round(centroid.y, 2)],
            "area_px": round(area, 2),
            "perimeter_px": round(perimeter, 2),
            "bounding_box": {
                "x": round(minx, 2),
                "y": round(miny, 2),
                "width": round(width, 2),
                "height": round(height, 2),
            },
            "convex_hull": [[round(x, 2), round(y, 2)] for x, y in hull_coords],
            "is_convex": is_convex,
            "aspect_ratio": aspect_ratio,
            "solidity": solidity,
            "compactness": compactness,
            "orientation_deg": orientation_deg,
            "anchor_points": anchors,
            "normalized": normalized,
            "contour_points": contour_points,
            "contour_svg_path": svg_path,
            "contour_flutter_path": flutter_path,
            "shapely_available": True,
        }

    except Exception as e:
        return _geometry_fallback(mask_uint8, img_w, img_h)


def _geometry_fallback(mask_uint8: np.ndarray, img_w: int, img_h: int) -> dict:
    """Basic geometry when Shapely is not available — uses OpenCV only."""
    contours, _ = cv2.findContours(mask_uint8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return {}
    c = max(contours, key=cv2.contourArea)
    x, y, w, h = cv2.boundingRect(c)
    M = cv2.moments(c)
    cx = M["m10"] / M["m00"] if M["m00"] else x + w / 2
    cy = M["m01"] / M["m00"] if M["m00"] else y + h / 2
    area = float(cv2.contourArea(c))
    perimeter = float(cv2.arcLength(c, True))
    return {
        "centroid": [round(cx, 2), round(cy, 2)],
        "area_px": round(area, 2),
        "perimeter_px": round(perimeter, 2),
        "bounding_box": {"x": float(x), "y": float(y), "width": float(w), "height": float(h)},
        "aspect_ratio": round(w / h, 4) if h > 0 else 1.0,
        "solidity": None,
        "compactness": None,
        "orientation_deg": None,
        "anchor_points": {
            "center": [round(cx, 2), round(cy, 2)],
            "top_left": [float(x), float(y)],
            "bottom_right": [float(x + w), float(y + h)],
        },
        "normalized": {
            "x": round(x / img_w, 6),
            "y": round(y / img_h, 6),
            "width": round(w / img_w, 6),
            "height": round(h / img_h, 6),
        },
        "contour_points": [],
        "contour_svg_path": "",
        "contour_flutter_path": "",
        "shapely_available": False,
    }


def _contour_to_svg(points: list) -> str:
    """Convert contour point list to SVG path d-attribute string."""
    if not points:
        return ""
    parts = [f"M {points[0][0]} {points[0][1]}"]
    for x, y in points[1:]:
        parts.append(f"L {x} {y}")
    parts.append("Z")
    return " ".join(parts)


def _contour_to_flutter_path(points: list) -> str:
    """Convert contour point list to Flutter Path() code."""
    if not points:
        return ""
    lines = ["final path = Path();"]
    lines.append(f"path.moveTo({points[0][0]}.0, {points[0][1]}.0);")
    for x, y in points[1:]:
        lines.append(f"path.lineTo({x}.0, {y}.0);")
    lines.append("path.close();")
    return "\n".join(lines)


def compute_spatial_relationships(objects: list, img_w: int, img_h: int) -> list:
    """
    For every pair of objects, compute:
      - distance between centroids (pixels)
      - distance between nearest edges (pixels)
      - whether they overlap
      - relative position (above/below/left/right)

    Returns a list of relationship dicts.
    """
    if not SHAPELY_AVAILABLE:
        return []

    relationships = []
    polys = {}
    for obj in objects:
        pts = obj.get("geometry", {}).get("contour_points", [])
        if len(pts) >= 3:
            try:
                p = Polygon(pts)
                if not p.is_valid:
                    p = p.buffer(0)
                polys[obj["label"]] = p
            except Exception:
                pass

    labels = [obj["label"] for obj in objects]
    for i in range(len(labels)):
        for j in range(i + 1, len(labels)):
            a_lbl = labels[i]
            b_lbl = labels[j]
            a = objects[i]
            b = objects[j]

            a_cx, a_cy = a.get("geometry", {}).get("centroid", [0, 0])
            b_cx, b_cy = b.get("geometry", {}).get("centroid", [0, 0])

            centroid_dist = round(math.sqrt((a_cx - b_cx)**2 + (a_cy - b_cy)**2), 2)

            overlaps = False
            edge_dist = None
            if a_lbl in polys and b_lbl in polys:
                pa = polys[a_lbl]
                pb = polys[b_lbl]
                overlaps = pa.intersects(pb)
                if not overlaps:
                    edge_dist = round(pa.distance(pb), 2)

            # Relative position
            dx = b_cx - a_cx
            dy = b_cy - a_cy
            if abs(dx) > abs(dy):
                relative = "right_of" if dx > 0 else "left_of"
            else:
                relative = "below" if dy > 0 else "above"

            relationships.append({
                "object_a": a_lbl,
                "object_b": b_lbl,
                "centroid_distance_px": centroid_dist,
                "edge_distance_px": edge_dist,
                "overlaps": overlaps,
                "b_is": relative,
            })

    return relationships


# ---------------------------------------------------------------------------
# Spatial zone labeling
# ---------------------------------------------------------------------------

def label_zone(y: int, h_obj: int, img_h: int, x: int, w_obj: int, img_w: int) -> str:
    cy = (y + h_obj / 2) / img_h
    cx = (x + w_obj / 2) / img_w
    if cy < 0.25:
        return "ceiling"
    elif cy > 0.72:
        return "floor"
    elif cx < 0.2:
        return "left_wall"
    elif cx > 0.8:
        return "right_wall"
    elif 0.25 <= cy <= 0.55 and 0.2 <= cx <= 0.8:
        return "foreground"
    else:
        return "background"


# ---------------------------------------------------------------------------
# Sprite sheet builder
# ---------------------------------------------------------------------------

def build_sprite_sheet(cutouts: list, padding: int = 10) -> Image.Image:
    if not cutouts:
        return Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    cols = math.ceil(math.sqrt(len(cutouts)))
    rows = math.ceil(len(cutouts) / cols)
    max_w = max(c["width"] for c in cutouts)
    max_h = max(c["height"] for c in cutouts)
    cell_w = max_w + padding * 2
    cell_h = max_h + padding * 2
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (0, 0, 0, 0))
    for i, c in enumerate(cutouts):
        col = i % cols
        row = i // cols
        sheet.paste(c["pil"], (col * cell_w + padding, row * cell_h + padding), c["pil"])
    return sheet


# ---------------------------------------------------------------------------
# Flutter code generator — now includes geometry constants
# ---------------------------------------------------------------------------

def _pascal(s: str) -> str:
    return "".join(w.capitalize() for w in s.replace("-", "_").split("_"))


def generate_flutter_code(cutouts: list, base_name: str, img_w: int, img_h: int) -> dict:
    prefix = _pascal(base_name)
    files = {}

    for c in cutouts:
        lbl = c["label"]
        class_name = f"{prefix}Layer{lbl:03d}"
        zone = c["zone"]
        x, y, w, h = c["x"], c["y"], c["width"], c["height"]
        asset = f"assets/{base_name}_layer_{lbl:03d}.png"
        geo = c.get("geometry", {})
        centroid = geo.get("centroid", [x + w/2, y + h/2])
        anchors = geo.get("anchor_points", {})
        norm = geo.get("normalized", {})
        flutter_path_code = geo.get("contour_flutter_path", "")
        svg_path = geo.get("contour_svg_path", "")

        # Format anchor constants
        anchor_lines = "\n".join(
            f"  static const Offset anchor{k.title().replace('_','')} "
            f"= Offset({v[0]}, {v[1]});"
            for k, v in anchors.items()
        ) if anchors else ""

        # Indent the flutter path code
        path_indented = "\n".join(
            "    " + line for line in flutter_path_code.splitlines()
        ) if flutter_path_code else "    // contour unavailable"

        dart = f"""import 'package:flutter/material.dart';

/// Auto-generated widget — Layer {lbl}
/// Zone        : {zone}
/// Position    : x={x}, y={y}
/// Size        : {w}x{h} px
/// Centroid    : ({centroid[0]}, {centroid[1]})
/// Aspect ratio: {geo.get('aspect_ratio', 'n/a')}
/// Solidity    : {geo.get('solidity', 'n/a')}
/// Compactness : {geo.get('compactness', 'n/a')}
/// Orientation : {geo.get('orientation_deg', 'n/a')}°
/// SVG outline : {svg_path[:80]}{'...' if len(svg_path) > 80 else ''}
class {class_name} extends StatelessWidget {{
  const {class_name}({{super.key}});

  // ── Asset ──────────────────────────────────────────────
  static const String assetPath = '{asset}';

  // ── Source position in original image ──────────────────
  static const double srcX = {x}.0;
  static const double srcY = {y}.0;
  static const double srcWidth = {w}.0;
  static const double srcHeight = {h}.0;

  // ── Spatial zone ───────────────────────────────────────
  static const String zone = '{zone}';

  // ── Precision geometry ─────────────────────────────────
  static const Offset centroid = Offset({centroid[0]}, {centroid[1]});
  static const double areaPixels = {geo.get('area_px', 0.0)};
  static const double perimeterPixels = {geo.get('perimeter_px', 0.0)};
  static const double aspectRatio = {geo.get('aspect_ratio', 1.0)};
  static const double solidity = {geo.get('solidity') or 0.0};
  static const double compactness = {geo.get('compactness') or 0.0};
  static const double orientationDeg = {geo.get('orientation_deg') or 0.0};

  // ── Normalized coordinates (0.0–1.0) ───────────────────
  static const double normX = {norm.get('x', 0.0)};
  static const double normY = {norm.get('y', 0.0)};
  static const double normWidth = {norm.get('width', 0.0)};
  static const double normHeight = {norm.get('height', 0.0)};
  static const double normCentroidX = {norm.get('centroid_x', 0.0)};
  static const double normCentroidY = {norm.get('centroid_y', 0.0)};

  // ── Precision anchor points ─────────────────────────────
{anchor_lines}

  // ── Precise contour as Flutter Path ────────────────────
  static Path buildContourPath() {{
{path_indented}
    return path;
  }}

  @override
  Widget build(BuildContext context) {{
    return Image.asset(
      assetPath,
      width: srcWidth,
      height: srcHeight,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
  }}
}}
"""
        files[f"{class_name.lower()}.dart"] = dart

    # Composition widget
    import_lines = [
        f"import '{prefix}Layer{c['label']:03d}'.lower() + '.dart';"
        for c in cutouts
    ]
    import_lines = [
        f"import '{prefix.lower()}layer{c['label']:03d}.dart';"
        for c in cutouts
    ]
    positioned_lines = []
    for c in cutouts:
        lbl = c["label"]
        class_name = f"{prefix}Layer{lbl:03d}"
        geo = c.get("geometry", {})
        positioned_lines.append(
            f"          // Layer {lbl} — zone: {c['zone']} — "
            f"centroid: {geo.get('centroid', 'n/a')}\n"
            f"          Positioned(\n"
            f"            left: {c['x']}.0,\n"
            f"            top: {c['y']}.0,\n"
            f"            child: {class_name}(),\n"
            f"          ),"
        )

    composition = f"""import 'package:flutter/material.dart';
{chr(10).join(import_lines)}

/// Auto-generated composition — reconstructs full scene ({img_w}x{img_h}px)
/// {len(cutouts)} objects detected and separated with precision geometry
class {prefix}Composition extends StatelessWidget {{
  const {prefix}Composition({{super.key}});

  @override
  Widget build(BuildContext context) {{
    return SizedBox(
      width: {img_w}.0,
      height: {img_h}.0,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
{chr(10).join(positioned_lines)}
        ],
      ),
    );
  }}
}}
"""
    files[f"{prefix.lower()}_composition.dart"] = composition
    return files


# ---------------------------------------------------------------------------
# Main processing endpoint
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SVG outline writer
# ---------------------------------------------------------------------------

def save_object_svg(
    contour_points: list,
    img_w: int,
    img_h: int,
    output_path: str,
    stroke_color: str = "#2563EB",
    stroke_width: float = 2.0,
    fill: str = "none",
):
    """
    Write a precise SVG vector outline for a single object.
    Transparent background — only the contour stroke is visible.
    Like masking tape tracing the exact edge of the object.
    """
    if not contour_points:
        return
    parts = [f"M {contour_points[0][0]} {contour_points[0][1]}"]
    for x, y in contour_points[1:]:
        parts.append(f"L {x} {y}")
    parts.append("Z")
    d = " ".join(parts)
    svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg"
     width="{img_w}" height="{img_h}"
     viewBox="0 0 {img_w} {img_h}">
  <path d="{d}"
        fill="{fill}"
        stroke="{stroke_color}"
        stroke-width="{stroke_width}"
        stroke-linejoin="round"
        stroke-linecap="round"/>
</svg>"""
    with open(output_path, "w") as f:
        f.write(svg)


@app.post("/api/process")
async def process_image(
    file: UploadFile = File(...),
    confidence: float = Form(0.85),
    remove_background: bool = Form(False),
    group_small: bool = Form(False),
    detection_mode: str = Form("ai"),
):
    try:
        raw = await file.read()
        pil_orig = Image.open(io.BytesIO(raw)).convert("RGBA")
        img_w, img_h = pil_orig.size
        img_np = np.array(pil_orig)
        img_bgra = cv2.cvtColor(img_np, cv2.COLOR_RGBA2BGRA)
        img_rgb = cv2.cvtColor(img_np, cv2.COLOR_RGBA2RGB)

        base_name = Path(file.filename).stem.replace(" ", "_").lower() or "image"
        session_id = uuid.uuid4().hex[:8]
        session_dir = WORK_DIR / session_id
        session_dir.mkdir(exist_ok=True)
        assets_dir = session_dir / "assets"
        assets_dir.mkdir(exist_ok=True)

        # Segmentation
        masks = None
        method_used = "classical"

        if detection_mode == "ai":
            masks = try_sam(img_rgb, confidence)
            if masks:
                method_used = "SAM"

        if not masks:
            method_used = "classical"
            masks = classical_segment(
                img_bgra,
                min_area=int(500 * (1 - confidence + 0.5))
            )

        min_area_filter = 200 if group_small else 500
        cutouts = []

        for i, mask_data in enumerate(masks[:20]):
            seg = mask_data["segmentation"]
            seg_uint8 = seg.astype(np.uint8) * 255

            contours, _ = cv2.findContours(seg_uint8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if not contours:
                continue
            c = max(contours, key=cv2.contourArea)
            x, y, w, h = cv2.boundingRect(c)
            area = int(cv2.contourArea(c))
            if area < min_area_filter:
                continue

            # Cutout PNG
            cutout_full = np.zeros((img_h, img_w, 4), dtype=np.uint8)
            cutout_full[:, :, :3] = img_np[:, :, :3]
            cutout_full[:, :, 3] = seg_uint8
            crop = cutout_full[y:y+h, x:x+w]
            pil_crop = Image.fromarray(crop, mode="RGBA")

            if remove_background:
                cleaned = try_rembg(pil_crop)
                if cleaned is not None:
                    pil_crop = Image.fromarray(cleaned, mode="RGBA")

            lbl = i + 1
            fname = f"{base_name}_layer_{lbl:03d}.png"
            pil_crop.save(assets_dir / fname)

            # Thumbnail
            thumb = pil_crop.copy()
            thumb.thumbnail((120, 120))
            buf = io.BytesIO()
            thumb.save(buf, format="PNG")
            thumb_b64 = base64.b64encode(buf.getvalue()).decode()

            zone = label_zone(y, h, img_h, x, w, img_w)

            # ── PRECISION GEOMETRY ──────────────────────────────
            contour_points = extract_precise_contour(seg_uint8)
            geometry = compute_geometry(contour_points, seg_uint8, img_w, img_h)

            # ── SVG VECTOR OUTLINE ───────────────────────────────
            svg_fname = f"{base_name}_outline_{lbl:03d}.svg"
            save_object_svg(
                contour_points=contour_points,
                img_w=img_w,
                img_h=img_h,
                output_path=str(assets_dir / svg_fname),
            )

            cutouts.append({
                "label": lbl,
                "x": int(x), "y": int(y),
                "width": int(w), "height": int(h),
                "area": area,
                "zone": zone,
                "filename": fname,
                "asset_path": f"assets/{fname}",
                "thumbnail": f"data:image/png;base64,{thumb_b64}",
                "geometry": geometry,
                "pil": pil_crop,
            })

        if not cutouts:
            raise HTTPException(
                status_code=422,
                detail="No objects detected. Try lowering confidence or switching detection mode."
            )

        # Spatial relationships between all objects
        relationships = compute_spatial_relationships(cutouts, img_w, img_h)

        # Sprite sheet
        sheet = build_sprite_sheet(cutouts)
        sheet_path = session_dir / f"{base_name}_sprite_sheet.png"
        sheet.save(sheet_path)

        # Flutter code
        flutter_files = generate_flutter_code(cutouts, base_name, img_w, img_h)
        lib_dir = session_dir / "lib"
        lib_dir.mkdir(exist_ok=True)
        for fname, code in flutter_files.items():
            (lib_dir / fname).write_text(code)

        # Full metadata
        meta = {
            "session_id": session_id,
            "source_image": file.filename,
            "image_width": img_w,
            "image_height": img_h,
            "method": method_used,
            "shapely": SHAPELY_AVAILABLE,
            "num_objects": len(cutouts),
            "objects": [
                {k: v for k, v in c.items() if k not in ("pil",)}
                for c in cutouts
            ],
            "spatial_relationships": relationships,
        }
        (session_dir / "metadata.json").write_text(json.dumps(meta, indent=2))

        # ZIP
        zip_path = session_dir / f"{base_name}_flutter_export.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for f in assets_dir.iterdir():
                zf.write(f, f"assets/{f.name}")
            for f in lib_dir.iterdir():
                zf.write(f, f"lib/{f.name}")
            zf.write(session_dir / "metadata.json", "metadata.json")
            zf.write(sheet_path, f"{base_name}_sprite_sheet.png")

        # Code previews
        comp_key = next((k for k in flutter_files if k.endswith("_composition.dart")), None)
        layer_key = next((k for k in flutter_files if not k.endswith("_composition.dart")), None)

        return JSONResponse({
            "session_id": session_id,
            "method": method_used,
            "shapely": SHAPELY_AVAILABLE,
            "image_width": img_w,
            "image_height": img_h,
            "num_objects": len(cutouts),
            "objects": [
                {k: v for k, v in c.items() if k not in ("pil",)}
                for c in cutouts
            ],
            "spatial_relationships": relationships,
            "sprite_sheet_url": f"/static/{session_id}/{base_name}_sprite_sheet.png",
            "download_zip_url": f"/api/download/{session_id}/{base_name}_flutter_export.zip",
            "main_dart": flutter_files.get(comp_key, "") if comp_key else "",
            "layers_dart": flutter_files.get(layer_key, "") if layer_key else "",
            "all_dart_files": flutter_files,
        })

    except HTTPException:
        raise
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


# ---------------------------------------------------------------------------
# Download endpoint
# ---------------------------------------------------------------------------

@app.get("/api/download/{session_id}/{filename}")
async def download_file(session_id: str, filename: str):
    path = WORK_DIR / session_id / filename
    if not path.exists():
        raise HTTPException(404, "File not found")
    return FileResponse(str(path), filename=filename)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health():
    sam_available = (Path(__file__).parent / "sam_vit_b_01ec64.pth").exists()
    try:
        import rembg
        rembg_available = True
    except ImportError:
        rembg_available = False
    return {
        "status": "ok",
        "sam": sam_available,
        "rembg": rembg_available,
        "shapely": SHAPELY_AVAILABLE,
    }
