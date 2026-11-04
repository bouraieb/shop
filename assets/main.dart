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
          if (v == 'goal') chooseGoal();
          if (v == 'buy') buy();
        }, itemBuilder: (_) => const [
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
