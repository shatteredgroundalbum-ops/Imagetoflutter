import 'package:flutter/material.dart';
class ZoneBadge extends StatelessWidget {
  final String zone;
  const ZoneBadge({super.key, required this.zone});
  @override
  Widget build(BuildContext context) {
    final s = _style(zone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: s.$1, borderRadius: BorderRadius.circular(10)),
      child: Text(zone.replaceAll('_', ' '), style: TextStyle(fontSize: 10, color: s.$2, fontWeight: FontWeight.w500)),
    );
  }
  (Color, Color) _style(String z) => switch (z) {
    'floor'      => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
    'ceiling'    => (const Color(0xFFEDE9FE), const Color(0xFF5B21B6)),
    'foreground' => (const Color(0xFFDCFCE7), const Color(0xFF166534)),
    'left_wall'  => (const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
    'right_wall' => (const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
    _            => (const Color(0xFFF3F4F6), const Color(0xFF6B7280)),
  };
}
