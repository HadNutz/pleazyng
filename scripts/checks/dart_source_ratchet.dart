import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/ast/token.dart';

const script = 'scripts/checks/dart_source_ratchet.dart';
const generatedTables = {'lib/data/ducet_order.dart', 'lib/data/hid_key_labels.dart', 'lib/data/iso_639_data.dart'};

bool maintained(String path) =>
    path.startsWith('lib/') &&
    path.endsWith('.dart') &&
    !path.endsWith('.g.dart') &&
    !path.endsWith('.freezed.dart') &&
    !generatedTables.contains(path);

class WildcardCatches extends RecursiveAstVisitor<void> {
  final counts = <String, int>{};

  @override
  void visitCatchClause(CatchClause node) {
    if (node.exceptionParameter?.name.lexeme == '_') {
      final token = node.body.rightBracket;
      final start = node.catchKeyword!.offset;
      final parent = node.parent;
      final owner =
          node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme ??
          node.thisOrAncestorOfType<FunctionDeclaration>()?.name.lexeme ??
          '';
      // Walk actual comment tokens. A string containing "//" is not a rationale.
      var documented = false;
      var current = node.beginToken;
      while (true) {
        Token? comment = current.precedingComments;
        while (comment != null) {
          if (comment.offset >= start && RegExp(r'[\p{L}]{3}', unicode: true).hasMatch(comment.lexeme)) {
            documented = true;
          }
          comment = comment.next;
        }
        if (current == token) break;
        final next = current.next;
        if (next == null) break;
        current = next;
      }
      if (!documented) {
        final signature = jsonEncode([owner, if (parent is TryStatement) parent.body.toSource(), node.toSource()]);
        counts.update(signature, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    super.visitCatchClause(node);
  }
}

Map<String, int> catches(String text) {
  final visitor = WildcardCatches();
  parseString(content: text, throwIfDiagnostics: false).unit.accept(visitor);
  return visitor.counts;
}

String git(List<String> args) {
  final result = Process.runSync('git', args);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
  return result.stdout as String;
}

void main(List<String> args) {
  if (args.length != 1) throw ArgumentError('Expected the comparison commit');
  var base = git(['merge-base', 'HEAD', args.single]).trim();
  // The first rollout also contains upstream ports. Count changes from the
  // commit that installed this policy when reviewing that initial rollout.
  if (Process.runSync('git', ['cat-file', '-e', '$base:$script']).exitCode != 0) {
    final bootstrap = git(['log', '--first-parent', '--diff-filter=A', '--format=%H', 'HEAD', '--', script]).trim();
    if (bootstrap.isNotEmpty) base = bootstrap.split('\n').last;
  }
  final delta = git(['diff', '--name-status', '--find-renames=80%', '-z', base, '--', 'lib']).split('\x00');
  var failures = 0;
  for (var i = 0; i < delta.length - 1;) {
    final status = delta[i++];
    final oldPath = delta[i++];
    final path = status.startsWith('R') ? delta[i++] : oldPath;
    if (status == 'D' || !maintained(path)) continue;
    final text = File(path).readAsStringSync();
    final previous = status == 'A' ? '' : git(['show', '$base:$oldPath']);
    final limit = status == 'A' ? 1500 : const LineSplitter().convert(previous).length;
    final lines = const LineSplitter().convert(text).length;
    if (lines > limit) {
      stderr.writeln('$path has $lines lines (limit $limit).');
      failures++;
    }
    final old = catches(previous);
    for (final entry in catches(text).entries) {
      if (entry.value > (old[entry.key] ?? 0)) {
        final fields = jsonDecode(entry.key) as List;
        stderr.writeln('$path: new undocumented catch (_) in ${fields.first}. Explain the fallback inside the catch.');
        failures++;
      }
    }
  }
  exitCode = failures == 0 ? 0 : 1;
}
