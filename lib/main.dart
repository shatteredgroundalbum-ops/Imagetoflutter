import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString('server_url');
  if (savedUrl != null) ApiService().baseUrl = savedUrl;
  runApp(const ImageToFlutterApp());
}

class ImageToFlutterApp extends StatelessWidget {
  const ImageToFlutterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Separator to Flutter Code',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
