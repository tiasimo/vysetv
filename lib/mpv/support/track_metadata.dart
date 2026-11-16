// The two track-title helpers the copied player uses, lifted from Plezy's
// `utils/track_label_builder.dart` (GPL-3.0, edde746/plezy) without the rest
// of that file, which pulls in Plezy's translations and language tables.

String? cleanTrackMetadataValue(String? value) {
  if (value == null) return null;
  var cleaned = value.trim();
  if (cleaned.isEmpty) return null;

  final prefixed = RegExp(r'^(?:title|lang|language)\s*=\s*(.*)$', caseSensitive: false).firstMatch(cleaned);
  if (prefixed != null) {
    cleaned = prefixed.group(1)?.trim() ?? '';
  }

  if ((cleaned.startsWith('"') && cleaned.endsWith('"')) || (cleaned.startsWith("'") && cleaned.endsWith("'"))) {
    cleaned = cleaned.substring(1, cleaned.length - 1).trim();
  }

  return cleaned.isEmpty ? null : cleaned;
}

String? cleanSubtitleTitle(String? title, {String? codec}) {
  var cleaned = cleanTrackMetadataValue(title);
  if (cleaned == null) return null;

  final codecAliases = _subtitleCodecAliases(codec);
  if (codecAliases.isEmpty) return cleaned;

  final parts = cleaned.split(RegExp(r'\s+-\s+'));
  while (parts.isNotEmpty && codecAliases.contains(_metadataToken(parts.last))) {
    parts.removeLast();
  }
  cleaned = parts.join(' - ').trim();

  return cleaned.isEmpty ? null : cleaned;
}

Set<String> _subtitleCodecAliases(String? codec) {
  final aliases = <String>{
    'SUBRIP',
    'SRT',
    'WEBVTT',
    'VTT',
    'ASS',
    'SSA',
    'PGS',
    'PGSSUB',
    'HDMV_PGS_SUBTITLE',
    'DVD',
    'DVDSUB',
    'DVD_SUBTITLE',
    'DVB_SUB',
    'DVB_SUBTITLE',
  };
  if (codec != null && codec.isNotEmpty) {
    aliases.add(_metadataToken(codec));
    aliases.add(_metadataToken(_formatSubtitleCodec(codec)));
    aliases.add(_metadataToken(_subtitleExtension(codec)));
  }
  return aliases;
}

String _metadataToken(String value) => value.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_');

String _formatSubtitleCodec(String codec) => switch (codec.toUpperCase()) {
  'SUBRIP' => 'SRT',
  'DVD_SUBTITLE' => 'DVD',
  'WEBVTT' => 'VTT',
  'HDMV_PGS_SUBTITLE' => 'PGS',
  'MOV_TEXT' => 'MOV',
  final upper => upper,
};

String _subtitleExtension(String codec) => switch (codec.toLowerCase()) {
  'subrip' || 'srt' || 'mov_text' => 'srt',
  'ass' || 'ssa' => 'ass',
  'webvtt' || 'vtt' => 'vtt',
  'pgs' || 'pgssub' || 'hdmv_pgs_subtitle' => 'sup',
  'dvd_subtitle' || 'dvdsub' => 'sub',
  _ => 'srt',
};
