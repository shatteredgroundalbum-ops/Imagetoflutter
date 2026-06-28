import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/app_models.dart';
import 'zone_badge.dart';

class LeftSidebar extends StatelessWidget {
  final AppState state;
  final VoidCallback onPickImage;
  final VoidCallback onSeparate;
  final ValueChanged<int> onSelectLayer;
  final ValueChanged<double> onConfidenceChanged;
  final ValueChanged<bool> onRemoveBgChanged;
  final ValueChanged<bool> onGroupSmallChanged;
  final ValueChanged<String> onModeChanged;
  final double confidence;
  final bool removeBg;
  final bool groupSmall;
  final String detectionMode;

  const LeftSidebar({
    super.key,
    required this.state,
    required this.onPickImage,
    required this.onSeparate,
    required this.onSelectLayer,
    required this.onConfidenceChanged,
    required this.onRemoveBgChanged,
    required this.onGroupSmallChanged,
    required this.onModeChanged,
    required this.confidence,
    required this.removeBg,
    required this.groupSmall,
    required this.detectionMode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildUploadSection(context),
          _buildSettingsSection(context),
          Expanded(child: _buildLayersSection()),
        ],
      ),
    );
  }

  // ── 1. Upload ──────────────────────────────────────────
  Widget _buildUploadSection(BuildContext context) {
    final hasImage = state.imagePath != null;
    return _SidebarSection(
      label: '1. Upload Image',
      child: Column(
        children: [
          GestureDetector(
            onTap: onPickImage,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                border: Border.all(
                  color: hasImage ? const Color(0xFF2563EB) : const Color(0xFFD1D5DB),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: hasImage
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: Image.file(
                        File(state.imagePath!),
                        fit: BoxFit.cover,
                        width: double.infinity,
                      ),
                    )
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.image_outlined, size: 32, color: Color(0xFF2563EB)),
                        SizedBox(height: 6),
                        Text('Tap to browse',
                            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          _SidebarPrimaryBtn(icon: Icons.folder_open_outlined, label: 'Browse Image', onTap: onPickImage),
        ],
      ),
    );
  }

  // ── 2. Settings ────────────────────────────────────────
  Widget _buildSettingsSection(BuildContext context) {
    return _SidebarSection(
      label: '2. Separation Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FieldLabel('Detection Mode'),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(6),
              color: Colors.white,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: detectionMode,
                isExpanded: true,
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
                items: const [
                  DropdownMenuItem(value: 'ai', child: Text('✦  AI (Best Quality)')),
                  DropdownMenuItem(value: 'classical', child: Text('⚙  Classical (Fast)')),
                ],
                onChanged: (v) => onModeChanged(v!),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const _FieldLabel('Confidence'),
              const Spacer(),
              Text('${(confidence * 100).round()}%',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF2563EB),
              thumbColor: const Color(0xFF2563EB),
              overlayColor: const Color(0x262563EB),
              trackHeight: 3,
            ),
            child: Slider(value: confidence, min: 0.1, max: 0.99, onChanged: onConfidenceChanged),
          ),
          _ToggleRow(label: 'Remove Background', value: removeBg, onChanged: onRemoveBgChanged),
          _ToggleRow(label: 'Group Small Objects', value: groupSmall, onChanged: onGroupSmallChanged),
          const SizedBox(height: 10),
          _SidebarPrimaryBtn(
            icon: Icons.auto_fix_high,
            label: state.phase == AppPhase.processing ? 'Processing…' : 'Separate Image',
            onTap: state.imagePath != null && state.phase != AppPhase.processing ? onSeparate : null,
          ),
        ],
      ),
    );
  }

  // ── 3. Layers ──────────────────────────────────────────
  Widget _buildLayersSection() {
    return _SidebarSection(
      label: '3. Layers',
      expand: true,
      child: state.result == null
          ? const _EmptyLayers()
          : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: state.result!.objects.length,
              itemBuilder: (_, i) {
                final obj = state.result!.objects[i];
                return _LayerItem(
                  obj: obj,
                  isSelected: state.selectedLayer == obj.label,
                  onTap: () => onSelectLayer(obj.label),
                );
              },
            ),
    );
  }
}

// ── Layer item ─────────────────────────────────────────────
class _LayerItem extends StatelessWidget {
  final DetectedObject obj;
  final bool isSelected;
  final VoidCallback onTap;

  const _LayerItem({required this.obj, required this.isSelected, required this.onTap});

  Uint8List _bytes(String dataUri) => base64Decode(dataUri.split(',').last);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEFF6FF) : Colors.transparent,
          border: Border.all(color: isSelected ? const Color(0xFFBFDBFE) : Colors.transparent),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE5E7EB)),
                borderRadius: BorderRadius.circular(4),
                color: const Color(0xFFF3F4F6),
              ),
              child: obj.thumbnail.startsWith('data:')
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.memory(_bytes(obj.thumbnail), fit: BoxFit.contain),
                    )
                  : const Icon(Icons.image, size: 18, color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Layer ${obj.label}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                  Text('${obj.width}×${obj.height}px',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                ],
              ),
            ),
            ZoneBadge(zone: obj.zone),
          ],
        ),
      ),
    );
  }
}

class _EmptyLayers extends StatelessWidget {
  const _EmptyLayers();
  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.layers_outlined, size: 36, color: Color(0xFFD1D5DB)),
        SizedBox(height: 8),
        Text('Layers will appear here\nafter separation',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF), height: 1.5)),
      ],
    );
  }
}

// ── Shared sidebar widgets ─────────────────────────────────
class _SidebarSection extends StatelessWidget {
  final String label;
  final Widget child;
  final bool expand;
  const _SidebarSection({required this.label, required this.child, this.expand = false});

  @override
  Widget build(BuildContext context) {
    final inner = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6)))),
      child: expand ? Expanded(child: SingleChildScrollView(child: inner)) : inner,
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)));
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.label, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
        const Spacer(),
        Switch(value: value, onChanged: onChanged, activeColor: const Color(0xFF2563EB),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ],
    );
  }
}

class _SidebarPrimaryBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _SidebarPrimaryBtn({required this.icon, required this.label, this.onTap});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 14),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2563EB),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFD1D5DB),
          padding: const EdgeInsets.symmetric(vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
      ),
    );
  }
}
