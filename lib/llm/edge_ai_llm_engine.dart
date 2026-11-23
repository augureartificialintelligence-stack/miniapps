import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

import 'llm_engine.dart';

/// Modelo GGUF baixado no primeiro uso (Wi-Fi). URL fixada em um commit do Hugging Face
/// para o download ser reproduzivel.
class LlmModelSpec {
  const LlmModelSpec({
    required this.name,
    required this.url,
    required this.approxBytes,
    required this.license,
  });

  final String name;
  final String url;
  final int approxBytes;
  final String license;

  /// Padrao do MVP: Qwen2.5-1.5B-Instruct Q4_K_M (Apache 2.0, repositorio publico, sem token).
  static const qwen25_1_5b = LlmModelSpec(
    name: 'Qwen2.5-1.5B-Instruct Q4_K_M',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/'
        '91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    approxBytes: 1120000000,
    license: 'Apache-2.0',
  );
}

/// Implementacao de [LlmEngine] sobre flutter_edge_ai + llama.cpp (GGUF).
/// Chame [EdgeAiLlmEngine.initializeRuntime] uma vez em `main()` antes de usar.
///
/// ATENCAO: nao compilado neste ambiente (sem Flutter SDK). Nomes de API conferidos no
/// README do flutter_edge_ai 2.7.1 / flutter_edge_ai_llama 0.2.0; validar na 1a build.
class EdgeAiLlmEngine implements InstallableLlm {
  EdgeAiLlmEngine({this.spec = LlmModelSpec.qwen25_1_5b});

  final LlmModelSpec spec;
  dynamic _model; // InferenceModel retornado por getActiveModel
  bool _ready = false;

  static Future<void> initializeRuntime() => FlutterEdgeAi.initialize(
        inferenceEngines: const [LlamaEngineProvider()],
      );

  @override
  bool get isReady => _ready;

  @override
  int get approxDownloadBytes => spec.approxBytes;

  /// Baixa e instala o modelo (uma vez). [onProgress] recebe 0..100.
  @override
  Future<void> install({void Function(int percent)? onProgress}) async {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.gguf,
    )
        .fromNetwork(spec.url)
        .withProgress((p) => onProgress?.call(p))
        .install();
  }

  @override
  Future<bool> load() async {
    try {
      // maxTokens = janela de contexto (prompt + resposta). Curta: prompts sao pequenos.
      _model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      _ready = true;
    } catch (_) {
      _ready = false; // sem modelo instalado ou falha ao carregar
    }
    return _ready;
  }

  @override
  Future<String> complete(
    String prompt, {
    Map<String, Object?>? jsonSchema,
    int maxTokens = 48,
  }) async {
    final model = _model;
    if (!_ready || model == null) throw StateError('LLM nao carregado');

    ResponseFormat? format;
    if (jsonSchema != null) {
      format = ResponseFormat.jsonSchema(jsonSchema);
      if (model.refusalFor(format) != null) format = null; // motor sem saida estruturada
    }

    // Chat novo a cada chamada: sem historico, sem vazamento entre usuarios/sessoes.
    final chat = await model.openChat(
      maxOutputTokens: maxTokens,
      responseFormat: format,
    );
    try {
      await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
      final out = StringBuffer();
      await for (final r in chat.generateChatResponseAsync()) {
        if (r is TextResponse) out.write(r.token);
      }
      return out.toString();
    } finally {
      await chat.close();
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
    await _model?.close();
    _model = null;
  }
}
