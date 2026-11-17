const _months = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'];

/// Oct 9, 2026
String fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// 1h 36m, or "45m / ep" for series.
String fmtRuntime(int minutes, {bool perEpisode = false}) {
  final h = minutes ~/ 60, m = minutes % 60;
  final s = h == 0 ? '${m}m' : (m == 0 ? '${h}h' : '${h}h ${m}m');
  return perEpisode ? '$s / ep' : s;
}

/// 1.2M, 34K, 950
String fmtCompact(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(1)}M'
    : n >= 1000
        ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K'
        : '$n';

String fmtMoney(int n) => '\$${fmtCompact(n)}';

/// 40,002
String fmtThousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
