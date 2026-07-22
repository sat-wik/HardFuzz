// main.dart — HardFuzz v2 app entry.
import 'package:flutter/material.dart';
import 'screens/connect_screen.dart';

void main() => runApp(const HardFuzzApp());

class HardFuzzApp extends StatelessWidget {
  const HardFuzzApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HardFuzz',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2B6CB0)),
        useMaterial3: true,
      ),
      home: const ConnectScreen(),
    );
  }
}
