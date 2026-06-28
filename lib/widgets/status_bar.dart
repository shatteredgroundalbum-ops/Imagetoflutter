import 'package:flutter/material.dart';
import '../models/app_models.dart';

class StatusBar extends StatelessWidget {
  final AppState state;
  final VoidCallback onCopyAll;
  final VoidCallback onSaveProject;

  const StatusBar({super.key, required this.state, required this.onCopyAll, required this.onSaveProject});

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    final health = state.health;

    return Container(
      height: 36,
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB)))),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          _SI(icon: state.imagePath != null ? Icons.check_circle_outline : Icons.info_outline,
              label: state.imagePath != null ? state.imagePath!.split('/').last : 'No image loaded',
              ok: state.imagePath != null),
          const SizedBox(width: 18),
          _SI(icon: result != null ? Icons.check_circle_outline : Icons.layers_outlined,
              label: result != null ? '${result.numObjects} layer${result.numObjects != 1 ? 's' : ''} detected' : 'No layers detected',
              ok: result != null),
          const SizedBox(width: 18),
          if (health != null)
            _SI(
              icon: health.sam ? Icons.auto_awesome : Icons.memory,
              label: health.sam ? 'MobileSAM on-device' : 'Classical mode',
              ok: health.sam,
            ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onCopyAll,
            icon: const Icon(Icons.copy_all, size: 13),
            label: const Text('Copy All Code'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF374151),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              textStyle: const TextStyle(fontSize: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: result != null ? onSaveProject : null,
            icon: const Icon(Icons.save_outlined, size: 13),
            label: const Text('Save Project'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFD1D5DB),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              elevation: 0,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

class _SI extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool ok, warn;
  const _SI({required this.icon, required this.label, this.ok = false, this.warn = false});
  @override
  Widget build(BuildContext context) {
    final color = warn ? const Color(0xFFD97706) : ok ? const Color(0xFF059669) : const Color(0xFF9CA3AF);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 12, color: color)),
    ]);
  }
}
