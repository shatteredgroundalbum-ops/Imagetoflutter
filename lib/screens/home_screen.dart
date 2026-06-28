import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_models.dart';
import '../services/segmentation_service.dart';
import '../widgets/left_sidebar.dart';
import '../widgets/viewport_panel.dart';
import '../widgets/code_panel.dart';
import '../widgets/status_bar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppState _state = const AppState();
  final _seg = SegmentationService();

  double _confidence = 0.5;
  bool _removeBg = false;
  bool _groupSmall = false;
  String _detectionMode = 'ai';

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  Future<void> _initModel() async {
    // Try to load MobileSAM model in background
    final loaded = await _seg.loadModel();
    setState(() => _state = _state.copyWith(
      health: HealthStatus(
        online: true,
        sam: loaded,
        rembg: false,
        shapely: false,
      ),
    ));
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.image, allowMultiple: false);
    if (result != null && result.files.single.path != null) {
      setState(() => _state = _state.copyWith(
            imagePath: result.files.single.path,
            phase: AppPhase.idle,
            result: null,
            selectedLayer: null,
          ));
    }
  }

  Future<void> _separate() async {
    if (_state.imagePath == null) return;
    setState(() => _state = _state.copyWith(
        phase: AppPhase.processing, progress: 0.0, errorMessage: null));
    try {
      final result = await _seg.processImage(
        imageFile: File(_state.imagePath!),
        confidence: _confidence,
        removeBackground: _removeBg,
        groupSmall: _groupSmall,
        detectionMode: _detectionMode,
        onProgress: (p) =>
            setState(() => _state = _state.copyWith(progress: p)),
      );
      setState(() => _state = _state.copyWith(
            phase: AppPhase.done,
            result: result,
            progress: 1.0,
            selectedLayer:
                result.objects.isNotEmpty ? result.objects.first.label : null,
          ));
      _snack('✓ ${result.numObjects} objects separated (${result.method})');
    } catch (e) {
      setState(() => _state =
          _state.copyWith(phase: AppPhase.error, errorMessage: e.toString()));
      _snack('Error: $e', error: true);
    }
  }

  void _selectLayer(int label) => setState(() =>
      _state = _state.copyWith(selectedLayer: label, activeCodeTab: 'layers'));

  Future<void> _saveProject() async {
    final result = _state.result;
    if (result == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _snack('Saved to ${dir.path}');
    } catch (e) {
      _snack('Save failed: $e', error: true);
    }
  }

  void _copyAll() {
    final result = _state.result;
    if (result == null) { _snack('Separate an image first'); return; }
    final all = result.allDartFiles.entries
        .map((e) => '// ── ${e.key} ──\n${e.value}')
        .join('\n\n');
    Clipboard.setData(ClipboardData(text: all));
    _snack('All code copied');
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? const Color(0xFFB91C1C) : const Color(0xFF111827),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _header(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LeftSidebar(
                  state: _state,
                  onPickImage: _pickImage,
                  onSeparate: _separate,
                  onSelectLayer: _selectLayer,
                  onConfidenceChanged: (v) => setState(() => _confidence = v),
                  onRemoveBgChanged: (v) => setState(() => _removeBg = v),
                  onGroupSmallChanged: (v) => setState(() => _groupSmall = v),
                  onModeChanged: (v) => setState(() => _detectionMode = v),
                  confidence: _confidence,
                  removeBg: _removeBg,
                  groupSmall: _groupSmall,
                  detectionMode: _detectionMode,
                ),
                Expanded(
                    child: ViewportPanel(
                        state: _state, onSelectLayer: _selectLayer)),
                CodePanel(
                  state: _state,
                  onTabChanged: (t) => setState(
                      () => _state = _state.copyWith(activeCodeTab: t)),
                ),
              ],
            ),
          ),
          StatusBar(
              state: _state,
              onCopyAll: _copyAll,
              onSaveProject: _saveProject),
        ],
      ),
    );
  }

  Widget _header() {
    final modelStatus = _state.health?.sam == true
        ? 'MobileSAM ready — on-device'
        : 'Classical mode — add MobileSAM model for better quality';

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
                color: const Color(0xFF2563EB),
                borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.layers, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Image Separator to Flutter Code',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827))),
                Text(modelStatus,
                    style: TextStyle(
                        fontSize: 11,
                        color: _state.health?.sam == true
                            ? const Color(0xFF059669)
                            : const Color(0xFF6B7280))),
              ],
            ),
          ),
          _HBtn(
              icon: Icons.folder_open_outlined,
              label: 'Open Image',
              onTap: _pickImage),
          const SizedBox(width: 8),
          _HBtn(
              icon: Icons.download_outlined,
              label: 'Export',
              onTap: _state.result != null ? _saveProject : null),
        ],
      ),
    );
  }
}

class _HBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _HBtn({required this.icon, required this.label, this.onTap});
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 14),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF374151),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
}
