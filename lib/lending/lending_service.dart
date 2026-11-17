import 'package:url_launcher/url_launcher.dart';

import '../services/book_identifiers.dart';
import '../sources/source_database.dart';
import '../sources/source_models.dart';
import '../sources/source_transport.dart';

/// Library services remain independent of owned files, watched state and DRM.
enum LendingProvider { openLibrary, hoopla, palace, cloudLibrary, borrowBox, cantook, onleihe, other }

extension LendingProviderInfo on LendingProvider {
  String get label => switch (this) {
    LendingProvider.openLibrary => 'Open Library',
    LendingProvider.hoopla => 'Hoopla',
    LendingProvider.palace => 'The Palace Project',
    LendingProvider.cloudLibrary => 'cloudLibrary',
    LendingProvider.borrowBox => 'BorrowBox',
    LendingProvider.cantook => 'Cantook',
    LendingProvider.onleihe => 'Onleihe',
    LendingProvider.other => '',
  };
  String get home => switch (this) {
    LendingProvider.openLibrary => 'https://openlibrary.org',
    LendingProvider.hoopla => 'https://www.hoopladigital.com',
    LendingProvider.palace => 'https://thepalaceproject.org/information-for-library-patrons/',
    LendingProvider.cloudLibrary => 'https://www.yourcloudlibrary.com/',
    LendingProvider.borrowBox => 'https://www.borrowbox.com/',
    LendingProvider.cantook => 'https://app.doc.cantook.com/en/doc/APP2445/app-cantook/connecting-to-a-library',
    LendingProvider.onleihe => 'https://hilfe.onleihe.de/',
    LendingProvider.other => '',
  };
}

Uri lendingHttps(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const SourceException(SourceFailure.permission);
  }
  return uri;
}

class LendingLibrary {
  const LendingLibrary({required this.id, required this.provider, required this.name, required this.home});
  final String id, name, home;
  final LendingProvider provider;
  Map<String, dynamic> toJson() => {'id': id, 'provider': provider.name, 'name': name, 'home': home};
  factory LendingLibrary.fromJson(Map<String, dynamic> value) => LendingLibrary(
    id: value['id'] as String,
    provider: LendingProvider.values.byName(value['provider'] as String),
    name: value['name'] as String,
    home: value['home'] as String,
  );
}

class LendingBook {
  const LendingBook({
    required this.id,
    required this.title,
    this.author = '',
    this.cover,
    this.page,
    this.purchaseLink,
    this.price,
    this.currency,
    this.identifiers = const {},
    this.data = const {},
  });
  final String id, title, author;
  final Uri? cover, page, purchaseLink;
  final double? price;
  final String? currency;
  final Map<String, String> identifiers;
  final Map<String, dynamic> data;
}

class LendingPage {
  const LendingPage(this.books, {this.more = false});
  final List<LendingBook> books;
  final bool more;
}

class LendingService {
  LendingService(
    this.repository,
    this.profile, {
    required this.valid,
    SourceTransport? transport,
    Future<bool> Function(Uri)? launch,
  }) : transport = transport ?? SourceTransport(),
       launch = launch ?? ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));
  final SourceRepository repository;
  final String profile;
  final bool Function() valid;
  final SourceTransport transport;
  final Future<bool> Function(Uri) launch;
  static DateTime _lastSearch = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastGoogleBooksSearch = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  void check() {
    if (_closed || !valid()) throw const SourceException(SourceFailure.cancelled);
  }

  Future<List<LendingLibrary>> libraries() async {
    check();
    final data = await repository.preference(profile, 'lending:libraries');
    check();
    return sourceList(data['libraries'])
        .map(sourceMap)
        .where((entry) => LendingProvider.values.any((provider) => provider.name == entry['provider']))
        .map(LendingLibrary.fromJson)
        .toList();
  }

  Future<void> save(LendingLibrary library) async {
    lendingHttps(library.home);
    final items = await libraries();
    check();
    await repository.savePreference(profile, 'lending:libraries', {
      'libraries': [...items.where((l) => l.id != library.id).map((l) => l.toJson()), library.toJson()],
    });
  }

  Future<void> remove(LendingLibrary library) async {
    final items = await libraries();
    check();
    await repository.savePreference(profile, 'lending:libraries', {
      'libraries': items.where((l) => l.id != library.id).map((l) => l.toJson()).toList(),
    });
  }

  Future<void> openPage(Uri uri) async {
    check();
    lendingHttps(uri.toString());
    if (!await launch(uri)) throw const SourceException(SourceFailure.unavailable);
  }

  Future<LendingPage> openLibrarySearch(String query, {int page = 1}) async {
    check();
    // Open Library's public API requests must be at least a second apart.
    final now = DateTime.now();
    final next = _lastSearch.add(const Duration(milliseconds: 1100));
    _lastSearch = next.isAfter(now) ? next : now;
    final delay = _lastSearch.difference(now);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    check();
    final result = await transport.json(
      'GET',
      Uri.https('openlibrary.org', '/search.json', {
        'q': query,
        'page': '$page',
        'limit': '30',
        'fields': 'key,title,author_name,cover_i,isbn',
      }),
      headers: const {'User-Agent': 'Pleazyng (https://github.com/snapetech-org/pleazyng)'},
    );
    check();
    final books = sourceList(result['docs'])
        .map(sourceMap)
        .where((b) => RegExp(r'^/works/OL\d+W$').hasMatch('${b['key']}'))
        .map((b) {
          final cover = sourceInt(b['cover_i']);
          return LendingBook(
            id: b['key'] as String,
            title: b['title'] as String? ?? '',
            author: sourceList(b['author_name']).join(', '),
            cover: cover == null ? null : Uri.https('covers.openlibrary.org', '/b/id/$cover-M.jpg'),
            page: Uri.https('openlibrary.org', b['key'] as String),
            identifiers: BookIdentifiers.fromValues(b['isbn']),
          );
        })
        .toList();
    return LendingPage(books, more: page * 30 < (sourceInt(result['numFound']) ?? 0));
  }

  /// Public Google Books catalog search, including country-specific sale
  /// metadata when Google supplies it. Search results are unauthenticated;
  /// only Google's own purchase URL is exposed as a checkout handoff.
  Future<LendingPage> googleBooksSearch(String query, {int page = 1, String country = 'CA'}) async {
    check();
    final normalizedCountry = RegExp(r'^[A-Za-z]{2}$').hasMatch(country) ? country.toUpperCase() : 'CA';
    final now = DateTime.now();
    final next = _lastGoogleBooksSearch.add(const Duration(milliseconds: 300));
    _lastGoogleBooksSearch = next.isAfter(now) ? next : now;
    final delay = _lastGoogleBooksSearch.difference(now);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    check();
    const pageSize = 20;
    final result = await transport.json(
      'GET',
      Uri.https('www.googleapis.com', '/books/v1/volumes', {
        'q': query,
        'country': normalizedCountry,
        'printType': 'books',
        'projection': 'lite',
        'maxResults': '$pageSize',
        'startIndex': '${(page - 1).clamp(0, 10000) * pageSize}',
      }),
    );
    check();
    final books = <LendingBook>[];
    for (final raw in sourceList(result['items'])) {
      final volume = sourceMap(raw);
      final id = volume['id'];
      if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) continue;
      final info = sourceMap(volume['volumeInfo']);
      final title = info['title'];
      if (title is! String || title.trim().isEmpty) continue;
      final sale = sourceMap(volume['saleInfo']);
      final buyLink = _googleBooksLink(sale['buyLink']);
      final saleability = sale['saleability'];
      final priceData = sourceMap(sale['retailPrice']);
      final rawAmount = priceData['amount'];
      final amount = rawAmount is num ? rawAmount.toDouble() : null;
      final currencyCode = priceData['currencyCode'];
      final forSale = saleability == 'FOR_SALE' || saleability == 'FOR_PREORDER';
      final thumbnails = sourceMap(info['imageLinks']);
      final cover = _googleBooksLink(thumbnails['thumbnail']);
      final pageLink = _googleBooksLink(info['infoLink']) ?? Uri.https('books.google.com', '/books', {'id': id});
      books.add(
        LendingBook(
          id: 'google-books:$id',
          title: title.trim(),
          author: sourceList(info['authors']).whereType<String>().join(', '),
          cover: cover,
          page: pageLink,
          purchaseLink: forSale ? buyLink : null,
          price: forSale && buyLink != null && amount != null && amount >= 0 ? amount : null,
          currency: currencyCode is String && RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode) ? currencyCode : null,
          identifiers: BookIdentifiers.fromValues(info['industryIdentifiers']),
          data: {'source': 'googleBooks', if (saleability is String) 'saleability': saleability},
        ),
      );
    }
    final total = sourceInt(result['totalItems']) ?? 0;
    return LendingPage(books, more: page * pageSize < total);
  }

  static Uri? _googleBooksLink(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.host.toLowerCase() != 'books.google.com' ||
        !uri.path.startsWith('/books') ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return uri.replace(scheme: 'https');
  }

  void close() {
    _closed = true;
    transport.close();
  }
}
