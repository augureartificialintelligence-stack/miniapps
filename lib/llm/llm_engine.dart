/// Abstracao do LLM local. O restante do app so conhece esta interface; a implementacao
/// concreta (flutter_edge_ai + llama.cpp) fica em `edge_ai_llm_engine.dart`.
///
/// Regra de ouro: o LLM NUNCA calcula nem decide precos. Ele so converte fala livre
/// em valores estruturados, que o codigo determinístico valida.
abstract class LlmEngine {
  /// true quando o modelo esta instalado e carregado.
  bool get isReady;

  /// Carrega o modelo ja instalado. Retorna false se nao houver modelo ou falhar.
  Future<bool> load();

  /// Uma chamada isolada (sem historico). [jsonSchema] pede saida JSON estruturada
  /// quando o motor suportar; caso contrario o chamador deve tolerar texto livre.
  Future<String> complete(
    String prompt, {
    Map<String, Object?>? jsonSchema,
    int maxTokens = 48,
  });

  Future<void> dispose();
}

/// LLM que precisa baixar o modelo uma vez (primeiro uso, preferencialmente em Wi-Fi).
abstract class InstallableLlm implements LlmEngine {
  /// Tamanho aproximado do download, em bytes (para avisar o usuario).
  int get approxDownloadBytes;

  /// Baixa e instala o modelo. [onProgress] recebe 0..100.
  Future<void> install({void Function(int percent)? onProgress});
}
