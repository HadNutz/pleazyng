import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/playlist_items_loader.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

void main() {
  for (final behavior in ['complete', 'empty', 'repeated']) {
    test('collection enumeration with a short $behavior page', () async {
      final requested = <int>[];
      final client = testJellyfinClient(
        handler: (request) async {
          final start = int.parse(request.url.queryParameters['StartIndex']!);
          requested.add(start);
          final offset = behavior == 'repeated' ? 0 : start;
          return jsonResponse({
            'Items': [
              if (behavior != 'empty' || start == 0)
                for (var i = offset; i < offset + 25 && i < 75; i++)
                  {'Id': 'item-$i', 'Type': 'Movie', 'Name': 'Movie $i'},
            ],
            'TotalRecordCount': 75,
          });
        },
      );
      addTearDown(client.close);
      final result = fetchAllCollectionItemsPaged(client, 'collection');
      if (behavior == 'complete') {
        expect((await result).map((item) => item.id), [for (var i = 0; i < 75; i++) 'item-$i']);
        expect(requested, [0, 25, 50]);
      } else {
        await expectLater(result, throwsFormatException);
        expect(requested, [0, 25]);
      }
    });
  }
}
