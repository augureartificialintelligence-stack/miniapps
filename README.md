# AUGURE MINIAPPS — Assistente de Vendas por Voz (MVP)

App Flutter (Android/iOS), offline-first, sem login. Fluxo: falar → confirmar o que foi entendido → perguntas curtas → preço calculado em código → resposta em voz.

## Estrutura
- `lib/core/pricing_calculator.dart` — cálculo determinístico em centavos (sem LLM).
- `lib/core/pt_br_parser.dart` — números, dinheiro, sim/não e comandos em pt-BR.
- `lib/core/dialog_machine.dart` — máquina de estados (produto → quantidade → custo → margem → confirmação → resultado; comandos: repetir, voltar, recomeçar).
- `lib/voice/` — interfaces `SttEngine`/`TtsEngine` e implementação com STT/TTS do sistema.
- `lib/ui/voice_screen.dart` — botão grande de falar, campo de texto alternativo, confirmação da transcrição.
- `test/core_test.dart` — testes do núcleo (14 casos).

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
- `lib/core` + testes: analisados e executados com Dart puro (14/14 passam).
- `lib/ui`, `lib/voice` e `main.dart`: **não compilados nem executados** (sem Flutter SDK no ambiente de criação). Validar a API do `speech_to_text` (`SpeechListenOptions.onDevice`) e do `flutter_tts` na versão instalada.
- Voz offline depende do pacote de idioma pt-BR no aparelho (Experimento B do documento).

## Fase 2 (não incluída)
LLM local (flutter_gemma / llama.cpp) apenas para interpretar fala livre; STT whisper.cpp ou sherpa-onnx; TTS Piper pt-BR. O LLM nunca calcula nem decide preços.
