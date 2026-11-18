import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../karaoke/karaoke_room_server.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/library_query.dart';
import '../../media/media_server_client.dart';
import 'music_playback_service.dart';

/// Browsers receive short-lived opaque choices scoped to one host-selected
/// music library. Only the host holds server credentials and playback controls.
class GuestJukebox extends ChangeNotifier {
  GuestJukebox(this._music, this._clientFor);
  final MusicPlaybackService _music;
  final MediaServerClient? Function(MediaLibrary) _clientFor;
  final _random = Random.secure();
  final _choices = <String, MediaItem>{};
  HttpServer? _server;
  int _epoch = 0;
  int _revision = -1;
  int _inflight = 0;
  String _secret = '';
  bool _disposed = false;
  MediaLibrary? library;
  Uri? get link => _server == null
      ? null
      : Uri(scheme: 'http', host: _server!.address.address, port: _server!.port, fragment: _secret);

  String _token() => base64UrlEncode(List.generate(24, (_) => _random.nextInt(256))).replaceAll('=', '');

  Future<void> open(MediaLibrary selected, {String? address}) async {
    close();
    final epoch = _epoch;
    final revision = _music.queueSessionRevision;
    if (!selected.kind.isMusic || _music.currentTrack == null || _clientFor(selected) == null) {
      throw StateError('Unavailable library');
    }
    final addresses = address == '127.0.0.1' ? const ['127.0.0.1'] : await KaraokeRoomServer.addresses();
    final bind = address ?? addresses.firstOrNull;
    if (bind == null || (!addresses.contains(bind) && bind != '127.0.0.1')) throw StateError('No local network');
    final server = await HttpServer.bind(InternetAddress(bind), 0, backlog: 12);
    if (epoch != _epoch || _disposed || _music.queueSessionRevision != revision || _clientFor(selected) == null) {
      await server.close(force: true);
      return;
    }
    server.idleTimeout = const Duration(seconds: 15);
    _server = server;
    _revision = revision;
    _secret = _token();
    library = selected;
    _music.addListener(_sessionChanged);
    server.listen(
      (request) => unawaited(_serve(request, epoch)),
      onError: (Object _) {
        if (epoch == _epoch) close();
      },
    );
    notifyListeners();
  }

  void _sessionChanged() {
    if (_music.currentTrack == null || _music.queueSessionRevision != _revision) close();
  }

  void close() {
    _epoch++;
    final server = _server;
    _server = null;
    _secret = '';
    library = null;
    _choices.clear();
    if (server != null) {
      _music.removeListener(_sessionChanged);
      unawaited(server.close(force: true));
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }

  Future<void> _serve(HttpRequest request, int epoch) async {
    final out = request.response;
    _inflight++;
    try {
      final host = link;
      if (epoch != _epoch || host == null || request.headers.value('host') != host.authority) {
        out.statusCode = 403;
        return;
      }
      out.headers.set('Cache-Control', 'no-store');
      out.headers.set('Referrer-Policy', 'no-referrer');
      out.headers.set('X-Content-Type-Options', 'nosniff');
      if (request.uri.path == '/' && request.method == 'GET') {
        out.headers.contentType = ContentType.html;
        out.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; form-action 'none'",
        );
        out.write(_page());
        return;
      }
      if (request.uri.path == '/room.js' && request.method == 'GET') {
        out.headers.contentType = ContentType('application', 'javascript', charset: 'utf-8');
        out.write(_guestScript);
        return;
      }
      final origin = request.headers.value('origin');
      if (request.headers.value('X-Room') != _secret || (origin != null && origin != host.origin)) {
        out.statusCode = 403;
        return;
      }
      if (_inflight > 8) {
        out.statusCode = 429;
        return;
      }
      final selected = library!;
      final client = _clientFor(selected);
      if (client == null || _music.queueSessionRevision != _revision) {
        out.statusCode = 410;
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/queue') {
        final start = (_music.currentIndex + 1).clamp(0, _music.queue.length);
        out.headers.contentType = ContentType.json;
        out.write(
          jsonEncode([
            for (final item in _music.queue.skip(start).take(50))
              if (item.backend == selected.backend &&
                  item.serverId == selected.serverId &&
                  item.libraryId == selected.id)
                {'title': item.displayTitle, 'artist': item.trackArtistTitle ?? ''},
          ]),
        );
      } else if (request.method == 'GET' && request.uri.path == '/songs') {
        final search = request.uri.queryParameters['q']?.trim() ?? '';
        if (search.length < 2 || search.length > 100) {
          out.statusCode = 400;
          return;
        }
        final page = await client
            .fetchLibraryPagedContent(
              selected.id,
              query: LibraryQuery(kind: MediaKind.track, search: search, limit: 30),
              libraryKind: selected.kind,
            )
            .timeout(const Duration(seconds: 8));
        if (_epoch != epoch || _clientFor(selected) != client) {
          out.statusCode = 410;
          return;
        }
        final rows = <Map<String, String>>[];
        for (final track in page.items.take(30)) {
          if (track.kind != MediaKind.track ||
              (track.libraryId != null && track.libraryId != selected.id) ||
              (track.serverId != null && track.serverId != selected.serverId)) {
            continue;
          }
          final key = _token();
          if (_choices.length >= 1024) _choices.remove(_choices.keys.first);
          _choices[key] = track.copyWith(serverId: selected.serverId, libraryId: selected.id);
          rows.add({'id': key, 'title': track.displayTitle, 'artist': track.trackArtistTitle ?? ''});
        }
        out.headers.contentType = ContentType.json;
        out.write(jsonEncode(rows));
      } else if (request.method == 'POST' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'add') {
        final track = _choices.remove(request.uri.pathSegments.last);
        if (track == null) {
          out.statusCode = 410;
          return;
        }
        final accepted = await _music.acceptGuestTrack(track);
        if (!accepted || epoch != _epoch) {
          out.statusCode = 409;
          return;
        }
        out.headers.contentType = ContentType.json;
        out.write(jsonEncode({'accepted': true, 'title': track.displayTitle}));
      } else {
        out.statusCode = 404;
      }
    } catch (_) {
      out.statusCode = 503;
    } finally {
      _inflight--;
      try {
        await out.close();
      } on IOException {
        /* Guest left. */
      }
    }
  }

  String _page() {
    final s = t.livingRoom;
    final escape = const HtmlEscape().convert;
    return '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta charset="utf-8"><title>${escape(s.jukebox)}</title>
<style>html{color-scheme:dark}body{max-width:36rem;margin:2rem auto;padding:0 1rem;font:1.05rem system-ui;background:#151717;color:#fafafa}input,button{font:inherit;padding:.7rem;border-radius:.4rem}input{width:65%}ul{padding:0}li{display:flex;align-items:center;justify-content:space-between;gap:1rem;border-bottom:1px solid #555;padding:.6rem 0}button{cursor:pointer}</style></head>
<body data-error="${escape(s.roomUnavailable)}" data-added="${escape(s.added)}" data-empty="${escape(s.noSongs)}" data-add="${escape(t.music.addToQueue)}">
<h1>${escape(s.jukebox)}</h1><form><label for="q">${escape(s.searchSongs)}</label><br><input id="q" required minlength="2" maxlength="100"><button>${escape(t.common.search)}</button></form>
<p role="status"></p><ul></ul><h2>${escape(t.music.upNext)}</h2><ol></ol><script src="/room.js"></script></body></html>''';
  }
}

const _guestScript = r'''
const token=location.hash.slice(1);
const headers={'X-Room':token};
const words=document.body.dataset;
const form=document.querySelector('form'), list=document.querySelector('ul'), statusText=document.querySelector('[role=status]');
let sequence=0, reading=false;
async function queue(){
  if(reading || document.hidden) return;
  reading=true;
  try {
    const response=await fetch('/queue',{headers});
    if(!response.ok) throw Error();
    const rows=await response.json();
    document.querySelector('ol').replaceChildren(...rows.map(song=>{
      const row=document.createElement('li'); row.textContent=[song.title,song.artist].filter(Boolean).join(' · '); return row;
    }));
  } catch { document.querySelector('ol').replaceChildren(); statusText.textContent=words.error; }
  finally { reading=false; }
}
queue(); setInterval(queue,10000); document.addEventListener('visibilitychange',queue);
form.onsubmit=async function(event){
  event.preventDefault();
  const current=++sequence;
  list.replaceChildren(); statusText.textContent='';
  try {
    const response=await fetch('/songs?q='+encodeURIComponent(document.querySelector('#q').value.trim()),{headers});
    if(!response.ok) throw Error();
    const songs=await response.json();
    if(sequence!==current) return;
    if(!songs.length) statusText.textContent=words.empty;
    for(const song of songs){
      const row=document.createElement('li'), name=document.createElement('span'), add=document.createElement('button');
      name.textContent=[song.title,song.artist].filter(Boolean).join(' · ');
      add.textContent=words.add;
      add.onclick=async function(){
        add.disabled=true;
        try {
          const result=await fetch('/add/'+encodeURIComponent(song.id),{method:'POST',headers});
          if(!result.ok || !(await result.json()).accepted) throw Error();
          queue();
          add.textContent=words.added; statusText.textContent=song.title+' · '+words.added;
        } catch {statusText.textContent=words.error;}
      };
      row.append(name,add); list.append(row);
    }
  } catch {if(sequence===current) statusText.textContent=words.error;}
};
''';
