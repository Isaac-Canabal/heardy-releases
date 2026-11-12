import 'download_source.dart';

List<RemoteTrack> exploreQueueFrom(
  List<RemoteTrack> shelf,
  int index, {
  RemoteTrack Function(RemoteTrack)? transform,
}) {
  if (index < 0 || index >= shelf.length) return const [];
  final slice = shelf.sublist(index);
  return transform == null ? slice : [for (final t in slice) transform(t)];
}
