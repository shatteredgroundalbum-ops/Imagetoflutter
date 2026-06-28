class HealthStatus {
  final bool online, sam, rembg, shapely;
  HealthStatus({required this.online, required this.sam, required this.rembg, required this.shapely});
  String get engineLabel {
    if (!online) return 'Backend offline';
    if (sam) return 'SAM (AI) ready';
    if (rembg) return 'rembg ready';
    return 'Classical ready';
  }
}

class ObjectGeometry {
  final List<double> centroid;
  final double areaPx, perimeterPx;
  final double? aspectRatio, solidity, compactness, orientationDeg;
  final Map<String, List<double>> anchorPoints;
  final Map<String, double> normalized;
  final List<List<int>> contourPoints;
  final String svgPath, flutterPath;
  final bool shapleyAvailable;

  ObjectGeometry({required this.centroid, required this.areaPx, required this.perimeterPx,
    this.aspectRatio, this.solidity, this.compactness, this.orientationDeg,
    required this.anchorPoints, required this.normalized, required this.contourPoints,
    required this.svgPath, required this.flutterPath, required this.shapleyAvailable});

  factory ObjectGeometry.fromJson(Map<String, dynamic> j) {
    List<double> pair(dynamic v) => v is List ? v.map((e) => (e as num).toDouble()).toList() : [0.0, 0.0];
    return ObjectGeometry(
      centroid: pair(j['centroid']),
      areaPx: (j['area_px'] as num?)?.toDouble() ?? 0,
      perimeterPx: (j['perimeter_px'] as num?)?.toDouble() ?? 0,
      aspectRatio: (j['aspect_ratio'] as num?)?.toDouble(),
      solidity: (j['solidity'] as num?)?.toDouble(),
      compactness: (j['compactness'] as num?)?.toDouble(),
      orientationDeg: (j['orientation_deg'] as num?)?.toDouble(),
      anchorPoints: (j['anchor_points'] as Map?)?.map((k, v) => MapEntry(k.toString(), pair(v))) ?? {},
      normalized: (j['normalized'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())) ?? {},
      contourPoints: (j['contour_points'] as List?)?.map<List<int>>((pt) =>
        pt is List ? pt.map<int>((e) => (e as num).toInt()).toList() : [0,0]).toList() ?? [],
      svgPath: j['contour_svg_path'] as String? ?? '',
      flutterPath: j['contour_flutter_path'] as String? ?? '',
      shapleyAvailable: j['shapely_available'] as bool? ?? false,
    );
  }
}

class DetectedObject {
  final int label, x, y, width, height, area;
  final String zone, filename, assetPath, thumbnail;
  final ObjectGeometry? geometry;

  DetectedObject({required this.label, required this.x, required this.y,
    required this.width, required this.height, required this.area,
    required this.zone, required this.filename, required this.assetPath,
    required this.thumbnail, this.geometry});

  factory DetectedObject.fromJson(Map<String, dynamic> j) => DetectedObject(
    label: j['label'] as int, x: j['x'] as int, y: j['y'] as int,
    width: j['width'] as int, height: j['height'] as int, area: j['area'] as int,
    zone: j['zone'] as String? ?? 'unknown', filename: j['filename'] as String? ?? '',
    assetPath: j['asset_path'] as String? ?? '', thumbnail: j['thumbnail'] as String? ?? '',
    geometry: j['geometry'] != null ? ObjectGeometry.fromJson(j['geometry'] as Map<String, dynamic>) : null,
  );
}

class SpatialRelationship {
  final int objectA, objectB;
  final double centroidDistancePx;
  final double? edgeDistancePx;
  final bool overlaps;
  final String bIs;

  SpatialRelationship({required this.objectA, required this.objectB,
    required this.centroidDistancePx, this.edgeDistancePx,
    required this.overlaps, required this.bIs});

  factory SpatialRelationship.fromJson(Map<String, dynamic> j) => SpatialRelationship(
    objectA: j['object_a'] as int, objectB: j['object_b'] as int,
    centroidDistancePx: (j['centroid_distance_px'] as num).toDouble(),
    edgeDistancePx: (j['edge_distance_px'] as num?)?.toDouble(),
    overlaps: j['overlaps'] as bool? ?? false, bIs: j['b_is'] as String? ?? '',
  );
}

class ProcessResult {
  final String sessionId, method, mainDart, layersDart, downloadZipUrl, spriteSheetUrl;
  final bool shapely;
  final int imageWidth, imageHeight, numObjects;
  final List<DetectedObject> objects;
  final List<SpatialRelationship> relationships;
  final Map<String, String> allDartFiles;

  ProcessResult({required this.sessionId, required this.method, required this.shapely,
    required this.imageWidth, required this.imageHeight, required this.numObjects,
    required this.objects, required this.relationships, required this.spriteSheetUrl,
    required this.downloadZipUrl, required this.mainDart, required this.layersDart,
    required this.allDartFiles});

  factory ProcessResult.fromJson(Map<String, dynamic> j, String base) => ProcessResult(
    sessionId: j['session_id'] as String, method: j['method'] as String? ?? '',
    shapely: j['shapely'] as bool? ?? false,
    imageWidth: j['image_width'] as int, imageHeight: j['image_height'] as int,
    numObjects: j['num_objects'] as int,
    objects: (j['objects'] as List).map((o) => DetectedObject.fromJson(o as Map<String, dynamic>)).toList(),
    relationships: (j['spatial_relationships'] as List? ?? []).map((r) => SpatialRelationship.fromJson(r as Map<String, dynamic>)).toList(),
    spriteSheetUrl: '$base${j['sprite_sheet_url']}',
    downloadZipUrl: j['download_zip_url'] as String,
    mainDart: j['main_dart'] as String? ?? '',
    layersDart: j['layers_dart'] as String? ?? '',
    allDartFiles: (j['all_dart_files'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString())),
  );
}

enum AppPhase { idle, processing, done, error }

class AppState {
  final AppPhase phase;
  final String? imagePath, errorMessage, activeCodeTab;
  final ProcessResult? result;
  final HealthStatus? health;
  final double progress;
  final int? selectedLayer;

  const AppState({this.phase = AppPhase.idle, this.imagePath, this.result,
    this.health, this.errorMessage, this.progress = 0,
    this.selectedLayer, this.activeCodeTab = 'main'});

  AppState copyWith({AppPhase? phase, String? imagePath, ProcessResult? result,
    HealthStatus? health, String? errorMessage, double? progress,
    int? selectedLayer, String? activeCodeTab}) => AppState(
    phase: phase ?? this.phase, imagePath: imagePath ?? this.imagePath,
    result: result ?? this.result, health: health ?? this.health,
    errorMessage: errorMessage ?? this.errorMessage, progress: progress ?? this.progress,
    selectedLayer: selectedLayer ?? this.selectedLayer, activeCodeTab: activeCodeTab ?? this.activeCodeTab,
  );
}
