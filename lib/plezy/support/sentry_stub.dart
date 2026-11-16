// Lorewatch stand-in for package:sentry_flutter: Plezy reports a couple of events to
// its own crash tracker; Lorewatch has none, so these do nothing.

class Breadcrumb {
  Breadcrumb({this.message, this.category, this.data, this.level});
  final String? message;
  final String? category;
  final Map<String, dynamic>? data;
  final Object? level;
}

abstract final class Sentry {
  static Future<void> addBreadcrumb(Breadcrumb crumb, {Object? hint}) async {}

  static Future<void> captureException(Object? exception, {Object? stackTrace, Object? hint, Object? withScope}) async {}
}
