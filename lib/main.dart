import 'package:material_ui/material_ui.dart';

import 'core/dialog_machine.dart';
import 'llm/edge_ai_llm_engine.dart';
import 'llm/smart_dialog.dart';
import 'llm/utterance_interpreter.dart';
import 'ui/voice_screen.dart';
import 'voice/system_voice.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registra o motor llama.cpp (GGUF). O modelo so e baixado se o usuario aceitar.
  await EdgeAiLlmEngine.initializeRuntime();
  runApp(const AugureMiniApp());
}

class AugureMiniApp extends StatefulWidget {
  const AugureMiniApp({super.key});

  @override
  State<AugureMiniApp> createState() => _AugureMiniAppState();
}

class _AugureMiniAppState extends State<AugureMiniApp> {
  final _llm = EdgeAiLlmEngine();
  late final _dialog = SmartDialog(DialogMachine(), UtteranceInterpreter(_llm));

  @override
  void dispose() {
    _llm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AUGURE Assistente de Vendas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1B5E7B),
        useMaterial3: true,
      ),
      home: VoiceScreen(
        stt: SystemStt(),
        tts: SystemTts(),
        dialog: _dialog,
        llm: _llm,
      ),
    );
  }
}
