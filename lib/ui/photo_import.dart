import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../core/document_parser.dart';
import '../core/pricing_calculator.dart' show formatBrl;
import '../core/pt_br_parser.dart' show speakMeasure;
import '../vision/text_scanner.dart';

/// Resultado das fotos: ingredientes das receitas e precos das compras.
typedef PhotoImport = ({List<RecipeItem> recipe, List<PurchaseItem> purchases});

class _Photo {
  _Photo(this.text, this.kind);
  final String text;
  DocKind kind;
  List<RecipeItem> get recipe => kind == DocKind.recipe ? parseRecipe(text) : const [];
  List<PurchaseItem> get purchases =>
      kind == DocKind.purchase ? parsePurchase(text) : const [];
  int get count => kind == DocKind.recipe ? recipe.length : purchases.length;
}

/// Tela de fotos: tira foto ou escolhe da galeria (varias de uma vez), le o texto no
/// aparelho, identifica se e RECEITA ou COMPRA (a pessoa pode trocar) e pergunta se ha
/// mais imagens. Devolve tudo o que foi lido ao tocar em "Concluir".
class PhotoImportPage extends StatefulWidget {
  const PhotoImportPage({
    super.key,
    required this.scanner,
    this.first,
    this.initialPaths = const [],
    this.onAsk,
  });

  final TextScanner scanner;

  /// De onde vem a primeira imagem (camera ou galeria). null com [initialPaths].
  final ImageSource? first;

  /// Fotos ja tiradas (ex.: recuperadas depois que o Android fechou o app com a camera
  /// aberta). Sao lidas direto, sem abrir a camera de novo.
  final List<String> initialPaths;

  /// Fala a pergunta "tem mais alguma imagem?" (voz do assistente).
  final void Function(String text)? onAsk;

  @override
  State<PhotoImportPage> createState() => _PhotoImportPageState();
}

class _PhotoImportPageState extends State<PhotoImportPage> {
  final _picker = ImagePicker();
  final _photos = <_Photo>[];
  bool _reading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialPaths.isNotEmpty) {
        _read([for (final p in widget.initialPaths) XFile(p)]);
      } else if (widget.first != null) {
        _add(widget.first!);
      }
    });
  }

  Future<void> _add(ImageSource source) async {
    final files = <XFile>[];
    try {
      if (source == ImageSource.gallery) {
        files.addAll(await _picker.pickMultiImage(imageQuality: 90, maxWidth: 2200));
      } else {
        final f = await _picker.pickImage(
            source: ImageSource.camera, imageQuality: 90, maxWidth: 2200);
        if (f != null) files.add(f);
      }
    } catch (e) {
      setState(() => _error = 'Não consegui abrir a câmera ou a galeria: $e');
      return;
    }
    if (files.isEmpty) {
      if (_photos.isEmpty && mounted) Navigator.pop(context);
      return;
    }
    await _read(files);
  }

  /// Le o texto das fotos no aparelho e identifica receita x compra.
  Future<void> _read(List<XFile> files) async {
    setState(() {
      _reading = true;
      _error = null;
    });
    for (final f in files) {
      try {
        final text = await widget.scanner.scan(f.path);
        if (text.trim().isEmpty) {
          _error = 'Uma das fotos não tinha texto legível. Tente mais de perto e com luz.';
          continue;
        }
        _photos.add(_Photo(text, classifyDocument(text)));
      } catch (e) {
        _error = 'Não consegui ler uma das fotos: $e';
      }
    }
    if (!mounted) return;
    setState(() => _reading = false);
    if (_photos.isNotEmpty) {
      widget.onAsk?.call('Li ${_photos.length == 1 ? 'a foto' : '${_photos.length} fotos'}. '
          'Tem mais alguma imagem, da receita ou da compra?');
    }
  }

  PhotoImport get _result => (
        recipe: [for (final p in _photos) ...p.recipe],
        purchases: [for (final p in _photos) ...p.purchases],
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Fotos da receita e da compra')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_reading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Lendo a foto…'),
                      ]),
                    ),
                  if (_error != null)
                    Card(
                      color: scheme.errorContainer,
                      child: Padding(
                          padding: const EdgeInsets.all(12), child: Text(_error!)),
                    ),
                  for (var i = 0; i < _photos.length; i++) _photoCard(i, muted),
                  if (_photos.isNotEmpty && !_reading) ...[
                    const SizedBox(height: 8),
                    Text('Tem mais alguma imagem?',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _add(ImageSource.camera),
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: const Text('Tirar outra'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _add(ImageSource.gallery),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Da galeria'),
                        ),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(children: [
                Expanded(
                  child: TextButton(
                      onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _photos.isEmpty || _reading
                        ? null
                        : () => Navigator.pop(context, _result),
                    child: const Text('Não tenho mais, concluir'),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoCard(int i, TextStyle? muted) {
    final p = _photos[i];
    final lines = p.kind == DocKind.recipe
        ? [
            for (final r in p.recipe)
              '${r.part != null ? '${r.part}: ' : ''}${r.name}'
                  '${r.used != null ? ' — ${speakMeasure(r.used!)}' : ''}',
          ]
        : [
            for (final c in p.purchases)
              '${c.name} — ${formatBrl(c.cents)}'
                  '${c.pack != null ? ' (${speakMeasure(c.pack!)})' : ''}',
          ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Foto ${i + 1}', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Remover foto',
                onPressed: () => setState(() => _photos.removeAt(i)),
                icon: const Icon(Icons.delete_outline),
              ),
            ]),
            // A pessoa corrige se o app errou o tipo da foto.
            SegmentedButton<DocKind>(
              segments: const [
                ButtonSegment(
                    value: DocKind.recipe,
                    icon: Icon(Icons.menu_book_outlined),
                    label: Text('Receita')),
                ButtonSegment(
                    value: DocKind.purchase,
                    icon: Icon(Icons.receipt_long_outlined),
                    label: Text('Compra')),
              ],
              selected: {p.kind},
              onSelectionChanged: (s) => setState(() => p.kind = s.first),
            ),
            const SizedBox(height: 8),
            if (lines.isEmpty)
              Text(
                  p.kind == DocKind.recipe
                      ? 'Não achei ingredientes nesta foto. Se for uma nota, toque em Compra.'
                      : 'Não achei preços nesta foto. Se for uma receita, toque em Receita.',
                  style: muted)
            else ...[
              Text(
                  p.kind == DocKind.recipe
                      ? '${p.count} ingredientes encontrados'
                      : '${p.count} itens com preço encontrados',
                  style: muted),
              const SizedBox(height: 4),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text('• $l'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
