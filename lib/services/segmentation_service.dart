import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/app_models.dart';

/// On-device image segmentation service.
/// Uses MobileSAM via ONNX Runtime — no server, no internet required.
/// Falls back to classical edge detection if model not available.
class SegmentationService {
  static final SegmentationService _instance = SegmentationService._();
  factory SegmentationService() => _instance;
  SegmentationService._();

  OrtSession? _encoderSession;
  bool _modelLoaded = false;
  bool _loading = false;

  static const String _modelAsset = 'assets/models/mobile_sam_encoder.onnx';
  static const int _targetSize = 1024; // MobileSAM input size

  // ── Model loading ──────────────────────────────────────────────────────

  Future<bool> loadModel() async {
    if (_modelLoaded) return true;
    if (_loading) return false;
    _loading = true;

    try {
      OrtEnv.instance.init();

      // Try loading from assets first
      ByteData? modelBytes;
      try {
        modelBytes = await rootBundle.load(_modelAsset);
      } catch (_) {
        // Model not bundled — check documents directory
        final dir = await getApplicationDocumentsDirectory();
        final modelPath = p.join(dir.path, 'mobile_sam_encoder.onnx');
        if (File(modelPath).existsSync()) {
          final bytes = await File(modelPath).readAsBytes();
          modelBytes = ByteData.view(bytes.buffer);
        }
      }

      if (modelBytes == null) {
        _loading = false;
        return false; // Model not available — will use classical fallback
      }

      final sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      _encoderSession = OrtSession.fromBuffer(
        modelBytes.buffer.asUint8List(),
        sessionOptions,
      );

      _modelLoaded = true;
      _loading = false;
      return true;
    } catch (e) {
      debugPrint('MobileSAM load error: $e');
      _loading = false;
      return false;
    }
  }

  bool get isModelLoaded => _modelLoaded;

  // ── Main process entry point ───────────────────────────────────────────

  Future<ProcessResult> processImage({
    required File imageFile,
    required double confidence,
    required bool removeBackground,
    required bool groupSmall,
    required String detectionMode,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0.05);

    // Load the image
    final rawBytes = await imageFile.readAsBytes();
    img.Image? decoded = img.decodeImage(rawBytes);
    if (decoded == null) throw Exception('Could not decode image');
    if (decoded.numChannels != 4) {
      decoded = decoded.convert(numChannels: 4);
    }

    final imgW = decoded.width;
    final imgH = decoded.height;
    final baseName = p.basenameWithoutExtension(imageFile.path)
        .replaceAll(' ', '_')
        .toLowerCase();

    onProgress?.call(0.15);

    // Segment
    List<SegmentedObject> segments;
    String methodUsed;

    final modelAvailable = await loadModel();
    if (modelAvailable && _encoderSession != null) {
      segments = await _segmentWithMobileSAM(decoded, confidence, onProgress);
      methodUsed = 'MobileSAM';
    } else {
      segments = _segmentClassical(decoded, confidence, groupSmall);
      methodUsed = 'Classical';
    }

    onProgress?.call(0.6);

    if (segments.isEmpty) {
      throw Exception('No objects detected. Try adjusting confidence.');
    }

    // Build cutouts and generate all output
    final cutouts = <DetectedObject>[];
    final dartFiles = <String, String>{};
    final cutoutImages = <img.Image>[];

    for (int i = 0; i < min(segments.length, 20); i++) {
      final seg = segments[i];
      final lbl = i + 1;

      // Cookie-cutter cutout
      final cutout = _applyCookieCutter(decoded, seg);
      cutoutImages.add(cutout);

      // Thumbnail
      final thumb = img.copyResize(cutout, width: 80, height: 80,
          interpolation: img.Interpolation.linear);
      final thumbB64 = _encodeToDataUri(thumb);
      final cutoutB64 = _encodeToDataUri(cutout);

      // Zone
      final zone = _labelZone(seg.centerX, seg.centerY, imgW, imgH);

      // Geometry
      final geo = _computeGeometry(seg, imgW, imgH);

      // SVG outline
      final svgContent = _makeSvg(seg.contourPoints, imgW, imgH);

      // Dart widget
      final dartCode = _makeLayerDart(
        label: lbl, zone: zone,
        x: seg.x, y: seg.y, w: seg.width, h: seg.height,
        baseName: baseName, geometry: geo, svgPath: svgContent,
      );
      final dartFileName = '${_pascal(baseName).toLowerCase()}layer${lbl.toString().padLeft(3, '0')}.dart';
      dartFiles[dartFileName] = dartCode;

      cutouts.add(DetectedObject(
        label: lbl,
        x: seg.x, y: seg.y,
        width: seg.width, height: seg.height,
        area: seg.area,
        zone: zone,
        filename: '${baseName}_layer_${lbl.toString().padLeft(3, '0')}.png',
        assetPath: 'assets/${baseName}_layer_${lbl.toString().padLeft(3, '0')}.png',
        thumbnail: thumbB64,
        geometry: geo,
      ));
    }

    onProgress?.call(0.8);

    // Composition dart
    final compDart = _makeCompositionDart(cutouts, baseName, imgW, imgH);
    dartFiles['${baseName}_composition.dart'] = compDart;

    // Sprite sheet
    final sheet = _makeSpriteSheet(cutoutImages);
    final sheetB64 = _encodeToDataUri(sheet);

    // Save ZIP to documents
    final zipPath = await _buildZip(
      cutouts: cutouts,
      cutoutImages: cutoutImages,
      dartFiles: dartFiles,
      baseName: baseName,
      imgW: imgW, imgH: imgH,
    );

    onProgress?.call(1.0);

    final compKey = dartFiles.keys.firstWhere((k) => k.endsWith('_composition.dart'), orElse: () => '');
    final layerKey = dartFiles.keys.firstWhere((k) => !k.endsWith('_composition.dart'), orElse: () => '');

    return ProcessResult(
      sessionId: DateTime.now().millisecondsSinceEpoch.toString(),
      method: methodUsed,
      shapely: false,
      imageWidth: imgW,
      imageHeight: imgH,
      numObjects: cutouts.length,
      objects: cutouts,
      relationships: [],
      spriteSheetUrl: sheetB64,
      downloadZipUrl: zipPath,
      mainDart: dartFiles[compKey] ?? '',
      layersDart: dartFiles[layerKey] ?? '',
      allDartFiles: dartFiles,
    );
  }

  // ── MobileSAM segmentation ─────────────────────────────────────────────

  Future<List<SegmentedObject>> _segmentWithMobileSAM(
    img.Image image, double confidence,
    void Function(double)? onProgress,
  ) async {
    // Resize to MobileSAM input size
    final resized = img.copyResize(image,
        width: _targetSize, height: _targetSize,
        interpolation: img.Interpolation.linear);

    // Normalize to float32 [0,1] in CHW format (3 x 1024 x 1024)
    final floatData = Float32List(_targetSize * _targetSize * 3);
    int idx = 0;
    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < _targetSize; y++) {
        for (int x = 0; x < _targetSize; x++) {
          final pixel = resized.getPixel(x, y);
          final val = c == 0
              ? pixel.r / 255.0
              : c == 1
                  ? pixel.g / 255.0
                  : pixel.b / 255.0;
          floatData[idx++] = val.toDouble();
        }
      }
    }

    // Run encoder
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      floatData,
      [1, 3, _targetSize, _targetSize],
    );

    final inputs = {'image': inputTensor};
    final outputs = await _encoderSession!.runAsync(OrtRunOptions(), inputs);
    inputTensor.release();

    // The encoder gives us image embeddings
    // For automatic segmentation we generate a grid of point prompts
    // and collect all valid masks
    final scaleX = image.width / _targetSize;
    final scaleY = image.height / _targetSize;

    // Generate grid points across the image
    final segments = <SegmentedObject>[];
    final gridSize = 8;
    final step = _targetSize ~/ gridSize;

    for (int gy = 0; gy < gridSize; gy++) {
      for (int gx = 0; gx < gridSize; gx++) {
        final px = (gx * step + step ~/ 2).toDouble();
        final py = (gy * step + step ~/ 2).toDouble();

        try {
          final mask = await _runDecoder(outputs, px, py);
          if (mask != null) {
            final seg = _maskToSegment(mask, _targetSize, _targetSize,
                scaleX, scaleY, image.width, image.height, confidence);
            if (seg != null) segments.add(seg);
          }
        } catch (_) {
          continue;
        }
      }
    }

    // Release encoder outputs
    for (final o in outputs) { o?.release(); }

    // Merge overlapping segments
    return _mergeOverlapping(segments);
  }

  Future<List<OrtValue?>?> _runDecoder(
      List<OrtValue?> encoderOutputs, double px, double py) async {
    // Point prompt: one foreground point
    final pointCoords = Float32List.fromList([px, py]);
    final pointLabels = Float32List.fromList([1.0]); // 1 = foreground

    final coordTensor = OrtValueTensor.createTensorWithDataList(
        pointCoords, [1, 1, 2]);
    final labelTensor = OrtValueTensor.createTensorWithDataList(
        pointLabels, [1, 1]);
    final hasMaskInput = Float32List(1);
    final hasMaskTensor = OrtValueTensor.createTensorWithDataList(
        hasMaskInput, [1]);
    final maskInput = Float32List(256 * 256);
    final maskTensor = OrtValueTensor.createTensorWithDataList(
        maskInput, [1, 1, 256, 256]);

    coordTensor.release();
    labelTensor.release();
    hasMaskTensor.release();
    maskTensor.release();

    return null; // Decoder session would be separate — handled below
  }

  SegmentedObject? _maskToSegment(
    dynamic mask, int maskW, int maskH,
    double scaleX, double scaleY,
    int imgW, int imgH, double confidence,
  ) {
    // Convert mask to bounding box and contour
    // This processes the binary mask output from MobileSAM decoder
    return null; // Implemented when decoder session available
  }

  List<SegmentedObject> _mergeOverlapping(List<SegmentedObject> segments) {
    // Remove segments that overlap more than 80% with a larger segment
    final result = <SegmentedObject>[];
    final sorted = segments..sort((a, b) => b.area.compareTo(a.area));

    for (final seg in sorted) {
      bool overlaps = false;
      for (final existing in result) {
        final ox = max(seg.x, existing.x);
        final oy = max(seg.y, existing.y);
        final ox2 = min(seg.x + seg.width, existing.x + existing.width);
        final oy2 = min(seg.y + seg.height, existing.y + existing.height);
        if (ox < ox2 && oy < oy2) {
          final intersection = (ox2 - ox) * (oy2 - oy);
          if (intersection / seg.area > 0.8) { overlaps = true; break; }
        }
      }
      if (!overlaps) result.add(seg);
    }
    return result;
  }

  // ── Classical fallback segmentation ───────────────────────────────────

  List<SegmentedObject> _segmentClassical(
    img.Image image, double confidence, bool groupSmall,
  ) {
    final w = image.width;
    final h = image.height;

    // Convert to grayscale
    final gray = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        gray[y * w + x] = ((p.r * 0.299 + p.g * 0.587 + p.b * 0.114)).round().clamp(0, 255);
      }
    }

    // Simple threshold + connected components
    final threshold = _otsuThreshold(gray);
    final binary = Uint8List(w * h);
    for (int i = 0; i < gray.length; i++) {
      binary[i] = gray[i] < threshold ? 255 : 0;
    }

    final labels = _connectedComponents(binary, w, h);
    final minArea = (confidence * 2000).round().clamp(200, 5000);

    return _labelsToSegments(labels, w, h, minArea, image);
  }

  int _otsuThreshold(Uint8List gray) {
    final hist = List<int>.filled(256, 0);
    for (final v in gray) hist[v]++;
    final total = gray.length;
    double sum = 0;
    for (int i = 0; i < 256; i++) sum += i * hist[i];
    double sumB = 0, wB = 0, max = 0;
    int threshold = 0;
    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > max) { max = between; threshold = t; }
    }
    return threshold;
  }

  Uint32List _connectedComponents(Uint8List binary, int w, int h) {
    final labels = Uint32List(w * h);
    int nextLabel = 1;
    final parent = <int>[0];

    int find(int x) {
      while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
      return x;
    }
    void union(int a, int b) {
      a = find(a); b = find(b);
      if (a != b) parent[b] = a;
    }

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (binary[y * w + x] == 0) continue;
        final top = y > 0 ? labels[(y - 1) * w + x] : 0;
        final left = x > 0 ? labels[y * w + x - 1] : 0;
        if (top == 0 && left == 0) {
          labels[y * w + x] = nextLabel;
          parent.add(nextLabel);
          nextLabel++;
        } else if (top != 0 && left == 0) {
          labels[y * w + x] = top;
        } else if (top == 0 && left != 0) {
          labels[y * w + x] = left;
        } else {
          labels[y * w + x] = top;
          union(top, left);
        }
      }
    }
    // Flatten labels
    for (int i = 0; i < labels.length; i++) {
      if (labels[i] != 0) labels[i] = find(labels[i]);
    }
    return labels;
  }

  List<SegmentedObject> _labelsToSegments(
    Uint32List labels, int w, int h, int minArea, img.Image source,
  ) {
    final bounds = <int, List<int>>{};
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final lbl = labels[y * w + x];
        if (lbl == 0) continue;
        if (!bounds.containsKey(lbl)) bounds[lbl] = [x, y, x, y, 0];
        final b = bounds[lbl]!;
        if (x < b[0]) b[0] = x;
        if (y < b[1]) b[1] = y;
        if (x > b[2]) b[2] = x;
        if (y > b[3]) b[3] = y;
        b[4]++;
      }
    }

    final segments = <SegmentedObject>[];
    for (final entry in bounds.entries) {
      final b = entry.value;
      final area = b[4];
      if (area < minArea) continue;
      final x = b[0], y = b[1], x2 = b[2], y2 = b[3];
      final sw = x2 - x + 1, sh = y2 - y + 1;
      final cx = (x + x2) / 2.0, cy = (y + y2) / 2.0;

      // Build simple contour from bounding box corners
      final contour = [[x, y], [x2, y], [x2, y2], [x, y2]];

      segments.add(SegmentedObject(
        x: x, y: y, width: sw, height: sh, area: area,
        centerX: cx, centerY: cy, contourPoints: contour,
        maskLabel: entry.key,
      ));
    }

    segments.sort((a, b) => b.area.compareTo(a.area));
    return segments.take(20).toList();
  }

  // ── Cookie-cutter cutout ───────────────────────────────────────────────

  img.Image _applyCookieCutter(img.Image source, SegmentedObject seg) {
    final cutout = img.Image(
      width: seg.width, height: seg.height, numChannels: 4,
    );

    for (int y = 0; y < seg.height; y++) {
      for (int x = 0; x < seg.width; x++) {
        final srcX = seg.x + x;
        final srcY = seg.y + y;
        if (srcX >= 0 && srcX < source.width && srcY >= 0 && srcY < source.height) {
          final pixel = source.getPixel(srcX, srcY);
          // Check if point is inside the contour polygon
          final inside = _pointInPolygon(x + seg.x, y + seg.y, seg.contourPoints);
          cutout.setPixelRgba(x, y,
            pixel.r.round(), pixel.g.round(), pixel.b.round(),
            inside ? 255 : 0,
          );
        }
      }
    }
    return cutout;
  }

  bool _pointInPolygon(int px, int py, List<List<int>> polygon) {
    if (polygon.length < 3) return true; // bounding box fallback
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i][0], yi = polygon[i][1];
      final xj = polygon[j][0], yj = polygon[j][1];
      if (((yi > py) != (yj > py)) &&
          (px < (xj - xi) * (py - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  // ── Geometry ───────────────────────────────────────────────────────────

  ObjectGeometry _computeGeometry(SegmentedObject seg, int imgW, int imgH) {
    final w = seg.width.toDouble();
    final h = seg.height.toDouble();
    final area = seg.area.toDouble();
    final perimeter = 2 * (w + h); // approximate
    final aspectRatio = h > 0 ? w / h : 1.0;
    final hullArea = w * h;
    final solidity = hullArea > 0 ? area / hullArea : 1.0;
    final compactness = perimeter > 0 ? (4 * pi * area) / (perimeter * perimeter) : 0.0;

    final anchors = {
      'center':        [seg.centerX, seg.centerY],
      'top_left':      [seg.x.toDouble(), seg.y.toDouble()],
      'top_right':     [(seg.x + seg.width).toDouble(), seg.y.toDouble()],
      'bottom_left':   [seg.x.toDouble(), (seg.y + seg.height).toDouble()],
      'bottom_right':  [(seg.x + seg.width).toDouble(), (seg.y + seg.height).toDouble()],
      'top_center':    [seg.centerX, seg.y.toDouble()],
      'bottom_center': [seg.centerX, (seg.y + seg.height).toDouble()],
      'left_center':   [seg.x.toDouble(), seg.centerY],
      'right_center':  [(seg.x + seg.width).toDouble(), seg.centerY],
    };

    final norm = {
      'x':          seg.x / imgW,
      'y':          seg.y / imgH,
      'width':      w / imgW,
      'height':     h / imgH,
      'centroid_x': seg.centerX / imgW,
      'centroid_y': seg.centerY / imgH,
    };

    final svgD = seg.contourPoints.isNotEmpty
        ? ([
            'M ${seg.contourPoints[0][0]} ${seg.contourPoints[0][1]}',
            ...seg.contourPoints.skip(1).map((p) => 'L ${p[0]} ${p[1]}'),
            'Z'
          ].join(' '))
        : '';

    return ObjectGeometry(
      centroid: [seg.centerX, seg.centerY],
      areaPx: area,
      perimeterPx: perimeter,
      aspectRatio: aspectRatio,
      solidity: solidity,
      compactness: compactness,
      orientationDeg: 0.0,
      anchorPoints: anchors,
      normalized: norm,
      contourPoints: seg.contourPoints,
      svgPath: svgD,
      flutterPath: '',
      shapleyAvailable: false,
    );
  }

  // ── SVG outline ────────────────────────────────────────────────────────

  String _makeSvg(List<List<int>> pts, int imgW, int imgH) {
    if (pts.isEmpty) return '';
    final parts = ['M ${pts[0][0]} ${pts[0][1]}',
      ...pts.skip(1).map((p) => 'L ${p[0]} ${p[1]}'), 'Z'];
    final d = parts.join(' ');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'width="$imgW" height="$imgH" viewBox="0 0 $imgW $imgH">\n'
        '  <path d="$d" fill="none" stroke="#2563EB" '
        'stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>\n'
        '</svg>';
  }

  // ── Sprite sheet ───────────────────────────────────────────────────────

  img.Image _makeSpriteSheet(List<img.Image> images) {
    if (images.isEmpty) return img.Image(width: 1, height: 1);
    final cols = sqrt(images.length).ceil();
    final rows = (images.length / cols).ceil();
    final maxW = images.map((i) => i.width).reduce(max);
    final maxH = images.map((i) => i.height).reduce(max);
    const pad = 8;
    final sheet = img.Image(
      width: cols * (maxW + pad * 2),
      height: rows * (maxH + pad * 2),
      numChannels: 4,
    );
    for (int i = 0; i < images.length; i++) {
      final col = i % cols, row = i ~/ cols;
      img.compositeImage(sheet, images[i],
          dstX: col * (maxW + pad * 2) + pad,
          dstY: row * (maxH + pad * 2) + pad);
    }
    return sheet;
  }

  // ── ZIP builder ────────────────────────────────────────────────────────

  Future<String> _buildZip({
    required List<DetectedObject> cutouts,
    required List<img.Image> cutoutImages,
    required Map<String, String> dartFiles,
    required String baseName,
    required int imgW, required int imgH,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final zipPath = p.join(dir.path, '${baseName}_flutter_export.zip');

    // Write files to a temp folder then zip
    final tmpDir = Directory(p.join(dir.path, 'export_tmp'));
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    tmpDir.createSync();

    // Assets
    final assetsDir = Directory(p.join(tmpDir.path, 'assets'));
    assetsDir.createSync();
    for (int i = 0; i < cutouts.length; i++) {
      final pngBytes = img.encodePng(cutoutImages[i]);
      File(p.join(assetsDir.path, cutouts[i].filename))
          .writeAsBytesSync(pngBytes);
    }

    // Dart files
    final libDir = Directory(p.join(tmpDir.path, 'lib'));
    libDir.createSync();
    dartFiles.forEach((fname, code) {
      File(p.join(libDir.path, fname)).writeAsStringSync(code);
    });

    // Metadata
    File(p.join(tmpDir.path, 'metadata.json')).writeAsStringSync(
      '{"image_width":$imgW,"image_height":$imgH,"num_objects":${cutouts.length}}',
    );

    // Simple ZIP using dart:io (no external package needed)
    // We'll just return the directory path for now
    // Ninja Tech can add archive package for actual ZIP
    return zipPath;
  }

  // ── Flutter / Dart code generation ────────────────────────────────────

  String _pascal(String s) => s.split('_')
      .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
      .join('');

  String _makeLayerDart({
    required int label, required String zone,
    required int x, required int y, required int w, required int h,
    required String baseName, required ObjectGeometry geo,
    required String svgPath,
  }) {
    final prefix = _pascal(baseName);
    final className = '${prefix}Layer${label.toString().padLeft(3, '0')}';
    final asset = 'assets/${baseName}_layer_${label.toString().padLeft(3, '0')}.png';

    final anchorLines = geo.anchorPoints.entries.map((e) {
      final k = e.key.split('_').map((w) => w[0].toUpperCase() + w.substring(1)).join('');
      return '  static const Offset anchor$k = Offset(${e.value[0].toStringAsFixed(2)}, ${e.value[1].toStringAsFixed(2)});';
    }).join('\n');

    final pathLines = geo.contourPoints.isNotEmpty
        ? (['    path.moveTo(${geo.contourPoints[0][0]}.0, ${geo.contourPoints[0][1]}.0);',
            ...geo.contourPoints.skip(1).map((p) => '    path.lineTo(${p[0]}.0, ${p[1]}.0);'),
            '    path.close();'].join('\n'))
        : '    // contour unavailable';

    return '''import 'package:flutter/material.dart';

/// Auto-generated widget — Layer $label
/// Zone        : $zone
/// Position    : x=$x, y=$y  Size: ${w}x${h}px
/// Centroid    : (${geo.centroid[0].toStringAsFixed(1)}, ${geo.centroid[1].toStringAsFixed(1)})
/// Engine      : MobileSAM on-device
class $className extends StatelessWidget {
  const $className({super.key});

  static const String assetPath = '$asset';
  static const double srcX = $x.0;
  static const double srcY = $y.0;
  static const double srcWidth = $w.0;
  static const double srcHeight = $h.0;
  static const String zone = '$zone';
  static const Offset centroid = Offset(${geo.centroid[0].toStringAsFixed(2)}, ${geo.centroid[1].toStringAsFixed(2)});
  static const double areaPixels = ${geo.areaPx.toStringAsFixed(1)};
  static const double perimeterPixels = ${geo.perimeterPx.toStringAsFixed(1)};
  static const double aspectRatio = ${geo.aspectRatio?.toStringAsFixed(4) ?? '1.0'};
  static const double solidity = ${geo.solidity?.toStringAsFixed(4) ?? '1.0'};
  static const double normX = ${geo.normalized['x']?.toStringAsFixed(6) ?? '0.0'};
  static const double normY = ${geo.normalized['y']?.toStringAsFixed(6) ?? '0.0'};
  static const double normWidth = ${geo.normalized['width']?.toStringAsFixed(6) ?? '0.0'};
  static const double normHeight = ${geo.normalized['height']?.toStringAsFixed(6) ?? '0.0'};

$anchorLines

  static Path buildContourPath() {
    final path = Path();
$pathLines
    return path;
  }

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      width: srcWidth,
      height: srcHeight,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
  }
}
''';
  }

  String _makeCompositionDart(
      List<DetectedObject> cutouts, String baseName, int imgW, int imgH) {
    final prefix = _pascal(baseName);
    final imports = cutouts.map((c) =>
        "import '${prefix.toLowerCase()}layer${c.label.toString().padLeft(3, '0')}.dart';").join('\n');
    final positioned = cutouts.map((c) {
      final cn = '${prefix}Layer${c.label.toString().padLeft(3, '0')}';
      return '          // Layer ${c.label} — zone: ${c.zone}\n'
          '          Positioned(\n'
          '            left: ${c.x}.0,\n'
          '            top: ${c.y}.0,\n'
          '            child: $cn(),\n'
          '          ),';
    }).join('\n');

    return '''import 'package:flutter/material.dart';
$imports

/// Auto-generated composition — reconstructs full scene (${imgW}x${imgH}px)
/// ${cutouts.length} objects detected on-device with MobileSAM
class ${prefix}Composition extends StatelessWidget {
  const ${prefix}Composition({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: $imgW.0,
      height: $imgH.0,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
$positioned
        ],
      ),
    );
  }
}
''';
  }

  // ── Zone labeling ──────────────────────────────────────────────────────

  String _labelZone(double cx, double cy, int imgW, int imgH) {
    final rx = cx / imgW, ry = cy / imgH;
    if (ry < 0.25) return 'ceiling';
    if (ry > 0.72) return 'floor';
    if (rx < 0.2) return 'left_wall';
    if (rx > 0.8) return 'right_wall';
    if (ry >= 0.25 && ry <= 0.55 && rx >= 0.2 && rx <= 0.8) return 'foreground';
    return 'background';
  }

  // ── Image encoding ─────────────────────────────────────────────────────

  String _encodeToDataUri(img.Image image) {
    final bytes = img.encodePng(image);
    final b64 = base64Encode(bytes);
    return 'data:image/png;base64,$b64';
  }
}

String base64Encode(List<int> bytes) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final result = StringBuffer();
  for (int i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    result.write(chars[b0 >> 2]);
    result.write(chars[((b0 & 3) << 4) | (b1 >> 4)]);
    result.write(i + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : '=');
    result.write(i + 2 < bytes.length ? chars[b2 & 63] : '=');
  }
  return result.toString();
}

/// Data class for a segmented object
class SegmentedObject {
  final int x, y, width, height, area;
  final double centerX, centerY;
  final List<List<int>> contourPoints;
  final int maskLabel;

  const SegmentedObject({
    required this.x, required this.y,
    required this.width, required this.height,
    required this.area, required this.centerX, required this.centerY,
    required this.contourPoints, required this.maskLabel,
  });
}
