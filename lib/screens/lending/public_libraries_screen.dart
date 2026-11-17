import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../lending/lending_service.dart';
import '../../services/external_access_directory.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../libraries/state_messages.dart';
import '../external_access_screen.dart';
import '../sources/source_widgets.dart';

Widget _focusedLendingButton({
  required VoidCallback? onPressed,
  required Widget Function(VoidCallback? onPressed) buildButton,
  bool primary = false,
}) {
  return FocusableButton(onPressed: onPressed, useBackgroundFocus: primary, child: buildButton(onPressed));
}

class PublicLibrariesScreen extends StatefulWidget {
  const PublicLibrariesScreen({super.key});
  @override
  State<PublicLibrariesScreen> createState() => _PublicLibrariesScreenState();
}

class _PublicLibrariesScreenState extends State<PublicLibrariesScreen> {
  LendingService? _service;
  List<LendingLibrary> _libraries = [];
  Object? _error;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = context.read<SourceController>();
      await sources.ready;
      if (!mounted) return;
      sources.requireSession();
      final epoch = sources.generation;
      _service ??= LendingService(
        sources.repository,
        sources.profileId!,
        valid: () => mounted && sources.current(epoch) && !sources.blocked,
      );
      final libraries = await _service!.libraries();
      if (mounted) {
        setState(() {
          _libraries = libraries;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add([LendingProvider? provider]) async {
    if (_service == null || _loading) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AddLibraryScreen(service: _service!, provider: provider),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _open(LendingLibrary library) async {
    final service = _service;
    if (service == null) return;
    await service.openPage(lendingHttps(library.home));
  }

  @override
  void dispose() {
    _service?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusedScrollScaffold(
    title: Text(t.lending.title),
    focusableAppBarActions: true,
    actions: [
      IconButton(
        tooltip: t.lending.add,
        onPressed: _service == null || _loading ? null : () => _add(),
        icon: const AppIcon(Symbols.add_rounded),
      ),
    ],
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(24),
        sliver: SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.lending.intro, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 24),
                  if (_loading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 12),
                          Text(t.common.loading, style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    )
                  else if (_error != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 240),
                      child: ErrorStateWidget(
                        message: sourceFailureText(_error!),
                        icon: Symbols.error_outline_rounded,
                        onRetry: () => unawaited(_load()),
                        actionAutofocus: true,
                        actionUseBackgroundFocus: true,
                      ),
                    ),
                  SourceTile(
                    title: t.discover.findNext.openLibraryName,
                    subtitle: t.lending.openLibraryNote,
                    icon: Symbols.menu_book_rounded,
                    onTap: _service == null || _loading
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => LibraryCatalogueScreen(service: _service!)),
                          ),
                  ),
                  if (_libraries.isNotEmpty) ...[
                    const SizedBox(height: 32),
                    for (var i = 0; i < _libraries.length; i++)
                      SourceTile(
                        title: _libraries[i].name,
                        subtitle: _libraries[i].provider.label,
                        icon: Symbols.local_library_rounded,
                        index: i,
                        count: _libraries.length,
                        onTap: () => sourceAction(context, () => _open(_libraries[i])),
                        trailing: AppMenuButton<String>(
                          icon: const AppIcon(Symbols.more_vert_rounded),
                          tooltip: t.fileSources.preferences,
                          adaptiveSheet: true,
                          entriesBuilder: (_) => [
                            AppMenuItem(value: 'remove', label: t.lending.disconnect, icon: Symbols.link_off_rounded),
                          ],
                          onSelected: (action) => sourceAction(context, () async {
                            final library = _libraries[i];
                            if (await showConfirmDialog(
                              context,
                              title: t.lending.disconnect,
                              message: t.lending.disconnectMessage,
                              confirmText: t.lending.disconnect,
                            )) {
                              await _service!.remove(library);
                              if (mounted) await _load();
                            }
                          }),
                        ),
                      ),
                  ],
                  const SizedBox(height: 32),
                  Text(t.lending.findLibrary, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final provider in LendingProvider.values.where(
                        (p) => p != LendingProvider.openLibrary && p != LendingProvider.other,
                      ))
                        ActionChip(
                          label: Text(provider.label),
                          onPressed: _service == null || _loading ? null : () => _add(provider),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _AddLibraryScreen extends StatefulWidget {
  const _AddLibraryScreen({required this.service, this.provider});
  final LendingService service;
  final LendingProvider? provider;
  @override
  State<_AddLibraryScreen> createState() => _AddLibraryScreenState();
}

class _AddLibraryScreenState extends State<_AddLibraryScreen> {
  late LendingProvider _provider = widget.provider ?? LendingProvider.other;
  final _name = TextEditingController(), _url = TextEditingController();
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final library = LendingLibrary(
        id: const Uuid().v4(),
        provider: _provider,
        name: _name.text.trim().isNotEmpty ? _name.text.trim() : _provider.label,
        home: _url.text.trim().isNotEmpty ? _url.text.trim() : _provider.home,
      );
      if (library.name.isEmpty) {
        throw const SourceException(SourceFailure.invalidData);
      }
      await widget.service.save(library);
      if (!mounted) return;
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FocusedScrollScaffold(
    title: Text(t.lending.add),
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(24),
        sliver: SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<LendingProvider>(
                    isExpanded: true,
                    icon: const AppIcon(Symbols.expand_more_rounded),
                    initialValue: _provider,
                    items: [
                      for (final p in LendingProvider.values.where((p) => p != LendingProvider.openLibrary))
                        DropdownMenuItem(value: p, child: Text(p == LendingProvider.other ? t.lending.other : p.label)),
                    ],
                    onChanged: _busy ? null : (value) => setState(() => _provider = value!),
                  ),
                  const SizedBox(height: 24),
                  Text(t.lending.handoff),
                  const SizedBox(height: 24),
                  FocusableTextField(
                    controller: _name,
                    decoration: InputDecoration(labelText: t.lending.libraryName),
                  ),
                  const SizedBox(height: 16),
                  FocusableTextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: t.lending.libraryUrl,
                      hintText: _provider.home,
                      helperText: t.lending.libraryUrlHint,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _focusedLendingButton(
                    onPressed: _busy ? null : () => sourceAction(context, _save),
                    primary: true,
                    buildButton: (onPressed) => FilledButton(onPressed: onPressed, child: Text(t.lending.add)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class LibraryCatalogueScreen extends StatefulWidget {
  const LibraryCatalogueScreen({super.key, required this.service, this.initialQuery, this.selectOnly = false});
  final LendingService service;
  final String? initialQuery;
  final bool selectOnly;
  @override
  State<LibraryCatalogueScreen> createState() => _LibraryCatalogueScreenState();
}

class _LibraryCatalogueScreenState extends State<LibraryCatalogueScreen> {
  final _search = TextEditingController();
  List<LendingBook> _books = [];
  String _catalogProvider = 'openLibrary';
  int _page = 1, _request = 0;
  bool _busy = false, _more = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _search.text = widget.initialQuery?.trim() ?? '';
    if (_search.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load({bool more = false}) async {
    if (_search.text.trim().isEmpty) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = more ? _page + 1 : 1;
      final service = widget.service;
      final result = _catalogProvider == 'googleBooks'
          ? await service.googleBooksSearch(
              _search.text.trim(),
              page: page,
              country: Localizations.localeOf(context).countryCode ?? 'CA',
            )
          : await service.openLibrarySearch(_search.text.trim(), page: page);
      if (mounted && request == _request) {
        setState(() {
          _books = more ? [..._books, ...result.books] : result.books;
          _page = page;
          _more = result.more;
        });
      }
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = error);
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(LendingBook book) async {
    if (widget.selectOnly) {
      Navigator.of(context).pop(book);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _LendingDetailScreen(service: widget.service, book: book),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FocusedScrollScaffold(
    title: Text(_catalogProvider == 'googleBooks' ? 'Google Books' : t.discover.findNext.openLibraryName),
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.selectOnly)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final source in [
                        ('openLibrary', t.discover.findNext.openLibraryName),
                        const ('googleBooks', 'Google Books'),
                      ])
                        ChoiceChip(
                          label: Text(source.$2),
                          selected: _catalogProvider == source.$1,
                          onSelected: _busy
                              ? null
                              : (_) {
                                  setState(() {
                                    _catalogProvider = source.$1;
                                    _books = [];
                                    _more = false;
                                  });
                                  if (_search.text.trim().isNotEmpty) {
                                    unawaited(_load());
                                  }
                                },
                        ),
                    ],
                  ),
                ),
              FocusableTextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _load(),
                decoration: InputDecoration(
                  hintText: t.lending.search,
                  prefixIcon: const AppIcon(Symbols.search_rounded),
                  suffixIcon: IconButton(
                    onPressed: _busy ? null : () => _load(),
                    icon: AppIcon(
                      Directionality.of(context) == ui.TextDirection.rtl
                          ? Symbols.arrow_back_rounded
                          : Symbols.arrow_forward_rounded,
                    ),
                  ),
                ),
              ),
              if (widget.selectOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(t.discover.findNext.libraryCatalogHint, style: Theme.of(context).textTheme.bodySmall),
                ),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 20), child: LinearProgressIndicator()),
              if (_error != null && _books.isEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 240),
                  child: ErrorStateWidget(
                    message: sourceFailureText(_error!),
                    icon: Symbols.error_outline_rounded,
                    onRetry: () => unawaited(_load()),
                    actionAutofocus: true,
                    actionUseBackgroundFocus: true,
                  ),
                )
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: SourceErrorMessage(message: sourceFailureText(_error!)),
                ),
              if (!_busy && _books.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Text(_catalogProvider == 'openLibrary' ? t.lending.openLibraryNote : t.lending.empty),
                ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 210,
            mainAxisSpacing: 28,
            crossAxisSpacing: 20,
            childAspectRatio: .54,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final book = _books[index];
            return FocusableWrapper(
              onSelect: () => _open(book),
              borderRadius: tokens(context).radiusMd,
              child: InkWell(
                onTap: () => _open(book),
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(tokens(context).radiusMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: LendingCover(book: book)),
                    const SizedBox(height: 10),
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                    ),
                    if (book.price != null && book.currency != null)
                      Text(
                        NumberFormat.simpleCurrency(name: book.currency).format(book.price),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary),
                      ),
                  ],
                ),
              ),
            );
          }, childCount: _books.length),
        ),
      ),
      if (_more)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _focusedLendingButton(
              onPressed: _busy ? null : () => _load(more: true),
              buildButton: (onPressed) => TextButton(onPressed: onPressed, child: Text(t.lending.more)),
            ),
          ),
        ),
    ],
  );
}

class LendingCover extends StatelessWidget {
  const LendingCover({super.key, required this.book});
  final LendingBook book;
  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: tokens(context).surface,
      child: Center(child: AppIcon(Symbols.menu_book_rounded, size: 52, color: tokens(context).textMuted)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      child: SizedBox.expand(
        child: book.cover == null
            ? fallback
            : Image.network(
                book.cover.toString(),
                fit: BoxFit.cover,
                cacheWidth: 420,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _LendingDetailScreen extends StatelessWidget {
  const _LendingDetailScreen({required this.service, required this.book});
  final LendingService service;
  final LendingBook book;

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(book.data['source'] == 'googleBooks' ? 'Google Books' : t.discover.findNext.openLibraryName),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: 220, height: 330, child: LendingCover(book: book)),
                    const SizedBox(height: 28),
                    Text(book.title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 8),
                    Text(
                      book.author,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens(context).textMuted),
                    ),
                    if (book.price != null && book.currency != null) ...[
                      const SizedBox(height: 8),
                      Text(NumberFormat.simpleCurrency(name: book.currency).format(book.price)),
                    ],
                    const SizedBox(height: 24),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if (book.page != null)
                          _focusedLendingButton(
                            onPressed: () => sourceAction(context, () => service.openPage(book.page!)),
                            primary: true,
                            buildButton: (onPressed) => FilledButton.icon(
                              onPressed: onPressed,
                              icon: const AppIcon(Symbols.open_in_new_rounded),
                              label: Text(t.lending.continueService),
                            ),
                          ),
                        if (book.purchaseLink != null)
                          _focusedLendingButton(
                            onPressed: () => sourceAction(context, () => service.openPage(book.purchaseLink!)),
                            buildButton: (onPressed) => OutlinedButton.icon(
                              onPressed: onPressed,
                              icon: const AppIcon(Symbols.shopping_bag_rounded),
                              label: Text(t.explore.detail.openOn(site: 'Google Books')),
                            ),
                          ),
                        _focusedLendingButton(
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => ExternalAccessScreen(
                                title: book.title,
                                creator: book.author,
                                identifiers: book.identifiers,
                                categories: const [ExternalAccessCategory.books],
                              ),
                            ),
                          ),
                          buildButton: (onPressed) => OutlinedButton.icon(
                            onPressed: onPressed,
                            icon: const AppIcon(Symbols.storefront_rounded),
                            label: Text(t.explore.detail.links),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (book.data['source'] != 'googleBooks')
                      Text(t.lending.openLibraryNote, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
