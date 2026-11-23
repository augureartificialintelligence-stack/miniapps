# AUGURE MINIAPPS — Assistente de Vendas por Voz (MVP)

App Flutter (Android/iOS), offline-first, sem login. Fluxo: falar → confirmar o que foi entendido → perguntas curtas → preço calculado em código → resposta em voz.

## Estrutura
- `lib/core/pricing_calculator.dart` — cálculo determinístico em centavos (sem LLM).
- `lib/core/pt_br_parser.dart` — números, dinheiro, sim/não e comandos em pt-BR.
- `lib/core/dialog_machine.dart` — máquina de estados (produto → quantidade → custo → margem → confirmação → resultado; comandos: repetir, voltar, recomeçar).
- `lib/voice/` — interfaces `SttEngine`/`TtsEngine` e implementação com STT/TTS do sistema.
- `lib/llm/` — interface `LlmEngine`, interpretador de fala, `SmartDialog` (fluxo híbrido) e adaptador `EdgeAiLlmEngine`.
- `lib/ui/voice_screen.dart` — botão grande de falar, campo de texto alternativo, confirmação da transcrição.
- `test/core_test.dart` — testes do núcleo .

## Rodar
```bash
flutter create . --platforms=android,ios --project-name augure_miniapps
flutter pub get
flutter test
flutter run
```
Permissões (adicionar após `flutter create`):
- Android `AndroidManifest.xml`: `RECORD_AUDIO`, `INTERNET` e `<queries>` para `android.speech.RecognitionService`.
- iOS `Info.plist`: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

## Estado de verificação
- `lib/core`, `lib/llm` (exceto `edge_ai_llm_engine.dart`) e testes: analisados e executados com Dart puro (22/22 passam).
- `lib/ui`, `lib/voice`, `lib/llm/edge_ai_llm_engine.dart` e `main.dart`: **não compilados nem executados** (sem Flutter SDK no ambiente de criação). Validar a API do `speech_to_text` (`SpeechListenOptions.onDevice`) e do `flutter_tts` na versão instalada.
- Voz offline depende do pacote de idioma pt-BR no aparelho (Experimento B do documento).

## Fase 2 — LLM local (incluída)
Fluxo híbrido (`lib/llm/`): o parser determinístico tenta primeiro; só se não entender, o LLM local reescreve a fala em forma canônica (ex.: "umas duas dezenas" → `20`) e a **mesma máquina de estados** valida de novo. O LLM nunca calcula nem decide preços, e o usuário ainda ouve a leitura dos valores na confirmação.

- Motor: `flutter_edge_ai` + `flutter_edge_ai_llama` (llama.cpp, GGUF). Ex-`flutter_gemma`, renomeado.
- Modelo padrão: Qwen2.5-1.5B-Instruct Q4_K_M (~1,1 GB, Apache-2.0, sem token), baixado **só se o usuário tocar em "Baixar"**, com o link fixado no commit do Hugging Face. Depois disso funciona offline. Para trocar, crie outro `LlmModelSpec`.
- Sem o modelo (ou se ele falhar) o app continua 100% no fluxo determinístico.
- `test/llm_test.dart` usa um LLM falso: testa a integração, **não a qualidade do modelo real em português**.

Configuração de plataforma (da documentação do flutter_edge_ai):
- Exige Flutter ≥ 3.44 / Dart ≥ 3.12.
- iOS: deployment target **16.4** com llama.cpp; no `ios/Podfile` use `platform :ios, '16.4'` e `use_frameworks! :linkage => :static`. Para modelos grandes, adicione os entitlements de memória estendida descritos no README do pacote.
- Android: `INTERNET` também no manifesto de release (para baixar o modelo).

A validar em aparelhos reais: tempo de resposta, RAM e bateria do 1,5B em Android de entrada; se ficar pesado, usar um modelo menor.

## Fase 3 (não incluída)
STT whisper.cpp ou sherpa-onnx e TTS Piper pt-BR, no lugar do STT/TTS do sistema.
