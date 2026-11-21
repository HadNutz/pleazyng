import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/ast/token.dart';

const rollout = 'docs/maintainers/dart-source-baseline.json';
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
  Map<String, dynamic>? rolloutSizes;
  // The initial integration brings in source from several parents. Its checked-in
  // rollout records the post-migration starting point. Later branches use their base.
  if (Process.runSync('git', ['cat-file', '-e', '$base:$rollout']).exitCode != 0) {
    final bootstrap = git(['log', '--first-parent', '--diff-filter=A', '--format=%H', 'HEAD', '--', rollout]).trim();
    if (bootstrap.isNotEmpty) {
      base = bootstrap.split('\n').last;
      final snapshot = jsonDecode(git(['show', '$base:$rollout'])) as Map<String, dynamic>;
      rolloutSizes = snapshot['lineCounts'] as Map<String, dynamic>;
    }
  }
  final delta = git(['diff', '--name-status', '--find-renames=80%', '-z', base, '--', 'lib']).split('\x00');
  var failures = 0;
  final previousCatches = <String, int>{};
  final currentCatches = <String, List<String>>{};
  for (var i = 0; i < delta.length - 1;) {
    final status = delta[i++];
    final oldPath = delta[i++];
    final path = status.startsWith('R') ? delta[i++] : oldPath;
    final hadSource = status != 'A' && maintained(oldPath);
    final previous = hadSource ? git(['show', '$base:$oldPath']) : '';
    if (hadSource) {
      for (final entry in catches(previous).entries) {
        previousCatches.update(entry.key, (n) => n + entry.value, ifAbsent: () => entry.value);
      }
    }
    if (status == 'D' || !maintained(path)) continue;
    final text = File(path).readAsStringSync();
    final initialLimit = rolloutSizes?[oldPath] as int?;
    final limit = hadSource ? initialLimit ?? const LineSplitter().convert(previous).length : 1500;
    final lines = const LineSplitter().convert(text).length;
    if (lines > limit) {
      stderr.writeln('$path has $lines lines (limit $limit).');
      failures++;
    }
    for (final entry in catches(text).entries) {
      currentCatches.putIfAbsent(entry.key, () => []).addAll(List.filled(entry.value, path));
    }
  }
  // Extracting an unchanged handler into a part preserves its existing review.
  // Count occurrences to distinguish a move from a new copy of the same code.
  for (final entry in currentCatches.entries) {
    if (entry.value.length > (previousCatches[entry.key] ?? 0)) {
      final fields = jsonDecode(entry.key) as List;
      stderr.writeln(
        '${entry.value.toSet().join(', ')}: new undocumented catch (_) in ${fields.first}. '
        'Explain the fallback inside the catch.',
      );
      failures++;
    }
  }
  exitCode = failures == 0 ? 0 : 1;
}
