import 'dart:async';

/// Uma sessao "crua" do reconhecedor do sistema. O Android encerra cada sessao sozinho
/// na primeira pausa curta (ignora o tempo de silencio pedido pelo app), entao a
/// [ContinuousDictation] abre sessoes em sequencia ate a pessoa realmente parar de falar.
abstract class RecognizerSession {
  /// Abre uma sessao. [onWords] recebe o texto DESTA sessao (parcial ou final);
  /// [onEnd] e chamado quando a sessao termina (erro = codigo do sistema, ou null).
  Future<bool> start(
    void Function(String words, bool isFinal) onWords,
    void Function(String? error) onEnd,
  );

  Future<void> stop();
}

/// Ditado continuo: so termina quando a PESSOA para de falar.
///
/// - Junta o texto de varias sessoes do reconhecedor ("quero vender" + "marmitas de
///   frango") em uma resposta so.
/// - Termina depois de [silence] sem palavras novas (a pessoa ja falou algo), ou de
///   [noSpeech] se ela nao disse nada, ou em [maxTotal], ou quando [stop] e chamado.
/// - Erros passageiros (nao entendeu, tempo esgotado) reabrem o microfone; erros de
///   permissao encerram.
class ContinuousDictation {
  ContinuousDictation(
    this._rec, {
    // 4 s: pausa natural para pensar no meio da frase nao encerra a escuta.
    this.silence = const Duration(seconds: 4),
    this.noSpeech = const Duration(seconds: 10),
    this.maxTotal = const Duration(seconds: 90),
    this.restartDelay = const Duration(milliseconds: 250),
    this.maxConsecutiveErrors = 6,
    this.log,
  });

  final RecognizerSession _rec;
  final Duration silence;
  final Duration noSpeech;
  final Duration maxTotal;
  final Duration restartDelay;
  final int maxConsecutiveErrors;

  /// Diagnostico opcional (ex.: debugPrint).
  final void Function(String message)? log;

  /// Erros que nao adianta repetir.
  static const fatalErrors = {
    'error_permission',
    'error_insufficient_permissions',
    'error_audio_error',
  };

  bool _active = false;
  String _committed = '';
  String _current = '';
  int _session = 0;
  int _errors = 0;
  bool _heardWords = false;
  Timer? _endTimer;
  Timer? _capTimer;
  Timer? _restartTimer;
  void Function(String text, bool isFinal)? _onResult;

  bool get isListening => _active;

  String get _full => [_committed, _current].where((s) => s.trim().isNotEmpty).join(' ');

  Future<void> listen(void Function(String text, bool isFinal) onResult) async {
    if (_active) await stop();
    _active = true;
    _committed = '';
    _current = '';
    _errors = 0;
    _heardWords = false;
    _onResult = onResult;
    _capTimer = Timer(maxTotal, () => _finish('tempo maximo'));
    _armEndTimer();
    await _startSession();
  }

  /// A pessoa tocou em parar: entrega o que foi ouvido ate agora.
  Future<void> stop() async => _finish('parado pelo usuario');

  Future<void> _startSession() async {
    if (!_active) return;
    final id = ++_session;
    var ended = false;
    void end(String? error) {
      // Cada sessao termina uma vez so (o sistema avisa "notListening" e "done").
      if (ended || id != _session || !_active) return;
      ended = true;
      _sessionEnded(error);
    }

    bool ok;
    try {
      ok = await _rec.start((words, isFinal) {
        if (id != _session || !_active) return;
        _onWords(words, isFinal);
      }, end);
    } catch (e) {
      ok = false;
      log?.call('falha ao abrir o microfone: $e');
    }
    if (!ok) end('error_start');
  }

  void _onWords(String words, bool isFinal) {
    final w = words.trim();
    if (w.isNotEmpty && w != _current) {
      _current = w;
      _heardWords = true;
      _errors = 0;
      _armEndTimer(); // palavra nova: o silencio comeca a contar de novo
      _onResult?.call(_full, false);
    }
    if (isFinal && _current.isNotEmpty) {
      _committed = _full;
      _current = '';
    }
  }

  void _sessionEnded(String? error) {
    if (!_active) return;
    if (error != null) {
      if (fatalErrors.contains(error)) return _finish('erro $error');
      _errors++;
      if (_errors > maxConsecutiveErrors) return _finish('muitos erros seguidos ($error)');
    }
    // O sistema fechou a sessao numa pausa curta: guarda o texto e reabre o microfone.
    if (_current.isNotEmpty) {
      _committed = _full;
      _current = '';
    }
    log?.call('sessao terminou (${error ?? 'pausa'}); reabrindo o microfone');
    _restartTimer?.cancel();
    _restartTimer = Timer(restartDelay, _startSession);
  }

  void _armEndTimer() {
    _endTimer?.cancel();
    _endTimer = Timer(_heardWords ? silence : noSpeech,
        () => _finish(_heardWords ? 'silencio' : 'ninguem falou'));
  }

  void _finish(String reason) {
    if (!_active) return;
    _active = false;
    _endTimer?.cancel();
    _capTimer?.cancel();
    _restartTimer?.cancel();
    _session++; // ignora qualquer evento atrasado da sessao antiga
    log?.call('fim do ditado: $reason');
    unawaited(_rec.stop());
    final cb = _onResult;
    _onResult = null;
    cb?.call(_full, true);
  }
}
