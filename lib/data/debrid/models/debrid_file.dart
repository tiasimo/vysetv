// Ported from PlayTorrio (GPL-3.0), lib/services/debrid.
class DebridFile {
  final String filename;
  final int filesize;
  final String downloadUrl;

  DebridFile({
    required this.filename,
    required this.filesize,
    required this.downloadUrl,
  });
}
