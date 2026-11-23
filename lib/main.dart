import 'package:flutter/material.dart';

import 'ui/voice_screen.dart';
import 'voice/system_voice.dart';

void main() {
  runApp(const AugureMiniApp());
}

class AugureMiniApp extends StatelessWidget {
  const AugureMiniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AUGURE Assistente de Vendas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1B5E7B),
        useMaterial3: true,
      ),
      home: VoiceScreen(stt: SystemStt(), tts: SystemTts()),
    );
  }
}
