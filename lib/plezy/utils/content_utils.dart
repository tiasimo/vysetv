import 'package:flutter/material.dart';

class ContentTypes {
  ContentTypes._();

  static const String movie = 'movie';
  static const String show = 'show';
  static const String season = 'season';
  static const String episode = 'episode';
  static const String artist = 'artist';
  static const String album = 'album';
  static const String track = 'track';
  static const String collection = 'collection';
  static const String playlist = 'playlist';
  static const String clip = 'clip';

  static const Set<String> musicTypes = {artist, album, track};
  static const Set<String> videoTypes = {movie, show, season, episode};
}

class ContentTypeHelper {
  ContentTypeHelper._();

  static bool isMusicContent(String type) => ContentTypes.musicTypes.contains(type.toLowerCase());

  static bool isVideoContent(String type) => ContentTypes.videoTypes.contains(type.toLowerCase());

  static IconData getLibraryIcon(String type) {
    switch (type.toLowerCase()) {
      case ContentTypes.movie:
        return Icons.movie_rounded;
      case ContentTypes.show:
        return Icons.tv_rounded;
      case ContentTypes.artist:
        return Icons.music_note_rounded;
      case 'photo':
        return Icons.photo_rounded;
      case 'mixed':
        return Icons.share_rounded;
      default:
        return Icons.folder_rounded;
    }
  }
}

/// Utility function to format content ratings by removing country prefixes
String formatContentRating(String? contentRating) {
  if (contentRating == null || contentRating.isEmpty) {
    return '';
  }

  final regex = RegExp(r'^[a-z]{2,3}/(.+)$', caseSensitive: false);
  final match = regex.firstMatch(contentRating);

  if (match != null && match.groupCount >= 1) {
    return match.group(1) ?? contentRating;
  }

  return contentRating;
}
