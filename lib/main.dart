import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'core/dialog_machine.dart';
import 'llm/edge_ai_llm_engine.dart';
import 'llm/smart_dialog.dart';
import 'llm/utterance_interpreter.dart';
import 'memory/conversation_store.dart';
import 'ui/voice_screen.dart';
import 'voice/system_voice.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registra o motor llama.cpp (GGUF). O modelo so e baixado se o usuario aceitar.
  await EdgeAiLlmEngine.initializeRuntime();
  runApp(AugureMiniApp(store: await _openStore()));
}

/// Memoria local no armazenamento privado do app. Falha = app sem memoria, nunca travado.
Future<ConversationStore?> _openStore() async {
  try {
    return await ConversationStore.open(await getApplicationDocumentsDirectory());
  } catch (e) {
    debugPrint('[AUGURE][MEM] memoria indisponivel: $e');
    return null;
  }
}

const _seed = Color(0xFF1B5E7B);

class AugureMiniApp extends StatefulWidget {
  const AugureMiniApp({super.key, this.store});

  final ConversationStore? store;

  @override
  State<AugureMiniApp> createState() => _AugureMiniAppState();
}

class _AugureMiniAppState extends State<AugureMiniApp> {
  final _llm = EdgeAiLlmEngine();
  late final SmartDialog _dialog = _buildDialog();

  SmartDialog _buildDialog() {
    final store = widget.store;
    // Cadastro salvo (um produto): com ele, a conversa vai direto ao preco.
    final machine = DialogMachine(profile: store?.profile);
    machine.onCorrected = (field, oldValue, newValue) {
      debugPrint('[AUGURE][DLG] correcao ${field.name}: "$oldValue" -> "$newValue"');
      store?.logExample({
        'type': 'correction',
        'field': field.name,
        'old': oldValue,
        'new': newValue,
      });
    };
    // O LLM local recebe o cadastro e exemplos parecidos da memoria (RAG local).
    final dialog = SmartDialog(machine, UtteranceInterpreter(_llm, context: store));
    dialog.onTurn = (t) {
      debugPrint('[AUGURE][DLG] ${t.stateBefore.name} "${t.input}"'
          '${t.llmCanonical != null ? ' llm="${t.llmCanonical}"' : ''}'
          ' -> ${t.stateAfter.name}${t.understood ? '' : ' (nao entendeu)'}');
      store?.logExample(t.toJson());
    };
    return dialog;
  }

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
      // Tema claro/escuro segue a configuracao do sistema.
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: VoiceScreen(
        stt: SystemStt(),
        tts: SystemTts(),
        dialog: _dialog,
        llm: _llm,
        store: widget.store,
      ),
    );
  }
}
