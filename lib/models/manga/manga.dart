class Manga {
  final String id;
  final String title;
  final String? coverSmall;
  final String? coverNormal;
  final String? type;
  final String? status;
  final String? year;
  final String? author;
  final List<String> tags;
  final String? synopsis;
  final String url;

  const Manga({
    required this.id,
    required this.title,
    this.coverSmall,
    this.coverNormal,
    this.type,
    this.status,
    this.year,
    this.author,
    this.tags = const [],
    this.synopsis,
    required this.url,
  });

  factory Manga.fromJson(Map<String, dynamic> json) {
    return Manga(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      coverSmall: json['coverSmall'] as String?,
      coverNormal: json['coverNormal'] as String?,
      type: json['type'] as String?,
      status: json['status'] as String?,
      year: json['year'] as String?,
      author: json['author'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      synopsis: json['synopsis'] as String?,
      url: json['url'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'coverSmall': coverSmall,
      'coverNormal': coverNormal,
      'type': type,
      'status': status,
      'year': year,
      'author': author,
      'tags': tags,
      'synopsis': synopsis,
      'url': url,
    };
  }
}
