import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'guides.dart';

const int kFreeLimit = 5;
const List<String> kCycles = ['Weekly', 'Monthly', 'Yearly'];
const List<String> kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String fmtDate(DateTime d) => '${kMonths[d.month - 1]} ${d.day}, ${d.year}';

String fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final suffix = d.hour < 12 ? 'AM' : 'PM';
  return '$h:$m $suffix';
}

String fmtMoney(double v, String cur) => '$cur${v.toStringAsFixed(2)}';

String timeLeft(DateTime d) {
  final diff = d.difference(DateTime.now());
  if (diff.isNegative) return 'now';
  if (diff.inHours < 24) return '${diff.inHours}h left';
  return '${diff.inDays}d left';
}

DateTime _addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final y = d.year + total ~/ 12;
  final m = total % 12 + 1;
  final last = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, d.day < last ? d.day : last, d.hour, d.minute);
}

DateTime advance(DateTime d, String cycle) {
  switch (cycle) {
    case 'Weekly':
      return d.add(const Duration(days: 7));
    case 'Yearly':
      return _addMonths(d, 12);
    default:
      return _addMonths(d, 1);
  }
}

int byDate(Sub a, Sub b) => a.nextBill.compareTo(b.nextBill);

int newId() => (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 200000000;

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

class Sub {
  final int id;
  String name;
  double cost;
  String cycle;
  String card;
  DateTime nextBill; // for a trial: the moment it starts charging
  bool isTrial;

  Sub({
    required this.id,
    required this.name,
    required this.cost,
    required this.cycle,
    required this.card,
    required this.nextBill,
    required this.isTrial,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cost': cost,
        'cycle': cycle,
        'card': card,
        'nextBill': nextBill.toIso8601String(),
        'isTrial': isTrial,
      };

  factory Sub.fromJson(Map<String, dynamic> j) => Sub(
        id: j['id'] as int,
        name: j['name'] as String,
        cost: (j['cost'] as num).toDouble(),
        cycle: (j['cycle'] ?? 'Monthly') as String,
        card: (j['card'] ?? '') as String,
        nextBill: DateTime.parse(j['nextBill'] as String),
        isTrial: (j['isTrial'] ?? false) as bool,
      );

  double get monthlyCost {
    switch (cycle) {
      case 'Weekly':
        return cost * 52 / 12;
      case 'Yearly':
        return cost / 12;
      default:
        return cost;
    }
  }

  double get yearlyCost => monthlyCost * 12;
}

class AppStore extends ChangeNotifier {
  List<Sub> subs = [];
  bool premium = false;
  String currency = r'$';
  late SharedPreferences prefs;

  double get monthlyTotal =>
      subs.where((s) => !s.isTrial).fold<double>(0, (a, s) => a + s.monthlyCost);

  Future<void> load() async {
    prefs = await SharedPreferences.getInstance();
    premium = prefs.getBool('premium') ?? false;
    currency = prefs.getString('currency') ?? r'$';
    final raw = prefs.getString('subs');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        subs = list
            .map((e) => Sub.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        subs = [];
      }
    }
    _rollForward();
  }

  void _rollForward() {
    final now = DateTime.now();
    for (final s in subs) {
      while (s.nextBill.isBefore(now)) {
        if (s.isTrial) s.isTrial = false; // the trial ended and billing began
        s.nextBill = advance(s.nextBill, s.cycle);
      }
    }
  }

  Future<void> _persist() async {
    await prefs.setString(
        'subs', jsonEncode(subs.map((s) => s.toJson()).toList()));
    await prefs.setBool('premium', premium);
    await prefs.setString('currency', currency);
  }

  Future<void> _commit() async {
    notifyListeners();
    await _persist();
    rescheduleAll(subs, currency);
  }

  Future<void> upsert(Sub s) async {
    final i = subs.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      subs[i] = s;
    } else {
      subs.add(s);
    }
    await _commit();
  }

  Future<void> remove(int id) async {
    subs.removeWhere((s) => s.id == id);
    await _commit();
  }

  Future<void> setCurrency(String c) async {
    currency = c;
    notifyListeners();
    await prefs.setString('currency', currency);
  }

  Future<void> setPremium(bool v) async {
    premium = v;
    await _commit();
  }

  String backupJson() => jsonEncode({
        'v': 1,
        'currency': currency,
        'subs': subs.map((s) => s.toJson()).toList(),
      });

  Future<bool> restoreJson(String raw) async {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = map['subs'] as List;
      final parsed = list
          .map((e) => Sub.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      subs = parsed;
      currency = (map['currency'] ?? currency) as String;
      _rollForward();
      await _commit();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearAll() async {
    subs = [];
    await _commit();
  }
}

final AppStore store = AppStore();

// ---------------------------------------------------------------------------
// Notifications (local only, no internet needed)
// ---------------------------------------------------------------------------

final FlutterLocalNotificationsPlugin notifs =
    FlutterLocalNotificationsPlugin();
bool notifsReady = false;

const NotificationDetails kAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'trial_alerts',
    'Trial and renewal alerts',
    channelDescription: 'Warnings before free trials convert and bills renew',
    importance: Importance.max,
    priority: Priority.high,
    autoCancel: false,
  ),
);

Future<void> initNotifications() async {
  try {
    tzdata.initializeTimeZones();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await notifs.initialize(settings);
    final android = notifs.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    notifsReady = true;
  } catch (_) {
    notifsReady = false;
  }
}

Future<void> rescheduleAll(List<Sub> subs, String cur) async {
  if (!notifsReady) return;
  try {
    await notifs.cancelAll();
    final now = DateTime.now();
    for (final s in subs) {
      final offsets = s.isTrial ? [48, 24, 2] : [24];
      for (var k = 0; k < offsets.length; k++) {
        final h = offsets[k];
        final when = s.nextBill.subtract(Duration(hours: h));
        if (!when.isAfter(now)) continue;
        final price = fmtMoney(s.cost, cur);
        final title = s.isTrial
            ? 'Free trial ending: ${s.name}'
            : 'Renewal coming up: ${s.name}';
        final body = s.isTrial
            ? '${s.name} starts charging $price in $h hours. Cancel now if you do not want it.'
            : '${s.name} renews for $price in $h hours.';
        await notifs.zonedSchedule(
          s.id * 10 + k,
          title,
          body,
          tz.TZDateTime.from(when, tz.UTC),
          kAlertDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const SubSentryApp());
  await initNotifications();
  await rescheduleAll(store.subs, store.currency);
}

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0F766E),
        brightness: b,
      ),
    );

class SubSentryApp extends StatelessWidget {
  const SubSentryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SubSentry',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _index = 0;
  int _addKey = 0;

  static const List<String> _titles = [
    'SubSentry',
    'Add Subscription',
    'Cancellation Guide',
    'Annual Projection',
    'Settings & Data',
  ];

  void _edit(Sub s) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: const Text('Edit subscription')),
          body: AddScreen(
            existing: s,
            onDone: () => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_index])),
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(
            onAdd: () => setState(() => _index = 1),
            onEdit: _edit,
          ),
          AddScreen(
            key: ValueKey(_addKey),
            onDone: () => setState(() {
              _addKey++;
              _index = 0;
            }),
          ),
          const GuidesScreen(),
          const ProjectionScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (v) => setState(() => _index = v),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Overview'),
          NavigationDestination(
              icon: Icon(Icons.add_circle_outline),
              selectedIcon: Icon(Icons.add_circle),
              label: 'Add'),
          NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'Cancel'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'Projection'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 1: Overview
// ---------------------------------------------------------------------------

class DashboardScreen extends StatelessWidget {
  final VoidCallback onAdd;
  final void Function(Sub) onEdit;

  const DashboardScreen({super.key, required this.onAdd, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final all = [...store.subs]..sort(byDate);
        final trials = all.where((s) => s.isTrial).toList();
        final active = all.where((s) => !s.isTrial).toList();

        if (all.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, size: 64, color: cs.primary),
                  const SizedBox(height: 16),
                  const Text('No subscriptions yet',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text(
                    'Add your subscriptions and free trials. Everything stays on this phone.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Add subscription'),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fixed monthly spend',
                      style: TextStyle(color: cs.onPrimaryContainer)),
                  const SizedBox(height: 6),
                  Text(
                    fmtMoney(store.monthlyTotal, store.currency),
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${active.length} active, ${trials.length} on trial',
                    style: TextStyle(color: cs.onPrimaryContainer),
                  ),
                ],
              ),
            ),
            if (trials.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('Trials ending soon',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final s in trials)
                Card(
                  color: cs.errorContainer,
                  child: ListTile(
                    onTap: () => onEdit(s),
                    leading: Icon(Icons.warning_amber_rounded,
                        color: cs.onErrorContainer),
                    title: Text(s.name,
                        style: TextStyle(
                            color: cs.onErrorContainer,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      'Charges ${fmtMoney(s.cost, store.currency)} on ${fmtDate(s.nextBill)}',
                      style: TextStyle(color: cs.onErrorContainer),
                    ),
                    trailing: Text(
                      timeLeft(s.nextBill),
                      style: TextStyle(
                          color: cs.onErrorContainer,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
            if (active.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('Upcoming bills',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final s in active)
                Card(
                  child: ListTile(
                    onTap: () => onEdit(s),
                    leading: CircleAvatar(
                      child: Text(s.name.isEmpty
                          ? '?'
                          : s.name.substring(0, 1).toUpperCase()),
                    ),
                    title: Text(s.name),
                    subtitle: Text(
                      '${s.cycle}${s.card.isEmpty ? '' : ' - ${s.card}'}\nNext: ${fmtDate(s.nextBill)}',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      fmtMoney(s.cost, store.currency),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 2: Add / edit subscription
// ---------------------------------------------------------------------------

Future<bool> confirmDialog(BuildContext context, String title, String message,
    {String action = 'OK'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true), child: Text(action)),
      ],
    ),
  );
  return r ?? false;
}

void showUpsell(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('SubSentry Premium'),
      content: Text(
        'The free plan tracks up to $kFreeLimit subscriptions.\n\n'
        'Premium (one-time purchase) will unlock unlimited tracking and remove ads. '
        'Billing is not connected in this version yet.',
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
      ],
    ),
  );
}

class AddScreen extends StatefulWidget {
  final Sub? existing;
  final VoidCallback onDone;

  const AddScreen({super.key, this.existing, required this.onDone});

  @override
  State<AddScreen> createState() => _AddScreenState();
}

class _AddScreenState extends State<AddScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _cost;
  late final TextEditingController _card;
  late String _cycle;
  late bool _trial;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _cost = TextEditingController(text: e == null ? '' : e.cost.toString());
    _card = TextEditingController(text: e?.card ?? '');
    _cycle = e?.cycle ?? 'Monthly';
    _trial = e?.isTrial ?? false;
    final soon = DateTime.now().add(const Duration(days: 7));
    _date = e?.nextBill ?? DateTime(soon.year, soon.month, soon.day, 9, 0);
  }

  @override
  void dispose() {
    _name.dispose();
    _cost.dispose();
    _card.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
    }
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (t != null) {
      setState(() => _date = DateTime(_date.year, _date.month, _date.day, t.hour, t.minute));
    }
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (widget.existing == null &&
        !store.premium &&
        store.subs.length >= kFreeLimit) {
      showUpsell(context);
      return;
    }
    final cost = double.parse(_cost.text.trim().replaceAll(',', '.'));
    final sub = Sub(
      id: widget.existing?.id ?? newId(),
      name: _name.text.trim(),
      cost: cost,
      cycle: _cycle,
      card: _card.text.trim(),
      nextBill: _date,
      isTrial: _trial,
    );
    await store.upsert(sub);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${sub.name} saved')),
    );
    widget.onDone();
  }

  Future<void> _delete() async {
    final e = widget.existing;
    if (e == null) return;
    final ok = await confirmDialog(
        context, 'Delete ${e.name}?', 'This removes it from the app.',
        action: 'Delete');
    if (!ok) return;
    await store.remove(e.id);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Service name', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _cost,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: _trial ? 'Price after the trial' : 'Cost per billing',
                  prefixText: '${store.currency} ',
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  final x = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
                  if (x == null || x < 0) return 'Enter a valid price';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Billing frequency',
                    border: OutlineInputBorder()),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _cycle,
                    isExpanded: true,
                    items: kCycles
                        .map((c) => DropdownMenuItem<String>(
                            value: c, child: Text(c)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _cycle = v);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _card,
                decoration: const InputDecoration(
                    labelText: 'Payment card tag (optional)',
                    hintText: 'e.g. Visa 4417',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('This is a free trial'),
                subtitle: const Text('You will get alerts 48h, 24h and 2h before it starts charging'),
                value: _trial,
                onChanged: (v) => setState(() => _trial = v),
              ),
              const SizedBox(height: 8),
              Text(_trial ? 'Trial ends on' : 'Next charge on',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today, size: 18),
                      label: Text(fmtDate(_date)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule, size: 18),
                      label: Text(fmtTime(_date)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: Text(widget.existing == null ? 'Save subscription' : 'Save changes'),
                ),
              ),
              if (widget.existing != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: _delete,
                    icon: Icon(Icons.delete_outline, color: cs.error),
                    label: Text('Delete', style: TextStyle(color: cs.error)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 3: Cancellation guide
// ---------------------------------------------------------------------------

class GuidesScreen extends StatefulWidget {
  const GuidesScreen({super.key});

  @override
  State<GuidesScreen> createState() => _GuidesScreenState();
}

class _GuidesScreenState extends State<GuidesScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = kGuides.where((g) => g.name.toLowerCase().contains(q)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search a service',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Menus change over time. If a step is missing, search the service Help page for "cancel".',
            style: TextStyle(fontSize: 12),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('No match. Try the service Help page.'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final g = list[i];
                    return ExpansionTile(
                      title: Text(g.name),
                      childrenPadding:
                          const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [Text(g.steps)],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 4: Annual projection
// ---------------------------------------------------------------------------

class ProjectionScreen extends StatelessWidget {
  const ProjectionScreen({super.key});

  Widget _card(BuildContext context, String label, double value) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: cs.onSecondaryContainer)),
            const SizedBox(height: 6),
            FittedBox(
              child: Text(
                fmtMoney(value, store.currency),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final yearly =
            store.subs.fold<double>(0, (a, s) => a + s.yearlyCost);
        final sorted = [...store.subs]
          ..sort((a, b) => b.yearlyCost.compareTo(a.yearlyCost));
        final maxV = (sorted.isEmpty || sorted.first.yearlyCost <= 0)
            ? 1.0
            : sorted.first.yearlyCost;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'If you keep every subscription and trial at today prices:',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _card(context, '1 year', yearly),
                const SizedBox(width: 8),
                _card(context, '3 years', yearly * 3),
                const SizedBox(width: 8),
                _card(context, '5 years', yearly * 5),
              ],
            ),
            const SizedBox(height: 24),
            const Text('Where it goes (per year)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (sorted.isEmpty) const Text('Add a subscription to see the projection.'),
            for (final s in sorted)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(s.name)),
                        Text(fmtMoney(s.yearlyCost, store.currency),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: s.yearlyCost / maxV,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 5: Settings & data
// ---------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _testAlert(BuildContext context) async {
    if (!notifsReady) {
      _snack(context, 'Notifications are not ready. Allow them in phone settings.');
      return;
    }
    try {
      await notifs.show(
        0,
        'SubSentry test alert',
        'Alerts are working on this phone.',
        kAlertDetails,
      );
    } catch (_) {
      if (context.mounted) _snack(context, 'Could not show the alert.');
    }
  }

  Future<void> _askPermission(BuildContext context) async {
    final android = notifs.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final ok = await android?.requestNotificationsPermission();
    if (!context.mounted) return;
    _snack(context, ok == false ? 'Notifications are blocked in phone settings.' : 'Notifications allowed.');
  }

  Future<void> _backup(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: store.backupJson()));
    if (!context.mounted) return;
    _snack(context, 'Backup copied. Paste it into a note or message to save it.');
  }

  Future<void> _restore(BuildContext context) async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (!context.mounted) return;
    if (text.trim().isEmpty) {
      _snack(context, 'Clipboard is empty. Copy your backup first.');
      return;
    }
    final ok = await confirmDialog(context, 'Restore backup?',
        'This replaces everything currently in the app.',
        action: 'Restore');
    if (!ok) return;
    final done = await store.restoreJson(text);
    if (!context.mounted) return;
    _snack(context, done ? 'Backup restored.' : 'That does not look like a SubSentry backup.');
  }

  Future<void> _clear(BuildContext context) async {
    final ok = await confirmDialog(context, 'Delete all data?',
        'All subscriptions will be removed from this phone.',
        action: 'Delete all');
    if (!ok) return;
    await store.clearAll();
    if (!context.mounted) return;
    _snack(context, 'All data deleted.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Icon(store.premium ? Icons.workspace_premium : Icons.lock_outline),
                title: Text(store.premium ? 'Premium active' : 'Free plan'),
                subtitle: Text('Free: up to $kFreeLimit subscriptions'),
                trailing: FilledButton(
                  onPressed: () => showUpsell(context),
                  child: const Text('Unlock'),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('Test mode: premium'),
              subtitle: const Text('For testing only. Real billing comes later.'),
              value: store.premium,
              onChanged: (v) => store.setPremium(v),
            ),
            const Divider(),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: store.currency,
              onChanged: (v) => store.setCurrency(v),
              decoration: const InputDecoration(
                labelText: 'Currency symbol',
                hintText: 'e.g. \$ or ETB',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Alerts', style: TextStyle(fontWeight: FontWeight.w600)),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Allow notifications'),
              onTap: () => _askPermission(context),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.send_outlined),
              title: const Text('Send a test alert'),
              onTap: () => _testAlert(context),
            ),
            const Divider(),
            const Text('Your data', style: TextStyle(fontWeight: FontWeight.w600)),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy backup'),
              subtitle: const Text('Copies your data as text'),
              onTap: () => _backup(context),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.restore_outlined),
              title: const Text('Restore from copied backup'),
              onTap: () => _restore(context),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: const Text('Delete all data'),
              onTap: () => _clear(context),
            ),
            const SizedBox(height: 16),
            const Text(
              'SubSentry works fully offline. Your data never leaves this phone, and no bank login is ever needed.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}
