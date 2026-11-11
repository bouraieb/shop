import 'package:adhan_dart/adhan_dart.dart';
import 'dart:math';
import 'dart:async';
import 'dart:typed_data';
import 'package:pdfx/pdfx.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// Six original PDFs bundled unchanged for offline reading.
const printUrl = String.fromEnvironment('PRINT_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  try {
    final document = await MushafDocuments.open();
    runApp(MushafApp(prefs: prefs, document: document));
  } catch (error) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('تعذّر فتح ملف المصحف المضمّن. أعد تثبيت النسخة الصحيحة.')))));
  }
}

class MushafDocuments {
  final List<PdfDocument> parts;
  MushafDocuments(this.parts);
  int get pagesCount => parts.fold(0, (total, part) => total + part.pagesCount);
  static Future<MushafDocuments> open() async {
    final parts = <PdfDocument>[];
    try {
      for (var i = 1; i <= 6; i++) {
        parts.add(await PdfDocument.openAsset('assets/BOOK_27070_$i.pdf'));
      }
      return MushafDocuments(parts);
    } catch (_) {
      for (final part in parts) { await part.close(); }
      rethrow;
    }
  }
  Future<PdfPage> getPage(int number) async {
    if (number < 1 || number > pagesCount) throw RangeError('Invalid page');
    var local = number;
    for (final part in parts) {
      if (local <= part.pagesCount) return await part.getPage(local);
      local -= part.pagesCount;
    }
    throw RangeError('Invalid page');
  }
}

class MushafApp extends StatelessWidget {
  final MushafDocuments document;
  final SharedPreferences prefs;
  const MushafApp({super.key, required this.prefs, required this.document});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'رفيق الورد',
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSansArabic',
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 18, height: 1.65),
        bodyMedium: TextStyle(fontSize: 16, height: 1.65),
        bodySmall: TextStyle(fontSize: 14, height: 1.6),
        titleLarge: TextStyle(fontSize: 23, height: 1.5, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: 19, height: 1.5, fontWeight: FontWeight.w600),
        labelLarge: TextStyle(fontSize: 16, height: 1.5, fontWeight: FontWeight.w600),
      ),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF17594A)),
      scaffoldBackgroundColor: const Color(0xFFF8F5EC),
    ),
    builder: (context, child) => Directionality(
      textDirection: TextDirection.rtl, child: child!),
    home: Reader(prefs: prefs, document: document),
  );
}

class Reader extends StatefulWidget {
  final MushafDocuments document;
  final SharedPreferences prefs;
  const Reader({super.key, required this.prefs, required this.document});
  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> with WidgetsBindingObserver {
  int get pageCount => widget.document.pagesCount;
  Timer? dateTimer;
  late String displayedDate;
  late final PageController controller;
  late int page;
  late int goal;
  late Set<int> bookmarks;
  late Set<int> today;
  bool hidden = false;
  bool repeat = false;
  String dateKey() {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }
  @override
  void initState() {
    super.initState();
    displayedDate = dateKey();
    WidgetsBinding.instance.addObserver(this);
    dateTimer = Timer.periodic(const Duration(seconds: 30), (_) => checkDate());
    page = (widget.prefs.getInt('sixPartsLastPageV1') ?? 1).clamp(1, pageCount).toInt();
    goal = (widget.prefs.getInt('goal') ?? 5).clamp(1, pageCount).toInt();
    bookmarks = (widget.prefs.getStringList('sixPartsBookmarksV1') ?? [])
        .map(int.tryParse).whereType<int>()
        .where((p) => p >= 1 && p <= pageCount).toSet();
    today = readToday();
    controller = PageController(initialPage: page - 1);
  }
  Set<int> readToday() => (widget.prefs.getStringList('sixPartsReadV1:${dateKey()}') ?? [])
      .map(int.tryParse).whereType<int>()
      .where((p) => p >= 1 && p <= pageCount).toSet();
  void checkDate() {
    if (!mounted || displayedDate == dateKey()) return;
    setState(() {
      displayedDate = dateKey();
      today = readToday();
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) checkDate();
  }
  @override
  void dispose() {
    dateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }
  void message(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
  Future<bool> storeBool(Future<bool> operation) async {
    try {
      if (await operation) return true;
    } catch (_) {
      // Show a single failure message, never a success after this failure.
    }
    message('تعذّر حفظ التغيير محليًا.');
    return false;
  }
  void go(int number) {
    if (!mounted || !controller.hasClients) return;
    controller.jumpToPage(number.clamp(1, pageCount).toInt() - 1);
  }
  Future<void> choosePage() async {
    String input = '$page';
    final number = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('الانتقال إلى صفحة'),
      content: TextFormField(initialValue: input,
        onChanged: (value) => input = value,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: 'رقم من 1 إلى $pageCount')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(onPressed: () {
          const arabic = '٠١٢٣٤٥٦٧٨٩';
          const persian = '۰۱۲۳۴۵۶۷۸۹';
          var normalized = input.trim();
          for (var i = 0; i < 10; i++) {
            normalized = normalized.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
          }
          final n = int.tryParse(normalized);
          if (n != null && n >= 1 && n <= pageCount) Navigator.pop(ctx, n);
        }, child: const Text('انتقال'))],
    ));
    if (number != null && mounted) go(number);
  }
  Future<void> chooseGoal() async {
    final result = await showDialog<int>(context: context, builder: (ctx) => SimpleDialog(
      title: const Text('الورد اليومي: عدد الصفحات'),
      children: [1, 2, 5, 10, 20].map((n) => SimpleDialogOption(
        onPressed: () => Navigator.pop(ctx, n), child: Text('$n صفحات'))).toList(),
    ));
    if (result != null && mounted) {
      setState(() => goal = result);
      await storeBool(widget.prefs.setInt('goal', goal));
    }
  }
  Future<void> showBookmarks() async {
    final pages = bookmarks.toList()..sort();
    final selected = await showDialog<int>(context: context, builder: (ctx) => SimpleDialog(
      title: const Text('العلامات المرجعية'),
      children: pages.isEmpty ? [const Padding(padding: EdgeInsets.all(24),
        child: Text('لم تضف علامة بعد.'))] : pages.map((p) => SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, p), child: Text('صفحة $p'))).toList(),
    ));
    if (selected != null && mounted) go(selected);
  }
  Future<void> toggleBookmark() async {
    setState(() { if (!bookmarks.add(page)) bookmarks.remove(page); });
    await storeBool(widget.prefs.setStringList('sixPartsBookmarksV1', bookmarks.map((p) => '$p').toList()));
  }
  Future<void> markRead() async {
    final key = 'sixPartsReadV1:${dateKey()}';
    final completed = (widget.prefs.getStringList(key) ?? [])
        .map(int.tryParse).whereType<int>()
        .where((p) => p >= 1 && p <= pageCount).toSet()..add(page);
    final saved = await storeBool(widget.prefs.setStringList(
        key, completed.map((p) => '$p').toList()));
    if (!mounted) return;
    setState(() { today = readToday(); });
    if (saved) message('تم تسجيل الصفحة ضمن ورد اليوم.');
  }
  Future<void> buy() async {
    final uri = Uri.tryParse(printUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      message('لم يُضف رابط شراء معتمد بعد.'); return;
    }
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) message('تعذّر فتح الرابط.');
    } catch (_) { message('تعذّر فتح الرابط.'); }
  }
  @override
  Widget build(BuildContext context) {
    final count = readToday().length;
    return Scaffold(
      appBar: AppBar(title: const Text('رفيق الورد'), actions: [
        IconButton(tooltip: 'العلامات', onPressed: showBookmarks, icon: const Icon(Icons.bookmarks_outlined)),
        IconButton(tooltip: 'انتقال لصفحة', onPressed: choosePage, icon: const Icon(Icons.find_in_page_outlined)),
        PopupMenuButton<String>(onSelected: (v) {
          if (v == 'adhkar') Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdhkarScreen()));
          if (v == 'prayers') Navigator.of(context).push(MaterialPageRoute(builder: (_) => PrayerScreen(prefs: widget.prefs)));
          if (v == 'goal') chooseGoal();
          if (v == 'buy') buy();
        }, itemBuilder: (_) => const [
          PopupMenuItem(value: 'adhkar', child: Text('أذكار الصباح والمساء والنوم')),
          PopupMenuItem(value: 'prayers', child: Text('مواقيت الصلاة')),
          PopupMenuItem(value: 'goal', child: Text('ضبط الورد اليومي')),
          PopupMenuItem(value: 'buy', child: Text('شراء النسخة المطبوعة')),
        ]),
      ]),
      body: SafeArea(child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(children: [
            Text('ورد اليوم: $count من $goal صفحات'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: min(1.0, count / goal)),
          ])),
        Expanded(child: PageView.builder(
          controller: controller,
          physics: repeat ? const NeverScrollableScrollPhysics() : null,
          itemCount: pageCount,
          onPageChanged: (index) {
            setState(() { page = index + 1; hidden = false; });
            storeBool(widget.prefs.setInt('sixPartsLastPageV1', page));
          },
          itemBuilder: (ctx, index) {
            return Padding(padding: const EdgeInsets.all(12), child: Card(
              clipBehavior: Clip.antiAlias,
              child: hidden ? const Center(child: Text('استرجع الصفحة من ذاكرتك ثم اضغط «إظهار»')) :
              OfflinePdfPage(document: widget.document, number: index + 1),
            ));
          },
        )),
        Text('صفحة PDF $page من $pageCount', style: Theme.of(context).textTheme.titleMedium),
        Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
          IconButton(tooltip: 'الصفحة السابقة', onPressed: repeat || page == 1 ? null : () => go(page - 1),
            icon: const Icon(Icons.arrow_back)),
          IconButton(tooltip: 'إضافة أو إزالة علامة', onPressed: toggleBookmark,
            icon: Icon(bookmarks.contains(page) ? Icons.bookmark : Icons.bookmark_border)),
          TextButton.icon(onPressed: () => setState(() => hidden = !hidden),
            icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
            label: Text(hidden ? 'إظهار' : 'إخفاء')),
          IconButton(tooltip: 'تثبيت الصفحة للمراجعة، بلا صوت',
            onPressed: () => setState(() => repeat = !repeat),
            icon: Icon(Icons.repeat, color: repeat ? Theme.of(context).colorScheme.primary : null)),
          IconButton(tooltip: 'الصفحة التالية', onPressed: repeat || page == pageCount ? null : () => go(page + 1),
            icon: const Icon(Icons.arrow_forward)),
        ]),
        Padding(padding: const EdgeInsets.only(bottom: 16),
          child: FilledButton.icon(onPressed: markRead,
            icon: const Icon(Icons.check), label: const Text('أتممت قراءة هذه الصفحة'))),
      ])),
    );
  }
}

// Render pages serially; keep no network dependency for reading.
class OfflinePdfPage extends StatefulWidget {
  final MushafDocuments document;
  final int number;
  const OfflinePdfPage({super.key, required this.document, required this.number});
  @override
  State<OfflinePdfPage> createState() => _OfflinePdfPageState();
}
class _OfflinePdfPageState extends State<OfflinePdfPage> {
  static Future<void> queue = Future<void>.value();
  late Future<Uint8List> image;
  @override
  void initState() { super.initState(); image = load(); }
  Future<Uint8List> load() {
    final completer = Completer<Uint8List>();
    queue = queue.then((_) async {
      try {
        final pdfPage = await widget.document.getPage(widget.number);
        try {
          final rendered = await pdfPage.render(
            width: 1800,
            height: 1800 * pdfPage.height / pdfPage.width,
            format: PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF',
          );
          if (rendered == null) throw StateError('PDF rendering failed');
          completer.complete(rendered.bytes);
        } finally { await pdfPage.close(); }
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: image,
    builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: TextButton(
        onPressed: () => setState(() { image = load(); }),
        child: const Text('تعذّر عرض الصفحة. اضغط لإعادة المحاولة.'),
      ));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      return InteractiveViewer(minScale: 1, maxScale: 5,
        child: Center(child: Image.memory(snapshot.data!, fit: BoxFit.contain)));
    },
  );
}


// Lightweight vector ornament: no image downloads, assets, or extra packages.
class OrnamentDivider extends StatelessWidget {
  const OrnamentDivider({super.key});
  @override
  Widget build(BuildContext context) => const Row(children: [
    Expanded(child: Divider(color: Color(0xFFB89B60), indent: 12, endIndent: 12)),
    SizedBox(width: 24, height: 24, child: CustomPaint(painter: StarOrnamentPainter())),
    Expanded(child: Divider(color: Color(0xFFB89B60), indent: 12, endIndent: 12)),
  ]);
}
class StarOrnamentPainter extends CustomPainter {
  const StarOrnamentPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFB89B60)..style = PaintingStyle.stroke..strokeWidth = 1.2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCenter(center: center, width: size.shortestSide * .58, height: size.shortestSide * .58);
    canvas.drawRect(rect, paint);
    canvas.save(); canvas.translate(center.dx, center.dy); canvas.rotate(pi / 4); canvas.translate(-center.dx, -center.dy);
    canvas.drawRect(rect, paint); canvas.restore();
  }
  @override
  bool shouldRepaint(covariant StarOrnamentPainter oldDelegate) => false;
}

class DhikrItem {
  final String text, source;
  final int count;
  const DhikrItem(this.text, this.count, this.source);
}
class AdhkarScreen extends StatelessWidget {
  const AdhkarScreen({super.key});
  static const shared = [
    DhikrItem('اللَّهُمَّ أَنْتَ رَبِّي، لَا إِلَهَ إِلَّا أَنْتَ، خَلَقْتَنِي وَأَنَا عَبْدُكَ، وَأَنَا عَلَى عَهْدِكَ وَوَعْدِكَ مَا اسْتَطَعْتُ، أَعُوذُ بِكَ مِنْ شَرِّ مَا صَنَعْتُ، أَبُوءُ لَكَ بِنِعْمَتِكَ عَلَيَّ، وَأَبُوءُ لَكَ بِذَنْبِي، فَاغْفِرْ لِي، فَإِنَّهُ لَا يَغْفِرُ الذُّنُوبَ إِلَّا أَنْتَ.', 1, 'سيد الاستغفار · صحيح البخاري، 6306'),
    DhikrItem('بِسْمِ اللَّهِ الَّذِي لَا يَضُرُّ مَعَ اسْمِهِ شَيْءٌ فِي الْأَرْضِ وَلَا فِي السَّمَاءِ وَهُوَ السَّمِيعُ الْعَلِيمُ.', 3, 'سنن أبي داود، 5088'),
    DhikrItem('اللَّهُمَّ عَافِنِي فِي بَدَنِي، اللَّهُمَّ عَافِنِي فِي سَمْعِي، اللَّهُمَّ عَافِنِي فِي بَصَرِي، لَا إِلَهَ إِلَّا أَنْتَ.', 3, 'سنن أبي داود، 5090'),
    DhikrItem('اللَّهُمَّ إِنِّي أَعُوذُ بِكَ مِنَ الْكُفْرِ وَالْفَقْرِ، اللَّهُمَّ إِنِّي أَعُوذُ بِكَ مِنْ عَذَابِ الْقَبْرِ، لَا إِلَهَ إِلَّا أَنْتَ.', 3, 'سنن أبي داود، 5090'),
  ];
  static const morning = [
    ...shared,
    DhikrItem('سُبْحَانَ اللَّهِ وَبِحَمْدِهِ', 100, 'صحيح مسلم، 2692'),
    DhikrItem('رَضِيتُ بِاللَّهِ رَبًّا، وَبِالإِسْلَامِ دِينًا، وَبِمُحَمَّدٍ صَلَّى اللَّهُ عَلَيْهِ وَسَلَّمَ نَبِيًّا.', 3, 'مشكاة المصابيح، 2399، نقلًا عن أحمد وأبي داود والترمذي'),
    DhikrItem('اللَّهُمَّ بِكَ أَصْبَحْنَا، وَبِكَ أَمْسَيْنَا، وَبِكَ نَحْيَا، وَبِكَ نَمُوتُ، وَإِلَيْكَ النُّشُورُ.', 1, 'سنن أبي داود، 5068'),
  ];
  static const evening = [
    ...shared,
    DhikrItem('سُبْحَانَ اللَّهِ وَبِحَمْدِهِ', 100, 'صحيح مسلم، 2692'),
    DhikrItem('رَضِيتُ بِاللَّهِ رَبًّا، وَبِالإِسْلَامِ دِينًا، وَبِمُحَمَّدٍ صَلَّى اللَّهُ عَلَيْهِ وَسَلَّمَ نَبِيًّا.', 3, 'مشكاة المصابيح، 2399، نقلًا عن أحمد وأبي داود والترمذي'),
    DhikrItem('اللَّهُمَّ بِكَ أَمْسَيْنَا، وَبِكَ أَصْبَحْنَا، وَبِكَ نَحْيَا، وَبِكَ نَمُوتُ، وَإِلَيْكَ الْمَصِيرُ.', 1, 'سنن أبي داود، 5068'),
    DhikrItem('أَعُوذُ بِكَلِمَاتِ اللَّهِ التَّامَّاتِ مِنْ شَرِّ مَا خَلَقَ.', 1, 'صحيح مسلم، 2709'),
  ];
  static const sleep = [
    DhikrItem('بِاسْمِكَ رَبِّ وَضَعْتُ جَنْبِي، وَبِكَ أَرْفَعُهُ، إِنْ أَمْسَكْتَ نَفْسِي فَارْحَمْهَا، وَإِنْ أَرْسَلْتَهَا فَاحْفَظْهَا بِمَا تَحْفَظُ بِهِ عِبَادَكَ الصَّالِحِينَ.', 1, 'صحيح البخاري، 6320'),
    DhikrItem('بِاسْمِكَ اللَّهُمَّ أَمُوتُ وَأَحْيَا.', 1, 'صحيح البخاري، 6324'),
    DhikrItem('سُبْحَانَ اللَّهِ', 33, 'صحيح البخاري، 6318'),
    DhikrItem('الْحَمْدُ لِلَّهِ', 33, 'صحيح البخاري، 6318'),
    DhikrItem('اللَّهُ أَكْبَرُ', 34, 'صحيح البخاري، 6318'),
    DhikrItem('اللَّهُمَّ أَسْلَمْتُ وَجْهِي إِلَيْكَ، وَفَوَّضْتُ أَمْرِي إِلَيْكَ، وَأَلْجَأْتُ ظَهْرِي إِلَيْكَ، رَغْبَةً وَرَهْبَةً إِلَيْكَ، لَا مَلْجَأَ وَلَا مَنْجَا مِنْكَ إِلَّا إِلَيْكَ، آمَنْتُ بِكِتَابِكَ الَّذِي أَنْزَلْتَ، وَبِنَبِيِّكَ الَّذِي أَرْسَلْتَ.', 1, 'صحيح البخاري، 6311 · بعد الوضوء والاضطجاع على الجانب الأيمن؛ يُجعل آخر ما يقال'),
  ];
  @override
  Widget build(BuildContext context) => DefaultTabController(length: 3, child: Scaffold(
    appBar: AppBar(title: const Text('الأذكار'), centerTitle: true, bottom: TabBar(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: BoxDecoration(color: const Color(0xFF123E36), borderRadius: BorderRadius.circular(24)),
      labelColor: Colors.white, unselectedLabelColor: const Color(0xFF123E36),
      dividerColor: Colors.transparent, tabs: const [Tab(text: 'الصباح'), Tab(text: 'المساء'), Tab(text: 'النوم')])),
    body: const TabBarView(physics: NeverScrollableScrollPhysics(), children: [DhikrList(items: morning), DhikrList(items: evening), DhikrList(items: sleep)]),
  ));
}
class DhikrList extends StatefulWidget {
  final List<DhikrItem> items;
  const DhikrList({super.key, required this.items});
  @override
  State<DhikrList> createState() => _DhikrListState();
}
class _DhikrListState extends State<DhikrList> with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static final sharedFont = ValueNotifier<double>(23);
  Timer? dayTimer;
  Future<void> saveQueue = Future<void>.value();
  void syncFont() { if (mounted) setState(() => fontSize = sharedFont.value); }
  void checkDay() {
    if (!mounted || savedPrefs == null || loadedDay == dayKey) return;
    final day = dayKey;
    setState(() {
      loadedDay = day;
      for (var i = 0; i < widget.items.length; i++) {
        counts[i] = (savedPrefs!.getInt('$storageKey:$day:$i') ?? 0).clamp(0, widget.items[i].count).toInt();
      }
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) checkDay();
  }
  final Map<int, int> counts = {};
  final PageController cards = PageController();
  int activeCard = 0;
  @override
  void dispose() { dayTimer?.cancel(); WidgetsBinding.instance.removeObserver(this); sharedFont.removeListener(syncFont); cards.dispose(); super.dispose(); }
  double fontSize = 23;
  SharedPreferences? savedPrefs;
  String loadedDay = '';
  String get storageKey => 'adhkar:${identical(widget.items, AdhkarScreen.morning) ? "morning" : identical(widget.items, AdhkarScreen.evening) ? "evening" : "sleep"}';
  String get dayKey { final d = DateTime.now(); return '${d.year}-${d.month}-${d.day}'; }
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sharedFont.addListener(syncFont);
    dayTimer = Timer.periodic(const Duration(seconds: 1), (_) => checkDay());
    restoreCounts();
  }
  Future<void> restoreCounts() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    sharedFont.value = (p.getDouble('adhkarFontSize') ?? 23).clamp(18, 34).toDouble();
    final day = dayKey;
    setState(() { loadedDay = day; savedPrefs = p; fontSize = sharedFont.value; for (var i = 0; i < widget.items.length; i++) { counts[i] = (p.getInt('$storageKey:$day:$i') ?? 0).clamp(0, widget.items[i].count).toInt(); } });
  }
  Future<void> changeCount(int index, {bool reset = false}) {
    if (savedPrefs == null || !mounted) return Future<void>.value();
    checkDay();
    final prefs = savedPrefs!;
    final day = loadedDay;
    final key = '$storageKey:$day:$index';
    final limit = widget.items[index].count;
    saveQueue = saveQueue.then((_) async {
      try {
        final previous = (prefs.getInt(key) ?? 0).clamp(0, limit).toInt();
        final value = reset ? 0 : min(previous + 1, limit);
        if (!await prefs.setInt(key, value)) throw StateError('Save failed');
        if (mounted && loadedDay == day) setState(() => counts[index] = value);
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذّر حفظ العدّاد. أعد المحاولة.')));
      }
    });
    return saveQueue;
  }
  Future<void> saveFont(double value) async {
    try {
      if (savedPrefs == null || !await savedPrefs!.setDouble('adhkarFontSize', value)) throw StateError('Save failed');
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذّر حفظ حجم الخط.')));
    }
  }
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
        const Icon(Icons.text_fields, color: Color(0xFF123E36)),
        Expanded(child: Slider(min: 18, max: 34, divisions: 16, label: '${fontSize.round()}', value: fontSize,
          onChanged: savedPrefs == null ? null : (v) => sharedFont.value = v,
          onChangeEnd: saveFont)),
      ])),
      Expanded(child: PageView.builder(controller: cards, itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => activeCard = i),
        itemBuilder: (ctx, i) {
          final item = widget.items[i];
          final count = counts[i] ?? 0;
          final complete = count >= item.count;
          return SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: const Color(0xFFFFFCF4), borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFFCFBD94))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('الذِّكر ${i + 1} من ${widget.items.length}', textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF776747), fontSize: 14)),
              const SizedBox(height: 20),
              Text(item.text, textAlign: TextAlign.center, style: TextStyle(fontFamily: 'NotoNaskhArabic', fontSize: fontSize,
                fontWeight: FontWeight.w500, height: 2.0, color: const Color(0xFF123E36))),
              const SizedBox(height: 16),
              Text(item.source, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 24),
              Center(child: Semantics(button: true, label: 'عداد الذكر: $count من ${item.count}',
                child: SizedBox(width: 152, height: 152, child: Stack(alignment: Alignment.center, children: [
                  SizedBox(width: 152, height: 152, child: CircularProgressIndicator(
                    value: count / item.count, strokeWidth: 5, backgroundColor: const Color(0xFFE9E0CA), color: const Color(0xFFB89B60))),
                  SizedBox(width: 134, height: 134, child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF123E36), disabledBackgroundColor: const Color(0xFF275A4E),
                      disabledForegroundColor: Colors.white, shape: const CircleBorder(), padding: const EdgeInsets.all(8)),
                    onPressed: savedPrefs == null || complete ? null : () => changeCount(i),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(complete ? '✓' : '$count', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                      Text(complete ? 'اكتمل' : 'من ${item.count}', style: const TextStyle(fontSize: 16)),
                    ]))),
                ])))),
              const SizedBox(height: 12),
              TextButton.icon(onPressed: savedPrefs == null || count == 0 ? null : () => changeCount(i, reset: true),
                icon: const Icon(Icons.restart_alt), label: const Text('إعادة عدّ هذا الذكر')),
            ])));
        })),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: Column(children: [
        LinearProgressIndicator(value: (activeCard + 1) / widget.items.length, color: const Color(0xFF123E36), backgroundColor: const Color(0xFFE9E0CA)),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          TextButton(onPressed: activeCard == 0 ? null : () => cards.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut), child: const Text('السابق')),
          Text('${activeCard + 1} / ${widget.items.length}'),
          TextButton(onPressed: activeCard == widget.items.length - 1 ? null : () => cards.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut), child: const Text('التالي')),
        ]),
        const Text('تُحفظ العدادات لهذا اليوم على جهازك', style: TextStyle(fontSize: 12)),
      ]))),
    ]);
  }
}

class PrayerScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const PrayerScreen({super.key, required this.prefs});
  @override
  State<PrayerScreen> createState() => _PrayerScreenState();
}
class _PrayerScreenState extends State<PrayerScreen> with WidgetsBindingObserver {
  // Coordinates are approximate city centers. The offset is explicitly editable.
  static const cities = <String, List<double>>{
    'الجزائر': [36.7538, 3.0588], 'وهران': [35.6971, -0.6308],
    'قسنطينة': [36.365, 6.6147], 'عنابة': [36.9, 7.7667],
    'سطيف': [36.19, 5.41], 'باتنة': [35.55, 6.17],
    'تلمسان': [34.8828, -1.3167], 'ورقلة': [31.95, 5.33],
    'غرداية': [32.49, 3.67], 'تمنراست': [22.79, 5.52],
  };
  static const labels = ['الفجر', 'الشروق', 'الظهر', 'العصر', 'المغرب', 'العشاء'];
  late String city;
  late double latitude, longitude, utcOffset;
  late List<int> adjustments;
  late bool customAngles;
  late double fajrAngle, ishaAngle;
  DateTime date = DateTime.now();
  bool followToday = true;
  late bool followPhoneZone;
  Timer? clockTimer;
  double get effectiveOffset => followPhoneZone ? DateTime.now().timeZoneOffset.inMinutes / 60.0 : utcOffset;
  DateTime cityNow() => DateTime.now().toUtc().add(Duration(minutes: (effectiveOffset * 60).round()));
  void tick() {
    if (!mounted) return;
    setState(() { if (followToday) date = cityNow(); });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) tick(); }
  @override
  void dispose() { clockTimer?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void initState() {
    super.initState();
    final p = widget.prefs;
    followPhoneZone = p.getBool('prayerFollowPhoneZone') ?? true;
    city = p.getString('prayerCity') ?? 'الجزائر';
    latitude = p.getDouble('prayerLat') ?? 36.7538;
    longitude = p.getDouble('prayerLon') ?? 3.0588;
    utcOffset = p.getDouble('prayerUtc') ?? 1;
    customAngles = p.getBool('prayerCustomAngles') ?? false;
    fajrAngle = p.getDouble('prayerFajrAngle') ?? 18;
    ishaAngle = p.getDouble('prayerIshaAngle') ?? 17;
    adjustments = List.generate(6, (i) => p.getInt('prayerAdjust$i') ?? 0);
    date = cityNow();
    WidgetsBinding.instance.addObserver(this);
    clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }
  Future<void> save() async {
    try {
      final p = widget.prefs;
      final results = await Future.wait([
        p.setBool('prayerFollowPhoneZone', followPhoneZone),
        p.setString('prayerCity', city), p.setDouble('prayerLat', latitude),
        p.setDouble('prayerLon', longitude), p.setDouble('prayerUtc', utcOffset),
        p.setBool('prayerCustomAngles', customAngles),
        p.setDouble('prayerFajrAngle', fajrAngle), p.setDouble('prayerIshaAngle', ishaAngle),
        for (var i = 0; i < 6; i++) p.setInt('prayerAdjust$i', adjustments[i]),
      ]);
      if (results.any((ok) => !ok)) throw StateError('Save failed');
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذّر حفظ إعدادات المواقيت.')));
    }
  }
  Future<void> settings() async {
    final name = TextEditingController(text: city);
    final lat = TextEditingController(text: '$latitude');
    final lon = TextEditingController(text: '$longitude');
    final offset = TextEditingController(text: '$utcOffset');
    final fajr = TextEditingController(text: '$fajrAngle');
    final isha = TextEditingController(text: '$ishaAngle');
    var useCustom = customAngles;
    var usePhoneZone = followPhoneZone;
    final corrections = List.generate(6, (i) => TextEditingController(text: '${adjustments[i]}'));
    String? error;
    double? number(String text) {
      var value = text.trim().replaceAll('٫', '.').replaceAll(',', '.').replaceAll('−', '-');
      for (var i = 0; i < 10; i++) { value = value.replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i').replaceAll('۰۱۲۳۴۵۶۷۸۹'[i], '$i'); }
      return double.tryParse(value);
    }
    Widget field(String label, TextEditingController c) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: label)));
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      title: const Text('إعدادات مواقيت الصلاة'),
      content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(hint: const Text('اختيار مدينة جزائرية'), items: cities.keys.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(), onChanged: (c) { if (c == null) return; name.text = c; lat.text = '${cities[c]![0]}'; lon.text = '${cities[c]![1]}'; offset.text = '1'; }),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('استخدام توقيت الهاتف تلقائيًا'), subtitle: const Text('عطّله إذا كنت تعرض مدينة في منطقة زمنية مختلفة عن الهاتف.'), value: usePhoneZone, onChanged: (v) => update(() => usePhoneZone = v)),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم المدينة')),
        field('خط العرض (-90 إلى 90)', lat), field('خط الطول (-180 إلى 180)', lon), field('فرق التوقيت عن UTC، مثال الجزائر: 1', offset),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('زوايا حساب مخصصة'), subtitle: const Text('الافتراضي: رابطة العالم الإسلامي، الفجر 18° والعشاء 17°'), value: useCustom, onChanged: (v) => update(() => useCustom = v)),
        if (useCustom) ...[field('زاوية الفجر', fajr), field('زاوية العشاء', isha)],
        const Text('تصحيح بالدقائق لكل وقت، موجب للتأخير وسالب للتقديم. طابق المواقيت مع الجهة المحلية المعتمدة.'),
        for (var i = 0; i < 6; i++) field('تصحيح ${labels[i]}', corrections[i]),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')), FilledButton(onPressed: () {
        final a = number(lat.text), b = number(lon.text), z = number(offset.text);
        final f = number(fajr.text), s = number(isha.text);
        final values = corrections.map((c) => number(c.text)).toList();
        if (name.text.trim().isEmpty || a == null || !a.isFinite || a.abs() > 90 || b == null || !b.isFinite || b.abs() > 180 || z == null || !z.isFinite || z < -12 || z > 14 || f == null || !f.isFinite || f <= 0 || f > 30 || s == null || !s.isFinite || s <= 0 || s > 30 || values.any((n) => n == null || !n.isFinite || n.abs() > 180 || n != n.roundToDouble())) {
          update(() => error = 'تحقق من القيم. التصحيح عدد صحيح بين -180 و180.'); return;
        }
        setState(() { city = name.text.trim(); latitude = a; longitude = b; utcOffset = z; followPhoneZone = usePhoneZone; if (followToday) date = cityNow(); customAngles = useCustom; fajrAngle = f; ishaAngle = s; adjustments = values.map((n) => n!.toInt()).toList(); });
        Navigator.pop(ctx, true);
      }, child: const Text('حفظ'))],
    )));
    // Dispose after the closing dialog animation has released its text fields.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final c in [name, lat, lon, offset, fajr, isha, ...corrections]) { c.dispose(); }
    if (accepted == true) await save();
  }
  final Map<String, List<DateTime>> prayerCache = {};
  List<DateTime> times([DateTime? requestedDate]) {
    final calculationDate = requestedDate ?? date;
    final key = '${calculationDate.year}-${calculationDate.month}-${calculationDate.day}:$latitude:$longitude:$customAngles:$fajrAngle:$ishaAngle';
    final cached = prayerCache[key];
    if (cached != null) return cached;
    final params = CalculationMethodParameters.muslimWorldLeague();
    if (customAngles) { params.fajrAngle = fajrAngle; params.ishaAngle = ishaAngle; }
    final t = PrayerTimes(coordinates: Coordinates(latitude, longitude), date: DateTime(calculationDate.year, calculationDate.month, calculationDate.day), calculationParameters: params);
    final result = [t.fajr, t.sunrise, t.dhuhr, t.asr, t.maghrib, t.isha];
    if (prayerCache.length >= 4) prayerCache.clear();
    prayerCache[key] = result;
    return result;
  }
  Widget nextPrayerCard(List<DateTime> todayTimes) {
    try {
      final now = DateTime.now().toUtc();
      final candidates = <MapEntry<int, DateTime>>[];
      for (final day in [date, DateTime(date.year, date.month, date.day + 1)]) {
        final daily = day == date ? todayTimes : times(day);
        for (final i in [0, 2, 3, 4, 5]) {
          final instant = daily[i].toUtc().add(Duration(minutes: adjustments[i]));
          if (instant.isAfter(now)) candidates.add(MapEntry(i, instant));
        }
      }
      candidates.sort((a, b) => a.value.compareTo(b.value));
      if (candidates.isEmpty) return const SizedBox.shrink();
      final next = candidates.first;
      final remaining = next.value.difference(now);
      final hours = remaining.inHours.toString().padLeft(2, '0');
      final minutes = (remaining.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (remaining.inSeconds % 60).toString().padLeft(2, '0');
      return Container(margin: const EdgeInsets.only(bottom: 18), padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF123E36), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFB89B60))), child: Column(children: [
        const Icon(Icons.mosque_outlined, color: Color(0xFFF1D8A4), size: 30),
        const SizedBox(height: 8),
        Text('الصلاة القادمة: ${labels[next.key]}', style: const TextStyle(color: Colors.white, fontSize: 21)),
        Text(format(next.value.subtract(Duration(minutes: adjustments[next.key])), next.key), textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('$hours:$minutes:$seconds', textDirection: TextDirection.ltr, style: const TextStyle(color: Color(0xFFF1D8A4), fontSize: 30, fontWeight: FontWeight.bold)),
        const Text('الوقت المتبقي حسب المواقيت المحسوبة وإعداداتك', style: TextStyle(color: Colors.white)),
      ]));
    } catch (_) { return const Text('تعذّر تحديد الصلاة القادمة لهذه الإعدادات.'); }
  }
  String format(DateTime time, int index) {
    final local = time.toUtc().add(Duration(minutes: (effectiveOffset * 60).round() + adjustments[index]));
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  @override
  Widget build(BuildContext context) {
    List<DateTime>? values;
    try { values = times(); } catch (_) { values = null; }
    return Scaffold(appBar: AppBar(title: const Text('مواقيت الصلاة'), actions: [IconButton(onPressed: settings, tooltip: 'المدينة وطريقة الحساب', icon: const Icon(Icons.settings))]), body: ListView(padding: const EdgeInsets.all(20), children: [
      const Icon(Icons.location_on_outlined, color: Color(0xFF123E36), size: 28),
      const SizedBox(height: 8),
      Text(city, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: const Color(0xFF123E36), fontWeight: FontWeight.bold)),
      Text('${date.year}/${date.month}/${date.day} · UTC ${effectiveOffset >= 0 ? "+" : ""}$effectiveOffset'),
      Text('الساعة الآن: ${cityNow().hour.toString().padLeft(2, "0")}:${cityNow().minute.toString().padLeft(2, "0")}:${cityNow().second.toString().padLeft(2, "0")} · ${followPhoneZone ? "توقيت الهاتف" : "توقيت يدوي"}'),
      if (!followToday) TextButton(onPressed: () => setState(() { followToday = true; date = cityNow(); }), child: const Text('العودة إلى مواقيت اليوم التلقائية')),
      TextButton.icon(icon: const Icon(Icons.calendar_month), label: const Text('اختيار يوم'), onPressed: () async {
        final result = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime(2100));
        if (result != null && mounted) setState(() { followToday = false; date = result; });
      }),
      Text(customAngles ? 'حساب بزوايا مخصصة: الفجر $fajrAngle°، العشاء $ishaAngle°' : 'طريقة الحساب: رابطة العالم الإسلامي'),
      const Text('العصر: ظل المثل. مواقيت حسابية وليست رزنامة رسمية. تحقق من إعداد المدينة والتوقيت الصيفي وطابقها مع المسجد المحلي. لا توجد تنبيهات أو أذان صوتي في هذه النسخة.'),
      const SizedBox(height: 12),
      if (followToday && values != null) nextPrayerCard(values),
      if (values == null) const Text('تعذّر حساب المواقيت لهذه الإعدادات. راجع المدينة والزوايا.')
      else for (var i = 0; i < 6; i++) Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(color: const Color(0xFFFFFCF4), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFB89B60))),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16), child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 24, runSpacing: 8, children: [
          Text(labels[i], style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: Color(0xFF123E36))),
          Text(format(values[i], i), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF123E36))),
        ]))),
      const Card(child: Padding(padding: EdgeInsets.all(16), child: Row(children: [
        Icon(Icons.volume_off_outlined, color: Color(0xFF776747)), SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('الأذان التلقائي', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('غير مضاف بعد؛ يحتاج تسجيل الأذان وإعداد تنبيهات الخلفية', style: TextStyle(fontSize: 13)),
        ])),
      ]))),
      const Padding(padding: EdgeInsets.only(top: 16), child: Text('الحساب يعمل دون إنترنت. يمكنك تغيير المدينة أو إدخال إحداثيات أي مدينة من الإعدادات.')),
    ]));
  }
}
