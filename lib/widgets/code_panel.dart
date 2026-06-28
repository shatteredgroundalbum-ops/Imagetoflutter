import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/app_models.dart';
import 'zone_badge.dart';

class CodePanel extends StatelessWidget {
  final AppState state;
  final ValueChanged<String> onTabChanged;

  const CodePanel({super.key, required this.state, required this.onTabChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        children: [
          _header(context),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB)))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              children: [
                const Text('Flutter Code',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                const Spacer(),
                _CopyBtn(label: 'Copy', onTap: () => _copyActive(context)),
              ],
            ),
          ),
          Row(
            children: [
              _Tab(id: 'main',   label: 'main.dart',  active: state.activeCodeTab, onTap: onTabChanged),
              _Tab(id: 'layers', label: 'layers.dart', active: state.activeCodeTab, onTap: onTabChanged),
              _Tab(id: 'meta',   label: 'metadata',    active: state.activeCodeTab, onTap: onTabChanged),
              _Tab(id: 'svg',    label: 'SVG',         active: state.activeCodeTab, onTap: onTabChanged),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (state.activeCodeTab) {
      case 'main':
        return _CodeView(code: state.result?.mainDart ?? '// Flutter code will appear here after separation');
      case 'layers':
        return _CodeView(code: state.result?.layersDart ?? '// Layer widget code will appear here');
      case 'meta':
        return _MetaView(state: state);
      case 'svg':
        return _SvgView(state: state, context: context);
      default:
        return const SizedBox();
    }
  }

  void _copyActive(BuildContext context) {
    String text = '';
    switch (state.activeCodeTab) {
      case 'main':   text = state.result?.mainDart ?? ''; break;
      case 'layers': text = state.result?.layersDart ?? ''; break;
      case 'meta':
        if (state.result != null) {
          text = const JsonEncoder.withIndent('  ').convert(
            state.result!.objects.map((o) => {
              'label': o.label, 'zone': o.zone,
              'x': o.x, 'y': o.y, 'width': o.width, 'height': o.height,
            }).toList(),
          );
        }
        break;
      case 'svg':
        final obj = _selectedObj();
        text = obj?.geometry?.svgPath ?? '';
        break;
    }
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied'), duration: Duration(seconds: 2), backgroundColor: Color(0xFF111827)),
      );
    }
  }

  DetectedObject? _selectedObj() {
    final r = state.result;
    if (r == null || r.objects.isEmpty) return null;
    if (state.selectedLayer == null) return r.objects.first;
    return r.objects.firstWhere((o) => o.label == state.selectedLayer, orElse: () => r.objects.first);
  }
}

// ── Code view ──────────────────────────────────────────────
class _CodeView extends StatelessWidget {
  final String code;
  const _CodeView({required this.code});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFAFAFA),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(code,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.6, color: Color(0xFF1F2937))),
      ),
    );
  }
}

// ── Metadata view ──────────────────────────────────────────
class _MetaView extends StatelessWidget {
  final AppState state;
  const _MetaView({required this.state});

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    if (result == null) {
      return const Center(child: Text('Metadata will appear after separation.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Chip('${result.numObjects} objects'),
            _Chip('${result.imageWidth}×${result.imageHeight}px'),
            _Chip(result.method),
            if (result.shapely) _Chip('Shapely ✓', bg: const Color(0xFFDCFCE7), fg: const Color(0xFF166534)),
          ]),
          const SizedBox(height: 12),
          ...result.objects.map((obj) => _ObjectCard(obj: obj)),
          if (result.relationships.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Spatial Relationships',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
            const SizedBox(height: 6),
            ...result.relationships.map((r) => Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(5)),
                  child: Text(
                    'Layer ${r.objectA} is ${r.bIs.replaceAll('_', ' ')} Layer ${r.objectB}'
                    '  ·  ${r.centroidDistancePx.toStringAsFixed(0)}px apart'
                    '${r.overlaps ? '  ·  overlapping' : ''}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF374151)),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

class _ObjectCard extends StatelessWidget {
  final DetectedObject obj;
  const _ObjectCard({required this.obj});

  @override
  Widget build(BuildContext context) {
    final geo = obj.geometry;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE5E7EB)), borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Layer ${obj.label}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(width: 8),
            ZoneBadge(zone: obj.zone),
          ]),
          const SizedBox(height: 6),
          _MRow('Position', 'x=${obj.x}, y=${obj.y}'),
          _MRow('Size', '${obj.width}×${obj.height}px'),
          if (geo != null) ...[
            _MRow('Centroid', '(${geo.centroid[0]}, ${geo.centroid[1]})'),
            _MRow('Area', '${geo.areaPx.toStringAsFixed(0)} px²'),
            _MRow('Perimeter', '${geo.perimeterPx.toStringAsFixed(1)} px'),
            if (geo.aspectRatio != null) _MRow('Aspect ratio', geo.aspectRatio!.toStringAsFixed(3)),
            if (geo.solidity != null) _MRow('Solidity', geo.solidity!.toStringAsFixed(3)),
            if (geo.compactness != null) _MRow('Compactness', geo.compactness!.toStringAsFixed(3)),
            if (geo.orientationDeg != null) _MRow('Orientation', '${geo.orientationDeg!.toStringAsFixed(1)}°'),
          ],
        ],
      ),
    );
  }
}

class _MRow extends StatelessWidget {
  final String label, value;
  const _MRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(children: [
          SizedBox(width: 88, child: Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)))),
          Text(value, style: const TextStyle(fontSize: 11, color: Color(0xFF111827))),
        ]),
      );
}

// ── SVG view ───────────────────────────────────────────────
class _SvgView extends StatelessWidget {
  final AppState state;
  final BuildContext context;
  const _SvgView({required this.state, required this.context});

  @override
  Widget build(BuildContext _) {
    final result = state.result;
    if (result == null) {
      return const Center(child: Text('SVG outlines appear after separation.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))));
    }
    final obj = state.selectedLayer != null
        ? result.objects.firstWhere((o) => o.label == state.selectedLayer, orElse: () => result.objects.first)
        : result.objects.first;

    final svgPath = obj.geometry?.svgPath ?? '';
    final w = result.imageWidth;
    final h = result.imageHeight;
    final fullSvg = svgPath.isNotEmpty
        ? '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<svg xmlns="http://www.w3.org/2000/svg"\n'
          '     width="$w" height="$h"\n'
          '     viewBox="0 0 $w $h">\n'
          '  <path d="$svgPath"\n'
          '        fill="none"\n'
          '        stroke="#2563EB"\n'
          '        stroke-width="2"\n'
          '        stroke-linejoin="round"\n'
          '        stroke-linecap="round"/>\n'
          '</svg>'
        : '<!-- No contour data for this layer -->';

    return Container(
      color: const Color(0xFFFAFAFA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Text('Layer ${obj.label} — vector outline',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                const Spacer(),
                _CopyBtn(label: 'Copy SVG', onTap: () {
                  Clipboard.setData(ClipboardData(text: fullSvg));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('SVG copied'), duration: Duration(seconds: 2),
                        backgroundColor: Color(0xFF111827)),
                  );
                }),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(fullSvg,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.6, color: Color(0xFF1F2937))),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Micro widgets ──────────────────────────────────────────
class _Tab extends StatelessWidget {
  final String id, label, active;
  final ValueChanged<String> onTap;
  const _Tab({required this.id, required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final on = id == active;
    return GestureDetector(
      onTap: () => onTap(id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: on ? const Color(0xFF2563EB) : Colors.transparent, width: 2)),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                color: on ? const Color(0xFF2563EB) : const Color(0xFF6B7280))),
      ),
    );
  }
}

class _CopyBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CopyBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(6), color: Colors.white),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.copy, size: 12, color: Color(0xFF6B7280)),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ]),
        ),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final Color bg, fg;
  const _Chip(this.label, {this.bg = const Color(0xFFF3F4F6), this.fg = const Color(0xFF374151)});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w500)),
      );
}
