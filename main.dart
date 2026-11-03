import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// Online prototype: pages are fetched from the Quran Android image host.
// Page images retain their source ownership. Confirm redistribution terms before release.
// Supply the real printed-book URL using --dart-define=PRINT_URL=https://...
const printUrl = String.fromEnvironment('PRINT_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MushafApp(prefs: prefs));
}

class MushafApp extends StatelessWidget {
  final SharedPreferences prefs;
  const MushafApp({super.key, required this.prefs});
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
    home: Reader(prefs: prefs),
  );
}

class Reader extends StatefulWidget {
  final SharedPreferences prefs;
  const Reader({super.key, required this.prefs});
  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> with WidgetsBindingObserver {
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
    page = (widget.prefs.getInt('lastPage') ?? 1).clamp(1, 604).toInt();
    goal = (widget.prefs.getInt('goal') ?? 5).clamp(1, 604).toInt();
    bookmarks = (widget.prefs.getStringList('bookmarks') ?? [])
        .map(int.tryParse).whereType<int>()
        .where((p) => p >= 1 && p <= 604).toSet();
    today = readToday();
    controller = PageController(initialPage: page - 1);
  }
  Set<int> readToday() => (widget.prefs.getStringList('read:${dateKey()}') ?? [])
      .map(int.tryParse).whereType<int>()
      .where((p) => p >= 1 && p <= 604).toSet();
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
    controller.jumpToPage(number.clamp(1, 604).toInt() - 1);
  }
  Future<void> choosePage() async {
    String input = '$page';
    final number = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('الانتقال إلى صفحة'),
      content: TextFormField(initialValue: input,
        onChanged: (value) => input = value,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'رقم من 1 إلى 604')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(onPressed: () {
          const arabic = '٠١٢٣٤٥٦٧٨٩';
          const persian = '۰۱۲۳۴۵۶۷۸۹';
          var normalized = input.trim();
          for (var i = 0; i < 10; i++) {
            normalized = normalized.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
          }
          final n = int.tryParse(normalized);
          if (n != null && n >= 1 && n <= 604) Navigator.pop(ctx, n);
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
    await storeBool(widget.prefs.setStringList('bookmarks', bookmarks.map((p) => '$p').toList()));
  }
  Future<void> markRead() async {
    final key = 'read:${dateKey()}';
    final completed = (widget.prefs.getStringList(key) ?? [])
        .map(int.tryParse).whereType<int>()
        .where((p) => p >= 1 && p <= 604).toSet()..add(page);
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
          itemCount: 604,
          onPageChanged: (index) {
            setState(() { page = index + 1; hidden = false; });
            storeBool(widget.prefs.setInt('lastPage', page));
          },
          itemBuilder: (ctx, index) {
            final name = (index + 1).toString().padLeft(3, '0');
            return Padding(padding: const EdgeInsets.all(12), child: Card(
              clipBehavior: Clip.antiAlias,
              child: hidden ? const Center(child: Text('استرجع الصفحة من ذاكرتك ثم اضغط «إظهار»')) :
              InteractiveViewer(minScale: 1, maxScale: 4,
                child: Center(child: Image.network(
                  'https://android.quran.com/data/width_1260/page$name.png',
                  fit: BoxFit.contain,
                  // Initial memory/clarity tradeoff; verify on real devices.
                  cacheWidth: 1260,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child : const Center(child: CircularProgressIndicator()),
                  errorBuilder: (_, error, stack) => Center(child: Padding(
                    padding: const EdgeInsets.all(24), child: Text(
                      'صفحة ${index + 1}\n\nتعذّر تحميل الصفحة.\nتحقق من اتصال الإنترنت ثم انتقل إلى صفحة أخرى وعُد إليها.',
                      textAlign: TextAlign.center))),
                ))),
            ));
          },
        )),
        Text('صفحة $page من 604', style: Theme.of(context).textTheme.titleMedium),
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
          IconButton(tooltip: 'الصفحة التالية', onPressed: repeat || page == 604 ? null : () => go(page + 1),
            icon: const Icon(Icons.arrow_forward)),
        ]),
        Padding(padding: const EdgeInsets.only(bottom: 16),
          child: FilledButton.icon(onPressed: markRead,
            icon: const Icon(Icons.check), label: const Text('أتممت قراءة هذه الصفحة'))),
      ])),
    );
  }
}
