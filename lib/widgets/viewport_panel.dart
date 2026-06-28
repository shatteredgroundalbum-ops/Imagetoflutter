import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/app_models.dart';

class ViewportPanel extends StatefulWidget {
  final AppState state;
  final ValueChanged<int> onSelectLayer;

  const ViewportPanel({super.key, required this.state, required this.onSelectLayer});

  @override
  State<ViewportPanel> createState() => _ViewportPanelState();
}

class _ViewportPanelState extends State<ViewportPanel> {
  double _zoom = 1.0;
  bool _showOverlays = true;
  bool _showGrid = false;
  final TransformationController _tc = TransformationController();

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _toolbar(),
        Expanded(child: _canvas()),
        _thumbnailStrip(),
      ],
    );
  }

  // ── Toolbar ────────────────────────────────────────────
  Widget _toolbar() {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          const Text('Separated Layers Preview',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1F2937))),
          const SizedBox(width: 10),
          _ZBtn(label: 'Fit',  active: _zoom == 0,   onTap: () => _setZoom(0)),
          _ZBtn(label: '100%', active: _zoom == 1.0,  onTap: () => _setZoom(1.0)),
          _ZBtn(label: '200%', active: _zoom == 2.0,  onTap: () => _setZoom(2.0)),
          _ZBtn(label: '50%',  active: _zoom == 0.5,  onTap: () => _setZoom(0.5)),
          const SizedBox(width: 4),
          _IBtn(icon: Icons.refresh, tip: 'Reset', onTap: () {
            _tc.value = Matrix4.identity();
            setState(() => _zoom = 1.0);
          }),
          _IBtn(
            icon: Icons.select_all,
            tip: 'Overlays',
            active: _showOverlays,
            onTap: () => setState(() => _showOverlays = !_showOverlays),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() => _showGrid = !_showGrid),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _showGrid ? const Color(0xFFEFF6FF) : Colors.white,
                border: Border.all(color: const Color(0xFFE5E7EB)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.grid_on, size: 14,
                      color: _showGrid ? const Color(0xFF2563EB) : const Color(0xFF6B7280)),
                  const SizedBox(width: 4),
                  Text('Grid', style: TextStyle(
                      fontSize: 12,
                      color: _showGrid ? const Color(0xFF2563EB) : const Color(0xFF6B7280))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _setZoom(double z) {
    setState(() => _zoom = z);
    _tc.value = z == 0 ? Matrix4.identity() : (Matrix4.identity()..scale(z));
  }

  // ── Canvas ─────────────────────────────────────────────
  Widget _canvas() {
    return Container(
      color: const Color(0xFFE0E0E0),
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 0.1,
        maxScale: 8.0,
        child: Center(child: _canvasContent()),
      ),
    );
  }

  Widget _canvasContent() {
    final s = widget.state;
    if (s.imagePath == null) {
      return Container(
        width: 480, height: 320,
        color: const Color(0xFFD8D8D8),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image_outlined, size: 48, color: Color(0xFFAAAAAA)),
            SizedBox(height: 10),
            Text('Load an image to get started',
                style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
          ],
        ),
      );
    }

    return Stack(
      children: [
        CustomPaint(painter: _CheckerPainter(), child: Image.file(File(s.imagePath!))),
        if (_showGrid) Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        if (_showOverlays && s.result != null)
          Positioned.fill(
            child: LayoutBuilder(builder: (_, constraints) {
              final img = File(s.imagePath!);
              // Use image resolution from result for accurate scaling
              return CustomPaint(
                painter: _BBoxPainter(
                  objects: s.result!.objects,
                  selectedLabel: s.selectedLayer,
                  imageWidth: s.result!.imageWidth.toDouble(),
                  imageHeight: s.result!.imageHeight.toDouble(),
                ),
              );
            }),
          ),
        if (s.phase == AppPhase.processing) Positioned.fill(child: _processingOverlay()),
      ],
    );
  }

  Widget _processingOverlay() {
    return Container(
      color: Colors.white70,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF2563EB)),
          const SizedBox(height: 14),
          Text(_progressLabel(widget.state.progress),
              style: const TextStyle(fontSize: 13, color: Color(0xFF374151), fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          SizedBox(
            width: 200,
            child: LinearProgressIndicator(
              value: widget.state.progress,
              color: const Color(0xFF2563EB),
              backgroundColor: const Color(0xFFBFDBFE),
            ),
          ),
        ],
      ),
    );
  }

  String _progressLabel(double p) {
    if (p < 0.3) return 'Uploading image…';
    if (p < 0.6) return 'Running segmentation…';
    if (p < 0.85) return 'Computing geometry…';
    return 'Generating Flutter code…';
  }

  // ── Thumbnail strip ────────────────────────────────────
  Widget _thumbnailStrip() {
    final result = widget.state.result;
    return Container(
      height: 88,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Text('Layer Thumbnails',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                if (result != null)
                  ...result.objects.map((obj) => _ThumbCell(
                        obj: obj,
                        isActive: widget.state.selectedLayer == obj.label,
                        onTap: () => widget.onSelectLayer(obj.label),
                      )),
                _AddCell(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Thumb cell ─────────────────────────────────────────────
class _ThumbCell extends StatelessWidget {
  final DetectedObject obj;
  final bool isActive;
  final VoidCallback onTap;
  const _ThumbCell({required this.obj, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68, margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          border: Border.all(
              color: isActive ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB),
              width: isActive ? 2 : 1.5),
          borderRadius: BorderRadius.circular(6),
          color: const Color(0xFFF9FAFB),
        ),
        child: Stack(
          children: [
            if (obj.thumbnail.startsWith('data:'))
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Image.memory(
                  base64Decode(obj.thumbnail.split(',').last),
                  fit: BoxFit.contain, width: 68, height: 54,
                ),
              ),
            Positioned(
              top: 2, left: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
                child: Text('${obj.label}',
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddCell extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFD1D5DB)),
          borderRadius: BorderRadius.circular(6)),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add, size: 16, color: Color(0xFF9CA3AF)),
          Text('Add', style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
        ],
      ),
    );
  }
}

// ── Painters ───────────────────────────────────────────────
class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 14.0;
    final p1 = Paint()..color = const Color(0xFFCCCCCC);
    final p2 = Paint()..color = const Color(0xFFE4E4E4);
    for (double y = 0; y < size.height; y += cell)
      for (double x = 0; x < size.width; x += cell)
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell),
            (((x / cell).floor() + (y / cell).floor()) % 2 == 0) ? p1 : p2);
  }

  @override
  bool shouldRepaint(_) => false;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x33000000)..strokeWidth = 0.5;
    for (double x = 0; x < size.width; x += 40)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y < size.height; y += 40)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
  }

  @override
  bool shouldRepaint(_) => false;
}

class _BBoxPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final int? selectedLabel;
  final double imageWidth;
  final double imageHeight;

  const _BBoxPainter({
    required this.objects,
    required this.selectedLabel,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / imageWidth;
    final sy = size.height / imageHeight;

    for (final obj in objects) {
      final sel = obj.label == selectedLabel;
      final color = sel ? const Color(0xFFF59E0B) : const Color(0xFF2563EB);
      final rect = Rect.fromLTWH(obj.x * sx, obj.y * sy, obj.width * sx, obj.height * sy);

      canvas.drawRect(rect, Paint()..color = color.withOpacity(0.08));
      canvas.drawRect(rect, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = sel ? 2.5 : 1.5);

      final tp = TextPainter(
        text: TextSpan(
          text: '${obj.label} · ${obj.zone.replaceAll('_', ' ')}',
          style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(rect.left, rect.top - 18, tp.width + 10, 16), const Radius.circular(3)),
        Paint()..color = color,
      );
      tp.paint(canvas, Offset(rect.left + 5, rect.top - 17));

      if (sel && obj.geometry != null) {
        final pts = obj.geometry!.contourPoints;
        if (pts.length >= 3) {
          final path = Path()..moveTo(pts[0][0] * sx, pts[0][1] * sy);
          for (int i = 1; i < pts.length; i++) path.lineTo(pts[i][0] * sx, pts[i][1] * sy);
          path.close();
          canvas.drawPath(path, Paint()
            ..color = color.withOpacity(0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeJoin = StrokeJoin.round);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BBoxPainter o) => o.selectedLabel != selectedLabel || o.objects != objects;
}

// ── Toolbar micro widgets ──────────────────────────────────
class _ZBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ZBtn({required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2563EB) : Colors.white,
            border: Border.all(color: const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: TextStyle(fontSize: 12, color: active ? Colors.white : const Color(0xFF374151))),
        ),
      );
}

class _IBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final bool active;
  final VoidCallback onTap;
  const _IBtn({required this.icon, required this.tip, required this.onTap, this.active = false});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(right: 4),
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: active ? const Color(0xFFEFF6FF) : Colors.white,
              border: Border.all(color: active ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 14, color: const Color(0xFF6B7280)),
          ),
        ),
      );
}
