class MangaChapter {
  final String id;
  final double? number;
  final String? name;
  final String url;
  final String rawName;

  const MangaChapter({
    required this.id,
    this.number,
    this.name,
    required this.url,
    required this.rawName,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'name': name,
        'url': url,
        'rawName': rawName,
      };

  factory MangaChapter.fromJson(Map<String, dynamic> json) => MangaChapter(
        id: json['id'] as String? ?? '',
        number: (json['number'] as num?)?.toDouble(),
        name: json['name'] as String?,
        url: json['url'] as String? ?? '',
        rawName: json['rawName'] as String? ?? '',
      );

  factory MangaChapter.fromRaw(String id, String rawName, String url) {
    double? number;
    String? name;

    final numMatch = RegExp(r'Chapter\s+([\d.]+)', caseSensitive: false).firstMatch(rawName);
    if (numMatch != null) {
      number = double.tryParse(numMatch.group(1)!);
    }

    final nameMatch = RegExp(r'Chapter\s+[\d.]+\s*[-:]\s*(.+)', caseSensitive: false).firstMatch(rawName);
    if (nameMatch != null) {
      name = nameMatch.group(1)!.trim();
      if (name.isEmpty) name = null;
    }

    return MangaChapter(
      id: id,
      number: number,
      name: name,
      url: url,
      rawName: rawName,
    );
  }
}
