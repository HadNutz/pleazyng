part of '../iptv_source_repository.dart';

class _StoredIptvSource {
  const _StoredIptvSource({
    required this.id,
    required this.profileId,
    required this.displayName,
    required this.kind,
    required this.revision,
    required this.generation,
    required this.createdAt,
    this.lastSuccessAt,
    this.lastErrorCode,
  });

  final String id;
  final String profileId;
  final String displayName;
  final String kind;
  final int revision;
  final int generation;
  final int createdAt;
  final int? lastSuccessAt;
  final String? lastErrorCode;
}
