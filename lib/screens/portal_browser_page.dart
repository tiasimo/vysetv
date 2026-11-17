import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/accent.dart';
import '../core/format.dart';
import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/live_favorites.dart';
import '../data/live_guide.dart';
import '../data/live_tv.dart';
import '../models/iptv/iptv_models.dart';
import '../services/iptv/iptv_controller.dart';
import '../widgets/common.dart';
import '../widgets/live_tv_widgets.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'live_tv_pages.dart' show SeriesPage;
import 'live_tv_player_page.dart';
import 'portal_browser_player.dart';

enum _Sort { portal, az, za }

/// Stands in for a category id: the Favorites entry isn't one of the portal's categories.
const _favId = '\u0000favorites';

typedef _Cat = ({String id, String name, int count, IconData? icon});

bool get _touchDevice => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// One portal, browsed the way a TV guide reads: categories, the channels in the open one with
/// what's on now, and the picture.
///
/// Wide windows show all three side by side and play the channel in the right pane. Tablets show
/// categories and channels, and open the full player. Phones take it a step at a time:
/// categories, then channels, with Back stepping out again. Movies and series keep their poster
/// grid in place of the channel list.
class PortalBrowserPage extends StatefulWidget {
  const PortalBrowserPage({super.key, required this.portal, this.controller});
  final VerifiedPortal portal;

  /// Where the portal's lists come from. The app leaves this to the IPTV controller; the layout
  /// test hands in a made-up portal.
  final IptvController? controller;

  @override
  State<PortalBrowserPage> createState() => _PortalBrowserPageState();
}

class _PortalBrowserPageState extends State<PortalBrowserPage> {
  final _catScroll = ScrollController();
  final _listScroll = ScrollController();
  final _gridScroll = ScrollController();
  final _text = TextEditingController(); // within the open category
  final _catText = TextEditingController(); // the category list
  final _alive = AliveChecker();
  final _playerKey = GlobalKey();
  Timer? _debounce;

  IptvSection _section = IptvSection.live;
  bool _workingOnly = false;
  bool _favorites = false; // the Favorites entry is open
  bool _catAz = false;
  _Sort _sort = _Sort.portal;

  // Short screens keep each search box behind its icon.
  bool _catSearch = false;
  bool _listSearch = false;

  /// The channel in the player pane.
  IptvStream? _watching;
  bool _expanded = false;
  LocalHistoryEntry? _expandEntry;

  /// Phones: past the category list. Back (the system's too) steps out through [_stepEntry].
  bool _channelsStep = false;
  LocalHistoryEntry? _stepEntry;
  bool _keepStep = false;
  bool _wasPhone = false;

  double _rowExtent = 74;

  // Everything derived from the portal's lists is worked out once per change, not per frame.
  int _dataTick = 0;
  Object? _listSig;
  List<IptvStream> _listMemo = const [];
  Object? _countSig;
  Map<String, int> _counts = const {};
  Map<String, String> _catNames = const {};
  int _favCount = 0;

  late final IptvController _data = widget.controller ?? iptv;

  VerifiedPortal get _portal => widget.portal;
  bool get _live => _section == IptvSection.live;

  @override
  void initState() {
    super.initState();
    _data.addListener(_dataChanged);
    _text.addListener(_searchChanged);
    _catText.addListener(_rebuild);
    liveGuide.addWatcher();
    LiveFavorites.load();
    _open(_section);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Turning a phone changes how Back works: the step only exists in the one-pane layout.
    final phone = _stepped(context);
    if (phone == _wasPhone) return;
    _wasPhone = phone;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_stepped(context)) {
        if (_channelsStep) _addStepEntry();
      } else {
        _dropStepEntry();
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _data.removeListener(_dataChanged);
    liveGuide.removeWatcher();
    _alive.dispose();
    _catScroll.dispose();
    _listScroll.dispose();
    _gridScroll.dispose();
    _text.dispose();
    _catText.dispose();
    if (_expanded) {
      if (isDesktopNative) unawaited(windowManager.setFullScreen(false));
      // after this frame: the tree is locked while pages are being taken down
      WidgetsBinding.instance.addPostFrameCallback((_) => fullWindow.value--);
    }
    super.dispose();
  }

  void _dataChanged() => _dataTick++;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _searchChanged() {
    _rebuild(); // the list narrows as you type; the controller hears a moment later
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _data.setBrowserSearch(_text.text.trim()));
  }

  // ───────────────────────── State changes ─────────────────────────

  void _open(IptvSection s) {
    _collapse();
    _dropStepEntry();
    setState(() {
      _section = s;
      _workingOnly = false;
      _favorites = false;
      _channelsStep = false;
      _listSearch = false;
      if (s != IptvSection.live) _watching = null;
    });
    _text.clear();
    _alive.stop();
    _data.openSection(_portal, s);
    for (final c in [_catScroll, _listScroll, _gridScroll]) {
      if (c.hasClients) c.jumpTo(0);
    }
  }

  void _resetList() {
    if (_text.text.isNotEmpty) _text.clear();
    _listSearch = false;
    for (final c in [_listScroll, _gridScroll]) {
      if (c.hasClients) c.jumpTo(0);
    }
  }

  void _pickCategory(String id) {
    _resetList();
    _favorites = false;
    _data.selectBrowserCategory(id);
    setState(_enterChannels);
  }

  void _pickFavorites() {
    _resetList();
    setState(() {
      _favorites = true;
      _enterChannels();
    });
  }

  void _enterChannels() {
    _channelsStep = true;
    if (_stepped(context)) _addStepEntry();
  }

  void _addStepEntry() {
    if (_stepEntry != null) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    final entry = LocalHistoryEntry(onRemove: () {
      _stepEntry = null;
      if (mounted && !_keepStep) setState(() => _channelsStep = false);
    });
    route.addLocalHistoryEntry(entry);
    _stepEntry = entry;
  }

  /// Forgets the Back step without leaving the channel list (the layout has room for both now).
  void _dropStepEntry() {
    final entry = _stepEntry;
    if (entry == null) return;
    _keepStep = true;
    entry.remove();
    _keepStep = false;
  }

  void _backToCategories() {
    final entry = _stepEntry;
    if (entry != null) {
      entry.remove();
    } else {
      setState(() => _channelsStep = false);
    }
  }

  /// The player takes the whole window (and the screen, on a computer), like a room's theater.
  void _expand() {
    if (_expanded || _watching == null) return;
    setState(() => _expanded = true);
    fullWindow.value++;
    if (isDesktopNative) unawaited(windowManager.setFullScreen(true));
    final route = ModalRoute.of(context);
    if (route != null) {
      final entry = LocalHistoryEntry(onRemove: () {
        _expandEntry = null;
        _collapse();
      });
      route.addLocalHistoryEntry(entry);
      _expandEntry = entry;
    }
  }

  void _collapse() {
    final entry = _expandEntry;
    if (entry != null) {
      entry.remove(); // comes back here through onRemove
      return;
    }
    if (!_expanded) return;
    _expanded = false;
    fullWindow.value--;
    if (isDesktopNative) unawaited(windowManager.setFullScreen(false));
    if (mounted) setState(() {});
  }

  void _toggleExpanded() => _expanded ? _collapse() : _expand();

  void _stepChannel(int dir) {
    final list = _visible();
    if (list.isEmpty) return;
    final at = list.indexWhere((s) => s.streamId == _watching?.streamId);
    final next = at < 0 ? 0 : (at + dir) % list.length;
    setState(() => _watching = list[next]);
    _reveal(next);
  }

  /// Keeps the playing channel's row in view while zapping.
  void _reveal(int index) {
    if (!_listScroll.hasClients) return;
    final pos = _listScroll.position;
    final y = index * _rowExtent;
    if (y < pos.pixels || y + _rowExtent > pos.pixels + pos.viewportDimension) {
      _listScroll.jumpTo((y - (pos.viewportDimension - _rowExtent) / 2).clamp(0.0, pos.maxScrollExtent));
    }
  }

  void _tapStream(List<IptvStream> list, int i, {required bool embedded}) {
    if (_section == IptvSection.series) {
      Navigator.of(context).push(ShellRoute(child: SeriesPage(portal: _portal, series: list[i])));
      return;
    }
    if (embedded && _live) {
      setState(() => _watching = list[i]);
      return;
    }
    openLivePlayer(context, [for (final x in list) LiveItem.stream(_portal, x, _section)], i);
  }

  void _checkCategory() {
    final list = _filtered(workingOnly: false);
    _alive.check([for (final s in list) (s.streamId, xtreamUrl(_portal, s, IptvSection.live))]);
  }

  /// A channel's details where there's no pane for them: its guide and a way to watch.
  void _showInfo(List<IptvStream> list, int i) {
    final s = list[i];
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: VyseColors.surface,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .78),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: _ChannelDetails(
              portal: _portal,
              stream: s,
              category: _catNames[s.categoryId] ?? '',
              touch: _touchDevice,
              onWatch: () {
                Navigator.of(sheet).pop();
                _tapStream(list, i, embedded: false);
              },
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────── What's in the lists ─────────────────────────

  static bool _isAll(String? id) => id == null || id.isEmpty || id == 'all' || id == '*';

  bool get _ready => _data.activePortal?.key == _portal.key && _data.activeSection == _section && !_data.isLoading;

  String get _noun => switch (_section) {
        IptvSection.live => 'channels',
        IptvSection.vod => 'movies',
        IptvSection.series => 'series',
      };

  String _counted(int n) {
    final one = switch (_section) {
      IptvSection.live => 'channel',
      IptvSection.vod => 'movie',
      IptvSection.series => 'series',
    };
    return '${fmtThousands(n)} ${n == 1 ? one : _noun}';
  }

  String get _title => _portal.name.isEmpty ? 'Portale' : _portal.name;

  String _meta(bool ready) => [
        if (_portal.expiry.isNotEmpty) 'Scade ${_portal.expiry}',
        if (ready) _counted(_data.browserAllStreams.length),
      ].join('  ·  ');

  String _categoryTitle() {
    if (_favorites) return 'Preferiti';
    final id = _data.browserSelectedCategoryId;
    if (_isAll(id)) return 'Tutti: $_noun';
    return _catNames[id] ?? 'Tutti: $_noun';
  }

  /// The open category (or the favorites), narrowed by the search box.
  List<IptvStream> _filtered({required bool workingOnly}) {
    final cat = _data.browserSelectedCategoryId;
    final all = _isAll(cat);
    final q = _text.text.trim().toLowerCase();
    final favs = LiveFavorites.ids.value;
    return [
      for (final s in _data.browserAllStreams)
        if ((_favorites ? favs.contains(LiveFavorites.keyOf(_portal, s)) : all || s.categoryId == cat) &&
            (q.isEmpty || s.name.toLowerCase().contains(q)) &&
            (!workingOnly || _alive.results[s.streamId] == true))
          s,
    ];
  }

  /// What the list shows, in the order picked.
  List<IptvStream> _visible() {
    final sig = (
      _dataTick,
      _section,
      _favorites,
      _data.browserSelectedCategoryId,
      _text.text.trim().toLowerCase(),
      _sort,
      _workingOnly,
      _workingOnly ? _alive.done : 0,
      _favorites ? identityHashCode(LiveFavorites.ids.value) : 0,
    );
    if (sig == _listSig) return _listMemo;
    var out = _filtered(workingOnly: _workingOnly);
    if (_sort != _Sort.portal) {
      final keyed = [for (final s in out) (s.name.toLowerCase(), s)]..sort((a, b) => a.$1.compareTo(b.$1));
      out = [for (final k in _sort == _Sort.az ? keyed : keyed.reversed) k.$2];
    }
    _listSig = sig;
    return _listMemo = out;
  }

  void _recount() {
    final favs = LiveFavorites.ids.value;
    final sig = (_dataTick, _section, identityHashCode(favs));
    if (sig == _countSig) return;
    _countSig = sig;
    final counts = <String, int>{};
    var fav = 0;
    for (final s in _data.browserAllStreams) {
      counts[s.categoryId] = (counts[s.categoryId] ?? 0) + 1;
      if (favs.isNotEmpty && favs.contains(LiveFavorites.keyOf(_portal, s))) fav++;
    }
    _counts = counts;
    _favCount = fav;
    _catNames = {for (final c in _data.categories) c.id: c.name};
  }

  /// The category list as shown: Favorites and All first, then the portal's, narrowed by search.
  List<_Cat> _cats() {
    final q = _catText.text.trim().toLowerCase();
    bool hit(String name) => q.isEmpty || name.toLowerCase().contains(q);
    final portal = [
      for (final c in _data.categories)
        if (((_counts[c.id] ?? 0) > 0 || _counts.isEmpty) && hit(c.name)) c,
    ];
    if (_catAz) portal.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return [
      if (_live && hit('Preferiti')) (id: _favId, name: 'Preferiti', count: _favCount, icon: Icons.star_rounded),
      if (hit('Tutti: $_noun')) (id: '', name: 'Tutti: $_noun', count: _data.browserAllStreams.length, icon: null),
      for (final c in portal) (id: c.id, name: c.name, count: _counts[c.id] ?? 0, icon: null),
    ];
  }

  /// The portal's own categories among those shown (Favorites and All aren't counted).
  static int _realCount(List<_Cat> cats) => cats.where((c) => c.id.isNotEmpty && c.id != _favId).length;

  // ───────────────────────── Layout ─────────────────────────

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: VyseColors.bg,
        child: ListenableBuilder(
          listenable: Listenable.merge([_data, _alive, LiveFavorites.ids]),
          builder: (context, _) {
            final ready = _ready;
            if (ready) _recount();
            final list = ready ? _visible() : const <IptvStream>[];
            final watching = _live ? _watching : null;
            if (_expanded && watching != null) return _player(watching, list, expanded: true);
            return LayoutBuilder(
              builder: (context, box) => _stepped(context) ? _steps(context, box.biggest, ready, list) : _panes(context, box.biggest, ready, list),
            );
          },
        ),
      );

  double _scale(BuildContext context) => (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 1.6);

  /// One list at a time: phones, and windows too narrow for two decent panes beside the rail.
  static bool _stepped(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w < 640 || w - Layout.inset(context) - pageRight(context) < 560;
  }

  /// Tablets and up: two or three cards side by side under one slim bar.
  Widget _panes(BuildContext context, Size size, bool ready, List<IptvStream> list) {
    final touch = _touchDevice;
    final short = size.height < 520; // a phone on its side
    final left = Layout.inset(context), right = pageRight(context);
    final top = Layout.topChrome(context) + (short ? 8 : 22);
    final cw = size.width - left - right;
    const gap = 14.0;
    final roomy = cw > 1900;
    final listW = (cw * .3).clamp(340.0, roomy ? 520.0 : 440.0);
    var catW = (cw * .24).clamp(210.0, roomy ? 340.0 : 300.0);
    // The picture needs a pane worth watching; otherwise the channel opens in the full player.
    final three = _live && cw - catW - listW - gap * 2 >= 340 && size.height >= 420;
    if (!three) {
      catW = (cw * .3).clamp(190.0, 300.0);
      _watching = null;
    }
    final bottom = pageBottom(context) - 16;
    final scale = _scale(context);
    _rowExtent = (touch ? 80 : 74) * scale;

    final cats = ready ? _cats() : const <_Cat>[];
    final categories = _pane(
      _catScroll,
      _catHeader(ready: ready, touch: touch, compact: short, shown: _realCount(cats)),
      _catSlivers(cats, ready: ready, touch: touch, extent: (touch ? 48 : 40) * scale, bottom: bottom),
    );
    final content = _pane(
      _live ? _listScroll : _gridScroll,
      _listHeader(list, ready: ready, touch: touch, compact: short, back: false),
      _live
          ? _channelSlivers(list, ready: ready, touch: touch, embedded: three, bottom: bottom)
          : _posterSlivers(list, ready: ready, bottom: bottom),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(left, top, right, short ? 8 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(ready, compact: short, touch: touch),
          SizedBox(height: short ? 8 : 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: catW, child: _Card(child: categories)),
                const SizedBox(width: gap),
                if (three) ...[
                  SizedBox(width: listW, child: _Card(child: content)),
                  const SizedBox(width: gap),
                  // not clipped: nothing sits between the picture and the window but paint
                  Expanded(child: _Card(clip: false, child: _watchPane(list, touch: touch, bottom: bottom))),
                ] else
                  Expanded(child: _Card(child: content)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Phones and narrow windows: one list at a time. Categories scroll with the page header; the
  /// channel step keeps its header (and the way back) in place when the screen is tall enough.
  Widget _steps(BuildContext context, Size size, bool ready, List<IptvStream> list) {
    const touch = true; // big targets either way: this is the small layout
    // Everything below is laid out for a phone's 16px margins; a narrow window adds the rail's.
    final extra = EdgeInsets.only(left: Layout.inset(context) - 16, right: pageRight(context) - 16);
    // A phone on its side: one slim row instead of the page header, so the list starts on screen.
    final short = size.height < 520;
    final slim = short && size.width - extra.horizontal >= 480;
    _watching = null; // no pane to play in here: channels open in the full player
    final top = Layout.topChrome(context) + 12;
    final bottom = pageBottom(context);
    final scale = _scale(context);
    _rowExtent = 80 * scale;
    final Widget body;
    if (!_channelsStep) {
      final cats = ready ? _cats() : const <_Cat>[];
      final fav = _data.isFavoritePortal(_portal.key);
      final pageHeader = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title: _title, subtitle: _meta(ready)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _SectionTabs(value: _section, onChanged: _open, touch: touch, expand: true)),
            const SizedBox(width: 6),
            _IconTool(
              icon: fav ? Icons.star_rounded : Icons.star_border_rounded,
              tooltip: fav ? 'Togli il portale dai preferiti' : 'Portale preferito',
              active: fav,
              touch: touch,
              onTap: () => _data.toggleFavoritePortal(_portal.key),
            ),
          ]),
        ],
      );
      body = PageScrollbar(
        controller: _catScroll,
        child: CustomScrollView(
          controller: _catScroll,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, top, 12, 6),
                child: slim ? _topBar(ready, compact: true, touch: touch) : pageHeader,
              ),
            ),
            SliverToBoxAdapter(child: _catHeader(ready: ready, touch: touch, compact: short, shown: _realCount(cats))),
            ..._catSlivers(cats, ready: ready, touch: touch, extent: 48 * scale, bottom: bottom),
          ],
        ),
      );
    } else {
      final header = _listHeader(list, ready: ready, touch: touch, compact: short, back: true);
      final slivers =
          _live ? _channelSlivers(list, ready: ready, touch: touch, embedded: false, bottom: bottom) : _posterSlivers(list, ready: ready, bottom: bottom);
      final c = _live ? _listScroll : _gridScroll;
      body = Padding(
        padding: EdgeInsets.only(top: top - 6),
        child: size.height >= 520
            ? _pane(c, header, slivers)
            : CustomScrollView(controller: c, slivers: [SliverToBoxAdapter(child: header), ...slivers]),
      );
    }
    return Stack(children: [
      const Positioned(top: -220, right: -160, child: PageGlow()),
      Positioned.fill(child: Padding(padding: extra, child: body)),
    ]);
  }

  /// A header that stays put over its own scrolling list.
  Widget _pane(ScrollController c, Widget header, List<Widget> slivers) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: _PaneScrollbar(controller: c, child: CustomScrollView(controller: c, slivers: slivers)),
          ),
        ],
      );

  Widget _topBar(bool ready, {required bool compact, required bool touch}) {
    final fav = _data.isFavoritePortal(_portal.key);
    final meta = _meta(ready);
    return Row(
      children: [
        if (Navigator.of(context).canPop()) ...[
          Transform.translate(offset: const Offset(-6, 0), child: BackLink(onTap: () => Navigator.of(context).maybePop())),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: compact ? 17 : 21, fontWeight: FontWeight.w800, letterSpacing: -.3, height: 1.15),
              ),
              if (!compact && meta.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        _IconTool(
          icon: fav ? Icons.star_rounded : Icons.star_border_rounded,
          tooltip: fav ? 'Togli il portale dai preferiti' : 'Portale preferito',
          active: fav,
          touch: touch,
          onTap: () => _data.toggleFavoritePortal(_portal.key),
        ),
        const SizedBox(width: 10),
        _SectionTabs(value: _section, onChanged: _open, touch: touch),
      ],
    );
  }

  // ───────────────────────── Categories ─────────────────────────

  Widget _catHeader({required bool ready, required bool touch, required bool compact, required int shown}) {
    final searching = _catSearch || _catText.text.isNotEmpty;
    final field = _PaneSearch(
      controller: _catText,
      hint: 'Cerca categorie',
      touch: touch,
      autofocus: compact,
      onClose: compact
          ? () {
              _catText.clear();
              setState(() => _catSearch = false);
            }
          : null,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (compact && searching)
            field
          else
            Row(children: [
              Expanded(
                child: _PaneTitle(
                  title: 'Categorie',
                  meta: !ready ? '' : (shown == 1 ? '1 categoria' : '${fmtThousands(shown)} categorie'),
                  inline: compact,
                ),
              ),
              if (compact)
                _IconTool(icon: Icons.search_rounded, tooltip: 'Cerca categorie', touch: touch, onTap: () => setState(() => _catSearch = true)),
              _IconTool(
                icon: Icons.sort_by_alpha_rounded,
                tooltip: _catAz ? 'Torna all\'ordine del portale' : 'Ordina dalla A alla Z',
                active: _catAz,
                touch: touch,
                onTap: () => setState(() => _catAz = !_catAz),
              ),
            ]),
          if (!compact) ...[const SizedBox(height: 10), field],
        ],
      ),
    );
  }

  List<Widget> _catSlivers(List<_Cat> cats, {required bool ready, required bool touch, required double extent, required double bottom}) {
    if (!ready) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Shimmer(
              child: Column(children: [
                for (var i = 0; i < 9; i++) const Padding(padding: EdgeInsets.only(bottom: 10), child: SkeletonBox(width: double.infinity, height: 28, radius: 9)),
              ]),
            ),
          ),
        ),
      ];
    }
    if (cats.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _PaneNote(icon: Icons.search_off_rounded, title: 'Nessuna categoria corrisponde', body: 'Prova un nome più corto.'),
        ),
      ];
    }
    final sel = _data.browserSelectedCategoryId;
    return [
      SliverFixedExtentList.builder(
        itemExtent: extent,
        itemCount: cats.length,
        itemBuilder: (context, i) {
          final c = cats[i];
          final fav = c.id == _favId;
          return _CategoryTile(
            label: c.name,
            count: c.count,
            icon: c.icon,
            selected: fav ? _favorites : !_favorites && (c.id.isEmpty ? _isAll(sel) : sel == c.id),
            onTap: () => fav ? _pickFavorites() : _pickCategory(c.id),
          );
        },
      ),
      SliverToBoxAdapter(child: SizedBox(height: bottom)),
    ];
  }

  // ───────────────────────── Channels / posters ─────────────────────────

  Widget _listHeader(List<IptvStream> list, {required bool ready, required bool touch, required bool compact, required bool back}) {
    final accent = accentOf(context);
    final title = _categoryTitle();
    final searching = _listSearch || _text.text.isNotEmpty;
    final field = _PaneSearch(
      controller: _text,
      hint: _favorites || !_isAll(_data.browserSelectedCategoryId) ? 'Cerca in $title' : 'Cerca in tutti: $_noun',
      touch: touch,
      autofocus: compact,
      onClose: compact
          ? () {
              _text.clear();
              setState(() => _listSearch = false);
            }
          : null,
    );
    final checked = _live && (_alive.running || _alive.working > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(back ? 6 : 14, 12, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (compact && searching)
                field
              else
                Row(children: [
                  if (back) ...[
                    _IconTool(icon: Icons.arrow_back_rounded, tooltip: 'Torna alle categorie', touch: touch, onTap: _backToCategories),
                    const SizedBox(width: 4),
                  ],
                  Expanded(child: _PaneTitle(title: title, meta: ready ? _counted(list.length) : 'Caricamento', inline: compact)),
                  if (compact) _IconTool(icon: Icons.search_rounded, tooltip: 'Cerca', touch: touch, onTap: () => setState(() => _listSearch = true)),
                  _listMenu(touch: touch, ready: ready),
                ]),
              if (!compact) ...[
                const SizedBox(height: 10),
                Padding(padding: EdgeInsets.only(left: back ? 8 : 0), child: field),
              ],
              if (checked) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.only(left: back ? 8 : 0),
                  child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (_alive.working > 0)
                      _Chip(label: 'Solo funzionanti · ${_alive.working}', selected: _workingOnly, onTap: () => setState(() => _workingOnly = !_workingOnly)),
                    if (_alive.running)
                      Text(
                        'Controllati ${_alive.done} di ${_alive.total}',
                        style: const TextStyle(fontSize: 12, color: VyseColors.textFaint, fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                  ]),
                ),
              ],
            ],
          ),
        ),
        // Thin line while the section loads, like Discover.
        SizedBox(height: 2, child: ready ? null : LinearProgressIndicator(minHeight: 2, color: accent, backgroundColor: Colors.transparent)),
      ],
    );
  }

  /// Order, and for live channels the check for which ones answer.
  Widget _listMenu({required bool touch, required bool ready}) {
    final accent = accentOf(context);
    PopupMenuItem<Object> item(Object value, String label, {bool on = false, IconData? icon}) => PopupMenuItem<Object>(
          value: value,
          height: 42,
          child: Row(children: [
            Icon(icon ?? (on ? Icons.check_rounded : null), size: 17, color: on ? accent : VyseColors.textDim),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? accent : VyseColors.text)),
          ]),
        );
    return PopupMenuButton<Object>(
      tooltip: 'Ordina e strumenti',
      // On the root navigator: a menu on this tab's would count as a page over the browser,
      // and the player in the pane stops when it's covered.
      useRootNavigator: true,
      color: VyseColors.surfaceHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: VyseColors.stroke)),
      onSelected: (v) {
        if (v is _Sort) {
          setState(() => _sort = v);
        } else if (_alive.running) {
          _alive.stop();
        } else {
          _checkCategory();
        }
      },
      itemBuilder: (context) => [
        item(_Sort.portal, 'Ordine del portale', on: _sort == _Sort.portal),
        item(_Sort.az, 'Dalla A alla Z', on: _sort == _Sort.az),
        item(_Sort.za, 'Dalla Z alla A', on: _sort == _Sort.za),
        if (_live && ready && _data.browserAllStreams.isNotEmpty) ...[
          const PopupMenuDivider(height: 8),
          _alive.running
              ? item('check', 'Ferma il controllo', icon: Icons.stop_rounded)
              : item('check', 'Controlla quali funzionano', icon: Icons.wifi_tethering_rounded),
        ],
      ],
      child: IgnorePointer(
        child: _IconTool(icon: Icons.tune_rounded, active: _sort != _Sort.portal || _alive.running, touch: touch, onTap: () {}),
      ),
    );
  }

  List<Widget> _channelSlivers(List<IptvStream> list, {required bool ready, required bool touch, required bool embedded, required double bottom}) {
    final extent = _rowExtent;
    if (!ready) {
      return [
        SliverToBoxAdapter(
          child: Shimmer(child: Column(children: [for (var i = 0; i < 7; i++) _RowSkeleton(height: extent)])),
        ),
      ];
    }
    if (list.isEmpty) return [SliverFillRemaining(hasScrollBody: false, child: _emptyNote())];
    return [
      SliverFixedExtentList.builder(
        itemExtent: extent,
        itemCount: list.length,
        itemBuilder: (context, i) {
          final s = list[i];
          return _ChannelRow(
            portal: _portal,
            stream: s,
            selected: embedded && _watching?.streamId == s.streamId,
            favorite: LiveFavorites.has(_portal, s),
            alive: _alive.results[s.streamId],
            touch: touch,
            onTap: () => _tapStream(list, i, embedded: embedded),
            onFavorite: () => LiveFavorites.toggle(_portal, s),
            onInfo: embedded ? null : () => _showInfo(list, i),
          );
        },
      ),
      SliverToBoxAdapter(child: SizedBox(height: bottom)),
    ];
  }

  List<Widget> _posterSlivers(List<IptvStream> list, {required bool ready, required double bottom}) {
    if (ready && list.isEmpty) return [SliverFillRemaining(hasScrollBody: false, child: _emptyNote())];
    final maxW = switch (Layout.of(context)) {
      FormFactor.phone => 124.0,
      FormFactor.tablet => 150.0,
      FormFactor.desktop => 172.0,
    };
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        sliver: !ready
            ? captionedGrid(
                maxWidth: maxW,
                aspect: 1.5,
                caption: 0,
                itemCount: 18,
                itemBuilder: (_, i) => const Shimmer(child: SkeletonBox(width: double.infinity, height: double.infinity, radius: 7)),
              )
            : captionedGrid(
                maxWidth: maxW,
                aspect: 1.5,
                caption: 0,
                itemCount: list.length,
                itemBuilder: (context, i) => FadeSlideIn(
                  key: ValueKey('${_section.name}/$i/${list[i].streamId}'),
                  delay: Duration(milliseconds: 22 * (i % 20)),
                  offset: 12,
                  child: StreamCard(name: list[i].name, image: list[i].icon, poster: true, onTap: () => _tapStream(list, i, embedded: false)),
                ),
              ),
      ),
      SliverToBoxAdapter(child: SizedBox(height: bottom)),
    ];
  }

  Widget _emptyNote() {
    if (_favorites && _text.text.trim().isEmpty) {
      return const _PaneNote(icon: Icons.star_border_rounded, title: 'Ancora nessun preferito', body: 'Metti una stella a un canale per tenerlo qui.');
    }
    if (_data.browserAllStreams.isEmpty) {
      return _PaneNote(
        icon: Icons.travel_explore_rounded,
        title: 'Niente in questa sezione',
        body: 'Questo portale non ha $_noun, o non ha risposto.',
        action: ('Riprova', () => _open(_section)),
      );
    }
    return const _PaneNote(icon: Icons.search_off_rounded, title: 'Nessun risultato', body: 'Prova un\'altra categoria, o cancella la ricerca.');
  }

  // ───────────────────────── The picture ─────────────────────────

  Widget _player(IptvStream s, List<IptvStream> list, {required bool expanded}) => BrowserLivePlayer(
        key: _playerKey,
        item: LiveItem.stream(_portal, s, IptvSection.live),
        expanded: expanded,
        onExpand: _toggleExpanded,
        onStep: list.length > 1 ? _stepChannel : null,
        guide: expanded ? _NowNextStrip(portal: _portal, stream: s) : null,
      );

  Widget _watchPane(List<IptvStream> list, {required bool touch, required double bottom}) {
    final s = _watching;
    if (s == null) {
      return _PaneNote(
        icon: Icons.live_tv_rounded,
        title: 'Scegli un canale',
        body: 'It plays here. ${touch ? 'Double-tap' : 'Doppio clic'} the picture for full screen.',
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        const pad = 10.0;
        // As wide as the pane, unless that would leave no room for the guide underneath.
        var w = box.maxWidth - pad * 2;
        var h = w * 9 / 16;
        final maxH = math.max(120.0, box.maxHeight - 210);
        if (h > maxH) {
          h = maxH;
          w = h * 16 / 9;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(pad),
              child: Center(child: SizedBox(width: w, height: h, child: _player(s, list, expanded: false))),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(18, 8, 18, bottom),
                child: _ChannelDetails(portal: _portal, stream: s, category: _catNames[s.categoryId] ?? '', touch: touch),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Pieces ─────────────────────────

/// A pane of the browser: a quiet card.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.clip = true});
  final Widget child;
  final bool clip;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: VyseColors.surface.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: VyseColors.stroke),
        ),
        child: clip ? ClipRRect(borderRadius: BorderRadius.circular(17), child: child) : child,
      );
}

class _PaneScrollbar extends StatelessWidget {
  const _PaneScrollbar({required this.controller, required this.child});
  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged) ? 7 : 4),
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.dragged)) return accent;
          return Colors.white.withValues(alpha: s.contains(WidgetState.hovered) ? .5 : .2);
        }),
        radius: const Radius.circular(8),
        crossAxisMargin: 2,
        mainAxisMargin: 6,
        minThumbLength: 40,
      ),
      child: Scrollbar(controller: controller, thumbVisibility: !_touchDevice, child: child),
    );
  }
}

class _PaneTitle extends StatelessWidget {
  const _PaneTitle({required this.title, required this.meta, this.inline = false});
  final String title;
  final String meta;

  /// One line, for short screens.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    const big = TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: VyseColors.text, height: 1.2);
    const small = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]);
    if (inline) {
      return Text.rich(
        TextSpan(children: [
          TextSpan(text: title, style: big),
          if (meta.isNotEmpty) TextSpan(text: '   $meta', style: small),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: big),
        if (meta.isNotEmpty) ...[const SizedBox(height: 2), Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)],
      ],
    );
  }
}

/// Live / Movies / Series, wearing the theme's colour.
class _SectionTabs extends StatelessWidget {
  const _SectionTabs({required this.value, required this.onChanged, required this.touch, this.expand = false});
  final IptvSection value;
  final ValueChanged<IptvSection> onChanged;
  final bool touch;
  final bool expand;

  static const _items = [(IptvSection.live, 'In diretta'), (IptvSection.vod, 'Film'), (IptvSection.series, 'Serie')];

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context), on = onAccentOf(context);
    Widget tab((IptvSection, String) it) {
      final selected = it.$1 == value;
      final child = Pressable(
        onTap: () => onChanged(it.$1),
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: touch ? 40 : 34,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: selected ? accent : Colors.white.withValues(alpha: hovered ? .08 : 0),
          ),
          child: Text(
            it.$2,
            maxLines: 1,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected ? on : (hovered ? VyseColors.text : VyseColors.textDim),
            ),
          ),
        ),
      );
      return expand ? Expanded(child: child) : child;
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: .05),
        border: Border.all(color: VyseColors.stroke),
      ),
      child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: [for (final it in _items) tab(it)]),
    );
  }
}

/// Square icon button for pane headers: a hover wash with a mouse, a full target for a finger.
class _IconTool extends StatelessWidget {
  const _IconTool({required this.icon, required this.onTap, this.tooltip, this.active = false, this.touch = false});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool active;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    final d = touch ? 44.0 : 34.0;
    return Pressable(
      tooltip: tooltip,
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: active ? accent.withValues(alpha: hovered ? .24 : .16) : Colors.white.withValues(alpha: hovered ? .1 : 0),
        ),
        child: Icon(icon, size: 19, color: active ? accent : (hovered ? VyseColors.text : VyseColors.textDim)),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? accent : Colors.white.withValues(alpha: hovered ? .12 : .07),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? onAccentOf(context) : VyseColors.textDim,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _AccentButton extends StatelessWidget {
  const _AccentButton({required this.label, required this.onTap, this.icon, this.height = 44});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context), hot = accentHotOf(context), on = onAccentOf(context);
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: hovered || pressed ? hot : accent),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 19, color: on), const SizedBox(width: 6)],
            Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: on)),
          ],
        ),
      ),
    );
  }
}

/// Small search box for a pane header; its focus ring wears the theme.
class _PaneSearch extends StatefulWidget {
  const _PaneSearch({required this.controller, required this.hint, required this.touch, this.autofocus = false, this.onClose});
  final TextEditingController controller;
  final String hint;
  final bool touch;
  final bool autofocus;

  /// Short screens: the box only appears on demand, and closes again.
  final VoidCallback? onClose;

  @override
  State<_PaneSearch> createState() => _PaneSearchState();
}

class _PaneSearchState extends State<_PaneSearch> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
    widget.controller.addListener(_changed);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(_PaneSearch old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _clearOrClose() {
    if (widget.controller.text.isNotEmpty) {
      widget.controller.clear();
      _focus.requestFocus();
    } else if (widget.onClose != null) {
      widget.onClose!();
    } else {
      _focus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    final focused = _focus.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;
    final h = widget.touch ? 44.0 : 38.0;
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: h,
        padding: const EdgeInsets.only(left: 12, right: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.white.withValues(alpha: focused ? .08 : .05),
          border: Border.all(color: focused ? accent.withValues(alpha: .6) : Colors.white.withValues(alpha: .08), width: focused ? 1.4 : 1),
        ),
        child: Row(children: [
          Icon(Icons.search_rounded, size: 18, color: focused ? accent : VyseColors.textDim),
          const SizedBox(width: 9),
          Expanded(
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clearOrClose},
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                cursorColor: accent,
                cursorWidth: 1.6,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: VyseColors.text),
                decoration: InputDecoration.collapsed(hintText: widget.hint, hintStyle: const TextStyle(fontSize: 13.5, color: VyseColors.textFaint)),
              ),
            ),
          ),
          if (hasText || widget.onClose != null)
            Pressable(
              tooltip: hasText ? 'Cancella' : 'Chiudi la ricerca',
              onTap: _clearOrClose,
              builder: (context, hovered, _) => SizedBox(
                width: h - 6,
                height: h - 6,
                child: Icon(Icons.close_rounded, size: 16, color: hovered ? VyseColors.text : VyseColors.textDim),
              ),
            ),
        ]),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.label, required this.count, required this.selected, required this.onTap, this.icon});
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
        padding: const EdgeInsets.only(left: 12, right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? accent.withValues(alpha: .14) : Colors.white.withValues(alpha: hovered ? .06 : 0),
          border: Border.all(color: selected ? accent.withValues(alpha: .6) : Colors.transparent),
        ),
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 16, color: selected ? accent : VyseColors.textDim), const SizedBox(width: 8)],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected || hovered ? VyseColors.text : VyseColors.textDim,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: selected ? accent : Colors.white.withValues(alpha: .07)),
            child: Text(
              fmtThousands(count),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: selected ? onAccentOf(context) : VyseColors.textDim,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Channel logo on a soft tile, the way studio logos sit elsewhere in the app.
class _Logo extends StatelessWidget {
  const _Logo({required this.url, required this.size});
  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.live_tv_rounded, size: size * .42, color: VyseColors.textFaint);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .13),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(size * .24)),
      child: url.isEmpty
          ? fallback
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              memCacheWidth: 160,
              fadeInDuration: const Duration(milliseconds: 200),
              errorWidget: (_, _, _) => fallback,
            ),
    );
  }
}

class _StarButton extends StatelessWidget {
  const _StarButton({required this.on, required this.touch, required this.onTap});
  final bool on;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = touch ? 44.0 : 34.0;
    return Pressable(
      tooltip: on ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
      onTap: onTap,
      builder: (context, hovered, _) => SizedBox(
        width: d,
        height: d,
        child: Icon(
          on ? Icons.star_rounded : Icons.star_border_rounded,
          size: 21,
          color: on ? accentOf(context) : (hovered ? VyseColors.text : VyseColors.textFaint),
        ),
      ),
    );
  }
}

/// Progress through a programme, in the theme's colour.
class _Progress extends StatelessWidget {
  const _Progress(this.value, {this.height = 3});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: ColoredBox(
          color: Colors.white.withValues(alpha: .1),
          child: SizedBox(
            height: height,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: value.clamp(0.0, 1.0),
                heightFactor: 1,
                child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [accentOf(context), accentHotOf(context)]))),
              ),
            ),
          ),
        ),
      );
}

class _PaneNote extends StatelessWidget {
  const _PaneNote({required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .05)),
                child: Icon(icon, size: 25, color: VyseColors.textDim),
              ),
              const SizedBox(height: 14),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.4)),
              if (action != null) ...[
                const SizedBox(height: 16),
                _AccentButton(label: action!.$1, onTap: action!.$2, height: 40),
              ],
            ],
          ),
        ),
      );
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            SkeletonBox(width: 44, height: 44, radius: 11),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 150, height: 11, radius: 5),
                  SizedBox(height: 9),
                  SkeletonBox(width: double.infinity, height: 8, radius: 4),
                ],
              ),
            ),
            SizedBox(width: 30),
          ]),
        ),
      );
}

// ───────────────────────── Channel row ─────────────────────────

/// One channel with what's on. It asks for its guide when it comes on screen and gives the
/// request up if it scrolls away first, so a long list only loads what you stop on.
class _ChannelRow extends StatefulWidget {
  const _ChannelRow({
    required this.portal,
    required this.stream,
    required this.selected,
    required this.favorite,
    required this.alive,
    required this.touch,
    required this.onTap,
    required this.onFavorite,
    this.onInfo,
  });

  final VerifiedPortal portal;
  final IptvStream stream;

  /// Playing in the pane beside the list.
  final bool selected;
  final bool favorite;

  /// What the alive check found; null before it has looked.
  final bool? alive;
  final bool touch;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  /// Layouts without a details pane get an info button instead.
  final VoidCallback? onInfo;

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  @override
  void initState() {
    super.initState();
    liveGuide.want(widget.portal, widget.stream);
    liveGuide.clock.addListener(_tick);
  }

  @override
  void didUpdateWidget(_ChannelRow old) {
    super.didUpdateWidget(old);
    if (old.stream.streamId != widget.stream.streamId || old.portal.key != widget.portal.key) {
      liveGuide.unwant(old.portal, old.stream);
      liveGuide.want(widget.portal, widget.stream);
    }
  }

  @override
  void dispose() {
    liveGuide.clock.removeListener(_tick);
    liveGuide.unwant(widget.portal, widget.stream);
    super.dispose();
  }

  /// Still on screen a while later: fetch again only if what it holds has all aired.
  void _tick() => liveGuide.refresh(widget.portal, widget.stream);

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    final s = widget.stream;
    final selected = widget.selected;
    return Pressable(
      onTap: widget.onTap,
      builder: (context, hovered, _) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: selected ? accent.withValues(alpha: .12) : Colors.white.withValues(alpha: hovered ? .05 : 0),
          border: Border.all(color: selected ? accent.withValues(alpha: .65) : Colors.transparent),
        ),
        child: Row(children: [
          _Logo(url: s.icon, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (selected) ...[
                    Icon(Icons.play_arrow_rounded, size: 16, color: accent),
                    const SizedBox(width: 3),
                  ] else if (widget.alive != null) ...[
                    Container(
                      width: 6,
                      height: 6,
                      // the alive check's own green, as on the channel tiles
                      decoration: BoxDecoration(shape: BoxShape.circle, color: widget.alive! ? const Color(0xFF2BD67B) : VyseColors.textFaint),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.25)),
                  ),
                ]),
                const SizedBox(height: 3),
                ValueListenableBuilder<List<EpgEntry>?>(
                  valueListenable: liveGuide.guideOf(widget.portal, s),
                  builder: (context, guide, _) => ValueListenableBuilder<DateTime>(
                    valueListenable: liveGuide.clock,
                    builder: (context, _, _) => _GuideLines(guide: guide),
                  ),
                ),
              ],
            ),
          ),
          _StarButton(on: widget.favorite, touch: widget.touch, onTap: widget.onFavorite),
          if (widget.onInfo != null) _IconTool(icon: Icons.info_outline_rounded, tooltip: 'Guida e dettagli', touch: widget.touch, onTap: widget.onInfo!),
        ]),
      ),
    );
  }
}

/// The two guide lines of a row: the programme on now, then its times around a progress bar
/// with what follows. Always the same height, so a row doesn't jump when its guide arrives.
class _GuideLines extends StatelessWidget {
  const _GuideLines({required this.guide});

  /// null while it loads; empty when there is none.
  final List<EpgEntry>? guide;

  static const _title = TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.25);
  static const _time = TextStyle(fontSize: 11, color: VyseColors.textFaint, height: 1.25, fontFeatures: [FontFeature.tabularFigures()]);

  @override
  Widget build(BuildContext context) {
    final list = guide;
    if (list == null) {
      // waiting for its turn: two faint bars where the lines will be
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text(' ', style: _title),
        const SizedBox(height: 4),
        SizedBox(height: _time.fontSize! * 1.25, child: const Align(alignment: Alignment.centerLeft, child: _Progress(0))),
      ]);
    }
    final t = DateTime.now();
    final nn = NowNext.of(list, t);
    final now = nn.now, next = nn.next;
    if (now == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(
          next == null ? 'Nessuna guida' : 'Dopo  ${guideTime(next.start)}  ${next.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _title.copyWith(color: next == null ? VyseColors.textFaint : VyseColors.textDim),
        ),
        const SizedBox(height: 4),
        const Text(' ', style: _time),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(now.title.isEmpty ? 'Senza titolo' : now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _title),
      const SizedBox(height: 4),
      LayoutBuilder(builder: (context, box) {
        // Measured, so it can't overflow: a narrow row drops the next title first, then the
        // times, and always keeps the bar.
        final times = _timeWidth(context) * 2 + 14;
        final bar = Expanded(flex: 4, child: _Progress(nn.progress(t)));
        if (box.maxWidth < times + 24) {
          return SizedBox(height: MediaQuery.textScalerOf(context).scale(_time.fontSize!) * 1.25, child: Row(children: [bar]));
        }
        return _timeRow(now, box.maxWidth - times - 9 >= 130 ? next : null, bar);
      }),
    ]);
  }

  Widget _timeRow(EpgEntry now, EpgEntry? next, Widget bar) => Row(children: [
        Text(guideTime(now.start), style: _time),
        const SizedBox(width: 7),
        bar,
        const SizedBox(width: 7),
        Text(guideTime(now.stop), style: _time),
        if (next != null && next.title.isNotEmpty) ...[
          const SizedBox(width: 9),
          Expanded(
            flex: 7,
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Dopo  '),
                TextSpan(text: next.title, style: const TextStyle(color: VyseColors.textDim)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _time,
            ),
          ),
        ],
      ]);

  /// How wide a time is drawn, measured once per font and text size.
  static Object? _timeKey;
  static double _timeW = 32;
  static double _timeWidth(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(_time);
    final scaler = MediaQuery.textScalerOf(context);
    final key = (style.fontFamily, scaler);
    if (key == _timeKey) return _timeW;
    final painter = TextPainter(text: TextSpan(text: '00:00', style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout();
    _timeKey = key;
    _timeW = painter.width;
    painter.dispose();
    return _timeW;
  }
}

// ───────────────────────── Details ─────────────────────────

/// A channel's fuller picture: what's on, how far in, the blurb, and what follows. Asks for the
/// longer schedule once when it opens.
class _ChannelDetails extends StatefulWidget {
  const _ChannelDetails({required this.portal, required this.stream, required this.category, required this.touch, this.onWatch});
  final VerifiedPortal portal;
  final IptvStream stream;
  final String category;
  final bool touch;

  /// Shown as a Watch button where the channel isn't already playing beside it.
  final VoidCallback? onWatch;

  @override
  State<_ChannelDetails> createState() => _ChannelDetailsState();
}

class _ChannelDetailsState extends State<_ChannelDetails> {
  @override
  void initState() {
    super.initState();
    _ask();
    liveGuide.clock.addListener(_ask);
  }

  @override
  void didUpdateWidget(_ChannelDetails old) {
    super.didUpdateWidget(old);
    if (old.stream.streamId != widget.stream.streamId) _ask();
  }

  @override
  void dispose() {
    liveGuide.clock.removeListener(_ask);
    super.dispose();
  }

  /// The loader keeps it to one request per channel every ten minutes.
  void _ask() => liveGuide.wantSchedule(widget.portal, widget.stream);

  static String _left(Duration d) {
    final m = d.inMinutes;
    if (m < 1) return 'in chiusura';
    if (m < 60) return '$m min rimanenti';
    return '${m ~/ 60} h ${m % 60} min rimanenti';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stream;
    final sub = [if (widget.category.isNotEmpty) widget.category, if (widget.portal.name.isNotEmpty) widget.portal.name].join('  ·  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          _Logo(url: s.icon, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.2)),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
                ],
              ],
            ),
          ),
          ValueListenableBuilder<Set<String>>(
            valueListenable: LiveFavorites.ids,
            builder: (context, _, _) => _StarButton(
              on: LiveFavorites.has(widget.portal, s),
              touch: widget.touch,
              onTap: () => LiveFavorites.toggle(widget.portal, s),
            ),
          ),
        ]),
        if (widget.onWatch != null) ...[
          const SizedBox(height: 16),
          _AccentButton(icon: Icons.play_arrow_rounded, label: 'Guarda', onTap: widget.onWatch!),
        ],
        const SizedBox(height: 20),
        ValueListenableBuilder<List<EpgEntry>?>(
          valueListenable: liveGuide.guideOf(widget.portal, s),
          builder: (context, guide, _) => ValueListenableBuilder<DateTime>(
            valueListenable: liveGuide.clock,
            builder: (context, _, _) => _schedule(context, guide),
          ),
        ),
      ],
    );
  }

  Widget _schedule(BuildContext context, List<EpgEntry>? guide) {
    const quiet = TextStyle(fontSize: 13, color: VyseColors.textFaint);
    if (guide == null) return const Text('Caricamento della guida', style: quiet);
    final t = DateTime.now();
    final now = NowNext.of(guide, t).now;
    final later = [
      for (final e in guide)
        if (e.start.isAfter(t)) e,
    ].take(6).toList();
    if (now == null && later.isEmpty) return const Text('Nessuna guida per questo canale', style: quiet);
    const label = TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: VyseColors.textFaint);
    const time = TextStyle(fontSize: 12.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (now != null) ...[
          Text('IN ONDA ORA', style: label.copyWith(color: accentOf(context))),
          const SizedBox(height: 6),
          Text(now.title.isEmpty ? 'Senza titolo' : now.title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, height: 1.25)),
          const SizedBox(height: 4),
          Text('${guideTime(now.start)} – ${guideTime(now.stop)}  ·  ${_left(now.stop.difference(t))}', style: time),
          const SizedBox(height: 10),
          _Progress(NowNext(now, null).progress(t), height: 4),
          if (now.description.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(now.description.trim(), maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.45)),
          ],
          const SizedBox(height: 22),
        ],
        if (later.isNotEmpty) ...[
          const Text('A SEGUIRE', style: label),
          const SizedBox(height: 8),
          for (final e in later)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ConstrainedBox(constraints: const BoxConstraints(minWidth: 50), child: Text(guideTime(e.start), style: time)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(e.title.isEmpty ? 'Senza titolo' : e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                ),
              ]),
            ),
        ],
      ],
    );
  }
}

/// Now / next over the picture in full screen, like the full player's strip.
class _NowNextStrip extends StatefulWidget {
  const _NowNextStrip({required this.portal, required this.stream});
  final VerifiedPortal portal;
  final IptvStream stream;

  @override
  State<_NowNextStrip> createState() => _NowNextStripState();
}

class _NowNextStripState extends State<_NowNextStrip> {
  @override
  void initState() {
    super.initState();
    liveGuide.want(widget.portal, widget.stream);
    liveGuide.clock.addListener(_tick);
  }

  @override
  void didUpdateWidget(_NowNextStrip old) {
    super.didUpdateWidget(old);
    if (old.stream.streamId != widget.stream.streamId) {
      liveGuide.unwant(old.portal, old.stream);
      liveGuide.want(widget.portal, widget.stream);
    }
  }

  @override
  void dispose() {
    liveGuide.clock.removeListener(_tick);
    liveGuide.unwant(widget.portal, widget.stream);
    super.dispose();
  }

  void _tick() => liveGuide.refresh(widget.portal, widget.stream);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<EpgEntry>?>(
        valueListenable: liveGuide.guideOf(widget.portal, widget.stream),
        builder: (context, guide, _) => ValueListenableBuilder<DateTime>(
          valueListenable: liveGuide.clock,
          builder: (context, _, _) {
            final t = DateTime.now();
            final nn = NowNext.of(guide ?? const [], t);
            final now = nn.now, next = nn.next;
            if (now == null) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Text('NOW  ', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: accentOf(context), letterSpacing: .6)),
                  Expanded(
                    child: Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  Text('${guideTime(now.start)} – ${guideTime(now.stop)}', style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
                ]),
                const SizedBox(height: 6),
                _Progress(nn.progress(t)),
                if (next != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Dopo  ${guideTime(next.start)}  ${next.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: VyseColors.textDim),
                  ),
                ],
              ],
            );
          },
        ),
      );
}
