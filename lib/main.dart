import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:provider/provider.dart';
import 'package:logger/logger.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

final logger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 5,
    lineLength: 80,
    colors: true,
    printEmojis: false,
  ),
);

bool isTestMode = false;

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> setupNotifications() async {
  if (isTestMode) return;
  const androidSettings = AndroidInitializationSettings('ic_dialog_info');
  const initSettings = InitializationSettings(android: androidSettings);
  await notificationsPlugin.initialize(initSettings);

  final androidImpl = notificationsPlugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (androidImpl != null) {
    await androidImpl.requestNotificationsPermission();
  }
}

Future<void> sendNotification(String title, String body) async {
  if (isTestMode) return;
  const androidDetails = AndroidNotificationDetails(
    'finance_channel',
    'Финансовые уведомления',
    channelDescription: 'Уведомления о расходах',
    importance: Importance.max,
    priority: Priority.high,
  );
  const details = NotificationDetails(android: androidDetails);
  await notificationsPlugin.show(0, title, body, details);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // await setupNotifications();
  logger.i('Приложение запущено');
  runApp(const FinanceApp());
}

class AuthStore {
  static const _keyLogin = 'auth_login';
  static const _keyPass = 'auth_pass';
  static const _keyPin = 'auth_pin';

  static String _hash(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  static Future<bool> isRegistered() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLogin) != null;
  }

  static Future<void> register(String login, String password, String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLogin, login);
    await prefs.setString(_keyPass, _hash(password));
    await prefs.setString(_keyPin, _hash(pin));
    logger.i('Пользователь создан: $login');
  }

  static Future<bool> checkPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getString(_keyPin);
    return savedPin == _hash(pin);
  }
}

const List<String> expenseCategories = [
  'Еда',
  'Транспорт',
  'Жильё',
  'Развлечения',
  'Здоровье',
  'Другое'
];

class Expense {
  final String id;
  final String title;
  final double amount;
  final String category;
  final DateTime date;

  const Expense({
    required this.id,
    required this.title,
    required this.amount,
    required this.category,
    required this.date,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'category': category,
        'date': date.toIso8601String(),
      };

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
        id: json['id'] as String,
        title: json['title'] as String,
        amount: (json['amount'] as num).toDouble(),
        category: json['category'] as String,
        date: DateTime.parse(json['date'] as String),
      );
}

class CurrencyRate {
  final String code;
  final String name;
  final double value;
  final int nominal;

  CurrencyRate({
    required this.code,
    required this.name,
    required this.value,
    required this.nominal,
  });

  Map<String, dynamic> toMap() => {
        'code': code,
        'name': name,
        'value': value,
        'nominal': nominal,
      };

  factory CurrencyRate.fromMap(Map<String, dynamic> map) => CurrencyRate(
        code: map['code'] as String,
        name: map['name'] as String,
        value: (map['value'] as num).toDouble(),
        nominal: (map['nominal'] as num).toInt(),
      );
}

class ExpenseDatabase {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  static Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/finance.db';
    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
            'CREATE TABLE expenses(id TEXT PRIMARY KEY, title TEXT, amount REAL, category TEXT, date TEXT)');
        await db.execute(
            'CREATE TABLE rates(code TEXT PRIMARY KEY, name TEXT, value REAL, nominal INTEGER)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'CREATE TABLE rates(code TEXT PRIMARY KEY, name TEXT, value REAL, nominal INTEGER)');
        }
      },
    );
  }
}

abstract class ExpenseRepository {
  Future<List<Expense>> getAll();
  Future<void> add(Expense e);
  Future<void> update(Expense e);
  Future<void> delete(String id);
  Future<void> clearAll();
}

class DbExpenseRepository implements ExpenseRepository {
  @override
  Future<List<Expense>> getAll() async {
    try {
      final db = await ExpenseDatabase.database;
      final maps = await db.query('expenses');
      return List.generate(
        maps.length,
        (i) => Expense(
          id: maps[i]['id'] as String,
          title: maps[i]['title'] as String,
          amount: (maps[i]['amount'] as num).toDouble(),
          category: maps[i]['category'] as String,
          date: DateTime.parse(maps[i]['date'] as String),
        ),
      );
    } catch (e) {
      logger.e('Ошибка загрузки расходов', error: e);
      return [];
    }
  }

  @override
  Future<void> add(Expense e) async {
    final db = await ExpenseDatabase.database;
    await db.insert('expenses', e.toJson());
    logger.i('Добавлен расход: ${e.title}');
  }

  @override
  Future<void> update(Expense e) async {
    final db = await ExpenseDatabase.database;
    await db.update('expenses', e.toJson(), where: 'id = ?', whereArgs: [e.id]);
    logger.i('Обновлён расход: ${e.title}');
  }

  @override
  Future<void> delete(String id) async {
    final db = await ExpenseDatabase.database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
    logger.i('Удалён расход: $id');
  }

  @override
  Future<void> clearAll() async {
    final db = await ExpenseDatabase.database;
    await db.delete('expenses');
    logger.i('Все расходы удалены');
  }
}

abstract class RatesRepository {
  Future<List<CurrencyRate>> fetchAndCache();
  Future<List<CurrencyRate>?> getCached();
  Future<bool> isOnline();
}

class ApiRatesRepository implements RatesRepository {
  static final Uri _url = Uri.parse('https://www.cbr-xml-daily.ru/daily_json.js');

  @override
  Future<bool> isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result != ConnectivityResult.none;
  }

  @override
  Future<List<CurrencyRate>> fetchAndCache() async {
    final response = await http.get(_url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) throw Exception('Ошибка сервера');
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final valute = data['Valute'] as Map<String, dynamic>;
    final rates = valute.values.map((v) {
      return CurrencyRate(
        code: v['CharCode'] as String,
        name: v['Name'] as String,
        value: (v['Value'] as num).toDouble(),
        nominal: (v['Nominal'] as num).toInt(),
      );
    }).toList()
      ..sort((a, b) => a.code.compareTo(b.code));

    final db = await ExpenseDatabase.database;
    await db.delete('rates');
    for (final r in rates) {
      await db.insert('rates', r.toMap());
    }
    logger.i('Курсы валют обновлены и закэшированы');
    return rates;
  }

  @override
  Future<List<CurrencyRate>?> getCached() async {
    final db = await ExpenseDatabase.database;
    final maps = await db.query('rates');
    if (maps.isEmpty) return null;
    return maps.map((m) => CurrencyRate.fromMap(m)).toList();
  }
}

enum LoadState { initial, loading, success, error }

class ExpenseViewModel extends ChangeNotifier {
  final ExpenseRepository _repository;
  ExpenseViewModel(this._repository);

  List<Expense> _items = [];
  List<Expense> get items => _items;

  LoadState _state = LoadState.initial;
  LoadState get state => _state;

  String? _error;
  String? get error => _error;

  String _query = '';
  String get query => _query;

  List<Expense> get filteredItems {
    if (_query.isEmpty) return _items;
    final q = _query.toLowerCase();
    return _items
        .where((e) =>
            e.title.toLowerCase().contains(q) ||
            e.category.toLowerCase().contains(q))
        .toList();
  }

  double get total => _items.fold(0.0, (s, e) => s + e.amount);

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  Future<void> load() async {
    _state = LoadState.loading;
    notifyListeners();
    try {
      _items = await _repository.getAll();
      _items.sort((a, b) => b.date.compareTo(a.date));
      _state = LoadState.success;
      logger.i('Загружено ${_items.length} расходов');
    } catch (e) {
      _state = LoadState.error;
      _error = 'Ошибка загрузки данных';
      logger.e('Ошибка загрузки расходов', error: e);
    }
    notifyListeners();
  }

  Future<void> addOrUpdate(Expense e) async {
    try {
      final i = _items.indexWhere((x) => x.id == e.id);
      if (i >= 0) {
        await _repository.update(e);
        _items[i] = e;
      } else {
        await _repository.add(e);
        _items.add(e);
        await sendNotification('Новый расход', '${e.title}: ${e.amount} ₽');
      }
      _items.sort((a, b) => b.date.compareTo(a.date));
      notifyListeners();
    } catch (err) {
      logger.e('Ошибка сохранения', error: err);
    }
  }

  Future<void> remove(String id) async {
    try {
      await _repository.delete(id);
      _items.removeWhere((e) => e.id == id);
      logger.i('Удалён расход: $id');
      notifyListeners();
    } catch (err) {
      logger.e('Ошибка удаления', error: err);
    }
  }

  Future<void> clearAll() async {
    await _repository.clearAll();
    _items = [];
    notifyListeners();
  }
}

class RatesViewModel extends ChangeNotifier {
  final RatesRepository _repository;
  RatesViewModel(this._repository);

  List<CurrencyRate>? _rates;
  List<CurrencyRate>? get rates => _rates;

  bool _loading = false;
  bool get loading => _loading;

  bool _isCached = false;
  bool get isCached => _isCached;

  String? _error;
  String? get error => _error;

  final List<String> _myCurrencies = ['USD', 'EUR', 'UAH', 'KZT'];

  Future<void> load() async {
    _loading = true;
    _error = null;
    _isCached = false;
    notifyListeners();

    final online = await _repository.isOnline();
    if (!online) {
      final cached = await _repository.getCached();
      if (cached != null && cached.isNotEmpty) {
        _rates = cached.where((r) => _myCurrencies.contains(r.code)).toList();
        _isCached = true;
        logger.w('Нет интернета, показаны кэшированные курсы');
      } else {
        _error = 'Нет интернета и нет сохранённых данных';
        logger.e('Нет интернета и нет кэша');
      }
      _loading = false;
      notifyListeners();
      return;
    }

    try {
      final r = await _repository.fetchAndCache();
      _rates = r.where((rate) => _myCurrencies.contains(rate.code)).toList();
      logger.i('Курсы загружены с сервера');
    } catch (e) {
      final cached = await _repository.getCached();
      if (cached != null && cached.isNotEmpty) {
        _rates = cached.where((r) => _myCurrencies.contains(r.code)).toList();
        _isCached = true;
        logger.w('Ошибка сети, показан кэш');
      } else {
        _error = 'Не удалось загрузить данные.\nПроверьте соединение.';
        logger.e('Ошибка загрузки курсов', error: e);
      }
    }
    _loading = false;
    notifyListeners();
  }
}

class SpendingAnalyzer {
  static List<String> getInsights(
      List<Expense> allItems, DateTime selectedMonth) {
    final currentItems = allItems
        .where((e) =>
            e.date.year == selectedMonth.year &&
            e.date.month == selectedMonth.month)
        .toList();
    if (currentItems.isEmpty) {
      return ['Добавьте расходы за этот месяц для формирования аналитики.'];
    }

    final insights = <String>[];
    final currentTotals = <String, double>{};
    for (final e in currentItems) {
      currentTotals[e.category] = (currentTotals[e.category] ?? 0) + e.amount;
    }

    final prevMonth = DateTime(selectedMonth.year, selectedMonth.month - 1);
    final prevItems = allItems
        .where((e) =>
            e.date.year == prevMonth.year && e.date.month == prevMonth.month)
        .toList();
    final prevTotals = <String, double>{};
    for (final e in prevItems) {
      prevTotals[e.category] = (prevTotals[e.category] ?? 0) + e.amount;
    }

    final totalSum = currentTotals.values.fold(0.0, (s, v) => s + v);
    if (totalSum > 0) {
      final maxEntry =
          currentTotals.entries.reduce((a, b) => a.value > b.value ? a : b);
      final percent = (maxEntry.value / totalSum * 100).toStringAsFixed(0);

      if (int.parse(percent) > 40) {
        insights.add(
            'Наибольшая доля трат приходится на "${maxEntry.key}" ($percent%). Рекомендуется пересмотреть расходы в этой категории.');
      } else {
        insights.add(
            'Основная статья расходов — "${maxEntry.key}" ($percent%). Баланс категорий в норме.');
      }

      for (final cat in currentTotals.keys) {
        final curr = currentTotals[cat]!;
        final prev = prevTotals[cat] ?? 0;
        if (prev > 0 && curr > prev * 1.3) {
          insights.add(
              'Зафиксирован рост трат на "$cat" на ${((curr - prev) / prev * 100).toStringAsFixed(0)}% по сравнению с прошлым периодом.');
        }
      }

      final average = totalSum / currentItems.length;
      final bigExpenses =
          currentItems.where((e) => e.amount > average * 3).toList();
      if (bigExpenses.isNotEmpty) {
        final biggest =
            bigExpenses.reduce((a, b) => a.amount > b.amount ? a : b);
        insights.add(
            'Обнаружена аномальная трата: "${biggest.title}" на сумму ${biggest.amount.toStringAsFixed(0)} ₽.');
      }

      if (insights.length == 1) {
        insights.add(
            'Динамика расходов стабильна. Рекомендуется направлять 10-15% дохода в накопления.');
      }
    }
    return insights;
  }
}

class AppColors {
  static const bgLight = Color(0xFFF4F6F9);
  static const cardLight = Colors.white;
  static const accent = Color(0xFF2196F3);
  static const textPrimary = Color(0xFF1A1A1A);
  static const textSecondary = Color(0xFF6C7B8B);

  static const bgDark = Color(0xFF121C24);
  static const cardDark = Color(0xFF1E2B36);
  static const darkText = Color(0xFFF0F4F8);
  static const darkSecondary = Color(0xFF8E9DA8);

  static const red = Color(0xFFEF5350);

  static const categoryColors = [
    Color(0xFF42A5F5),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFFAB47BC),
    Color(0xFFEF5350),
    Color(0xFF26C6DA),
  ];
}

class FinanceApp extends StatefulWidget {
  const FinanceApp({super.key});
  @override
  State<FinanceApp> createState() => _FinanceAppState();
}

class _FinanceAppState extends State<FinanceApp> {
  bool _showSplash = true;
  bool _isRegistered = false;
  bool _isLoggedIn = false;
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      final registered = await AuthStore.isRegistered();

      if (!mounted) return;
      setState(() {
        _isRegistered = registered;
        _dark = prefs.getBool('dark_theme') ?? false;
        _showSplash = false;
      });
      logger.i('Инициализация завершена');
    } catch (e) {
      logger.e('Ошибка инициализации, принудительный запуск', error: e);
      if (!mounted) return;
      setState(() {
        _isRegistered = false;
        _showSplash = false;
      });
    }
  }

  void _toggleTheme(bool v) async {
    setState(() => _dark = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_theme', v);
    logger.d('Тема изменена: ${v ? "тёмная" : "светлая"}');
  }

  void _logout() {
    setState(() => _isLoggedIn = false);
    logger.i('Выход из аккаунта');
  }

  @override
  Widget build(BuildContext context) {
    Widget homeWidget;
    if (_showSplash) {
      homeWidget = const SplashScreen();
    } else if (!_isRegistered) {
      homeWidget = RegisterScreen(
        onRegistered: () {
          setState(() {
            _isRegistered = true;
            _isLoggedIn = true;
          });
        },
      );
    } else if (!_isLoggedIn) {
      homeWidget = PinScreen(
        onSuccess: () {
          setState(() => _isLoggedIn = true);
        },
      );
    } else {
      homeWidget = MainAppScreen(
        dark: _dark,
        onToggleTheme: _toggleTheme,
        onLogout: _logout,
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ExpenseViewModel(DbExpenseRepository()),
        ),
        ChangeNotifierProvider(
          create: (_) => RatesViewModel(ApiRatesRepository()),
        ),
      ],
      child: MaterialApp(
        title: 'Мои расходы',
        debugShowCheckedModeBanner: false,
        themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
        theme: _buildTheme(false),
        darkTheme: _buildTheme(true),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: homeWidget,
      ),
    );
  }

  ThemeData _buildTheme(bool dark) {
    final bg = dark ? AppColors.bgDark : AppColors.bgLight;
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        primary: AppColors.accent,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        foregroundColor: dark ? AppColors.darkText : AppColors.textPrimary,
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale, _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _scale = Tween<double>(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.accent,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(30),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      )
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/icon.png',
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => const Icon(
                        Icons.monetization_on,
                        size: 60,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Мои расходы',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Учет финансов',
                  style: TextStyle(fontSize: 16, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  final VoidCallback onRegistered;
  const RegisterScreen({super.key, required this.onRegistered});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _login = TextEditingController();
  final _pass = TextEditingController();
  final _pin = TextEditingController();
  bool _obscurePass = true;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await AuthStore.register(_login.text.trim(), _pass.text, _pin.text);
    if (!mounted) return;
    widget.onRegistered();
  }

  @override
  void dispose() {
    _login.dispose();
    _pass.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Регистрация'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.account_balance_wallet,
                      size: 64, color: AppColors.accent),
                  const SizedBox(height: 16),
                  const Text(
                    'Создать аккаунт',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _login,
                    decoration: const InputDecoration(
                      labelText: 'Логин',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'Минимум 3 символа'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _pass,
                    obscureText: _obscurePass,
                    decoration: InputDecoration(
                      labelText: 'Пароль',
                      prefixIcon: const Icon(Icons.lock),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePass
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () =>
                            setState(() => _obscurePass = !_obscurePass),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 4) ? 'Минимум 4 символа' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _pin,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'PIN-код',
                      prefixIcon: Icon(Icons.pin),
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.length != 4) ? 'Введите 4 цифры' : null,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                      ),
                      onPressed: _submit,
                      child: const Text(
                        'Создать',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PinScreen extends StatefulWidget {
  final VoidCallback onSuccess;
  const PinScreen({super.key, required this.onSuccess});
  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  String? _error;

  void _onKeyPress(String value) async {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += value;
      _error = null;
    });
    if (_pin.length == 4) {
      final ok = await AuthStore.checkPin(_pin);
      if (!mounted) return;
      if (ok) {
        widget.onSuccess();
        logger.i('Успешный вход по PIN');
      } else {
        setState(() {
          _error = 'Неверный PIN-код';
          _pin = '';
        });
        logger.w('Неверный PIN-код');
      }
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Вход'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 72, color: AppColors.accent),
            const SizedBox(height: 16),
            const Text(
              'Введите PIN-код',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? ' ',
              style: TextStyle(
                color: isDark ? AppColors.darkSecondary : AppColors.red,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                4,
                (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? AppColors.accent : Colors.transparent,
                    border: Border.all(color: AppColors.accent, width: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 48),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: GridView.count(
                shrinkWrap: true,
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 1.2,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (var i = 1; i <= 9; i++) _buildKey(i.toString(), isDark),
                  _buildKey('', isDark, isTransparent: true),
                  _buildKey('0', isDark),
                  _buildKey('', isDark, isBackspace: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKey(
    String text,
    bool isDark, {
    bool isBackspace = false,
    bool isTransparent = false,
  }) {
    if (isTransparent) return const SizedBox.shrink();
    return Material(
      color: isDark ? AppColors.cardDark : Colors.white,
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => isBackspace ? _onBackspace() : _onKeyPress(text),
        child: Center(
          child: isBackspace
              ? Icon(
                  Icons.backspace,
                  color: isDark ? AppColors.darkText : AppColors.textPrimary,
                )
              : Text(
                  text,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                    color: isDark ? AppColors.darkText : AppColors.textPrimary,
                  ),
                ),
        ),
      ),
    );
  }
}

class MainAppScreen extends StatelessWidget {
  final bool dark;
  final Function(bool) onToggleTheme;
  final VoidCallback onLogout;

  const MainAppScreen({
    super.key,
    required this.dark,
    required this.onToggleTheme,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final expenseVm = context.watch<ExpenseViewModel>();
    if (expenseVm.state == LoadState.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (expenseVm.state == LoadState.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(expenseVm.error ?? 'Ошибка'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => expenseVm.load(),
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    return MainScreen(
      dark: dark,
      onToggleTheme: onToggleTheme,
      onLogout: onLogout,
    );
  }
}

class MainScreen extends StatefulWidget {
  final bool dark;
  final Function(bool) onToggleTheme;
  final VoidCallback onLogout;

  const MainScreen({
    super.key,
    required this.dark,
    required this.onToggleTheme,
    required this.onLogout,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with SingleTickerProviderStateMixin {
  int _tab = 0;
  DateTime _selectedMonth = DateTime.now();
  late AnimationController _emptyController;

  @override
  void initState() {
    super.initState();
    _emptyController = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _emptyController.dispose();
    super.dispose();
  }

Future<void> _openForm(BuildContext context, [Expense? expense]) async {
  await Navigator.of(context).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (_, __, ___) => ExpenseFormScreen(
        expense: expense,
        onSave: (e) async {
          await context.read<ExpenseViewModel>().addOrUpdate(e);
        },
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOut),
          ),
          child: child,
        ),
      ),
    ),
  );
  if (mounted) {
    setState(() {});
  }
}

  void _prevMonth() => setState(() =>
      _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1));

  void _nextMonth() => setState(() =>
      _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1));

  Future<void> _pickMonth(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Выберите месяц',
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked != null) {
      setState(() => _selectedMonth = DateTime(picked.year, picked.month));
    }
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          dark: widget.dark,
          onClearAll: () async {
            await context.read<ExpenseViewModel>().clearAll();
          },
          onLogout: widget.onLogout,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ExpenseViewModel>();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Мои расходы',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/icon.png',
              errorBuilder: (c, e, s) =>
                  const Icon(Icons.account_balance_wallet),
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, animation) =>
                  RotationTransition(turns: animation, child: child),
              child: Icon(
                widget.dark ? Icons.light_mode : Icons.dark_mode,
                key: ValueKey(widget.dark),
              ),
            ),
            onPressed: () => widget.onToggleTheme(!widget.dark),
          ),
          IconButton(
            icon: const Icon(Icons.currency_exchange),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RatesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [_buildList(context, vm), _buildStats(context, vm)],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.receipt_long),
            label: 'Расходы',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            label: 'Аналитика',
          ),
        ],
      ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              onPressed: () => _openForm(context),
              icon: const Icon(Icons.add),
              label: const Text('Добавить'),
            )
          : null,
    );
  }

  Widget _buildList(BuildContext context, ExpenseViewModel vm) {
    final formatter = NumberFormat.currency(
      locale: 'ru_RU',
      symbol: '₽',
      decimalDigits: 0,
    );
    final grouped = <String, List<Expense>>{};
    for (final e in vm.filteredItems) {
      grouped.putIfAbsent(e.category, () => []).add(e);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            onChanged: vm.setQuery,
            decoration: InputDecoration(
              hintText: 'Поиск...',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: widget.dark ? AppColors.cardDark : Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (vm.filteredItems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.accent, AppColors.accent.withOpacity(0.8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withAlpha(100),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  )
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Всего потрачено',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  TweenAnimationBuilder<double>(
                    key: ValueKey(vm.total),
                    tween: Tween(begin: 0, end: vm.total),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => Text(
                      formatter.format(value),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    'Записей: ${vm.items.length}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => vm.load(),
            child: vm.filteredItems.isEmpty
                ? AnimatedBuilder(
                    animation: _emptyController,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(
                          0, math.sin(_emptyController.value * math.pi * 2) * 10),
                      child: child,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 72,
                            color: widget.dark
                                ? AppColors.darkSecondary
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            vm.query.isEmpty
                                ? 'Нет записей о расходах'
                                : 'Ничего не найдено',
                            style: const TextStyle(fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 96, top: 4),
                    children: grouped.entries
                        .map((entry) => _CategoryGroup(
                              category: entry.key,
                              expenses: entry.value,
                              sum: entry.value
                                  .fold(0.0, (s, e) => s + e.amount),
                              isDark: widget.dark,
                              formatter: formatter,
                              onTap: (e) => _openForm(context, e),
                              onRemove: (id) => vm.remove(id),
                            ))
                        .toList(),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildStats(BuildContext context, ExpenseViewModel vm) {
    final formatter = NumberFormat.currency(
      locale: 'ru_RU',
      symbol: '₽',
      decimalDigits: 0,
    );
    final monthFormatter = DateFormat('LLLL yyyy', 'ru_RU');
    final monthItems = vm.items
        .where((e) =>
            e.date.year == _selectedMonth.year &&
            e.date.month == _selectedMonth.month)
        .toList();
    final monthTotal = monthItems.fold(0.0, (s, e) => s + e.amount);
    final totals = <String, double>{};
    for (final e in monthItems) {
      totals[e.category] = (totals[e.category] ?? 0) + e.amount;
    }
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    String monthName = monthFormatter.format(_selectedMonth);
    monthName = monthName[0].toUpperCase() + monthName.substring(1);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: widget.dark ? AppColors.cardDark : Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _prevMonth,
              ),
              InkWell(
                onTap: () => _pickMonth(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    monthName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _nextMonth,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (monthItems.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 64),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.pie_chart_outline,
                    size: 72,
                    color: widget.dark
                        ? AppColors.darkSecondary
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'За этот период нет данных',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: widget.dark ? AppColors.cardDark : Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  width: 200,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 1000),
                    curve: Curves.easeOut,
                    builder: (context, value, _) => CustomPaint(
                      painter: PieChartPainter(data: sorted, progress: value),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  formatter.format(monthTotal),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text('Сумма расходов'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: widget.dark ? AppColors.cardDark : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.accent.withAlpha(50),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.insights, color: AppColors.accent),
                    SizedBox(width: 8),
                    Text(
                      'Анализ трат',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...SpendingAnalyzer.getInsights(vm.items, _selectedMonth).map(
                  (insight) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 8,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            insight,
                            style: const TextStyle(height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ...sorted.asMap().entries.map((entry) {
            final i = entry.key;
            final cat = entry.value.key;
            final sum = entry.value.value;
            final percent = monthTotal == 0 ? 0 : (sum / monthTotal * 100);
            final color =
                AppColors.categoryColors[i % AppColors.categoryColors.length];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: widget.dark ? AppColors.cardDark : Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      cat,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${percent.toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: widget.dark
                          ? AppColors.darkSecondary
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    formatter.format(sum),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _CategoryGroup extends StatefulWidget {
  final String category;
  final List<Expense> expenses;
  final double sum;
  final bool isDark;
  final NumberFormat formatter;
  final void Function(Expense) onTap;
  final Future<void> Function(String) onRemove;

  const _CategoryGroup({
    required this.category,
    required this.expenses,
    required this.sum,
    required this.isDark,
    required this.formatter,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_CategoryGroup> createState() => _CategoryGroupState();
}

class _CategoryGroupState extends State<_CategoryGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isDark ? AppColors.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(5),
            blurRadius: 10,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withAlpha(30),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(_iconFor(widget.category), color: AppColors.accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.category,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '${widget.expenses.length} записей',
                          style: TextStyle(
                            color: widget.isDark
                                ? AppColors.darkSecondary
                                : AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    widget.formatter.format(widget.sum),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: widget.isDark
                          ? AppColors.darkSecondary
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Column(
              children: [
                Divider(
                  height: 1,
                  color: widget.isDark ? Colors.white10 : Colors.black12,
                ),
                ...widget.expenses.map(
                  (e) => Dismissible(
                    key: ValueKey(e.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      color: AppColors.red,
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    onDismissed: (_) => widget.onRemove(e.id),
                    child: ListTile(
                      onTap: () => widget.onTap(e),
                      title: Text(e.title),
                      subtitle: Text(
                        DateFormat('dd.MM.yyyy').format(e.date),
                        style: TextStyle(
                          color: widget.isDark
                              ? AppColors.darkSecondary
                              : AppColors.textSecondary,
                        ),
                      ),
                      trailing: Text(
                        widget.formatter.format(e.amount),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 300),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String c) {
    switch (c) {
      case 'Еда':
        return Icons.restaurant;
      case 'Транспорт':
        return Icons.directions_bus;
      case 'Жильё':
        return Icons.home;
      case 'Развлечения':
        return Icons.movie;
      case 'Здоровье':
        return Icons.favorite;
      default:
        return Icons.category;
    }
  }
}

class PieChartPainter extends CustomPainter {
  final List<MapEntry<String, double>> data;
  final double progress;
  PieChartPainter({required this.data, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final total = data.fold(0.0, (s, e) => s + e.value);
    if (total == 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final rect = Rect.fromCircle(center: center, radius: radius);
    var startAngle = -math.pi / 2;
    for (var i = 0; i < data.length; i++) {
      final sweep = (data[i].value / total) * 2 * math.pi * progress;
      final paint = Paint()
        ..color = AppColors.categoryColors[i % AppColors.categoryColors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 32
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, startAngle, sweep, false, paint);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant PieChartPainter oldDelegate) => true;
}

class ExpenseFormScreen extends StatefulWidget {
  final Expense? expense;
  final Future<void> Function(Expense) onSave;
  const ExpenseFormScreen({super.key, this.expense, required this.onSave});
  @override
  State<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends State<ExpenseFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title, _amount;
  late String _category;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final e = widget.expense;
    _title = TextEditingController(text: e?.title ?? '');
    _amount = TextEditingController(
      text: e == null ? '' : e.amount.toStringAsFixed(0),
    );
    _category = e?.category ?? expenseCategories.first;
    _date = e?.date ?? DateTime.now();
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _submit(BuildContext context) async {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amount.text.replaceAll(',', '.').trim());
    final expense = Expense(
      id: widget.expense?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: _title.text.trim(),
      amount: amount,
      category: _category,
      date: _date,
    );
    await widget.onSave(expense);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.cardDark : Colors.white;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.expense == null ? 'Новый расход' : 'Изменить',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              maxLength: 40,
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return 'Введите название';
                if (t.length < 2) return 'Минимум 2 символа';
                return null;
              },
              decoration: InputDecoration(
                labelText: 'Название',
                filled: true,
                fillColor: fill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final n = double.tryParse(
                  (v ?? '').replaceAll(',', '.').trim(),
                );
                if (n == null || n <= 0) return 'Введите сумму больше 0';
                return null;
              },
              decoration: InputDecoration(
                labelText: 'Сумма, ₽',
                filled: true,
                fillColor: fill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [100, 500, 1000].map((val) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      label: Text(
                        '+$val ₽',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () {
                        final current =
                            double.tryParse(_amount.text.replaceAll(',', '.')) ??
                                0;
                        setState(
                          () => _amount.text = (current + val).toStringAsFixed(0),
                        );
                      },
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            const Text(
              'Категория',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: expenseCategories.map((c) {
                return ChoiceChip(
                  label: Text(c),
                  selected: _category == c,
                  onSelected: (_) => setState(() => _category = c),
                  selectedColor: AppColors.accent.withAlpha(60),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _pickDate(context),
              child: Container(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('Дата'),
                  subtitle: Text(DateFormat('dd.MM.yyyy').format(_date)),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _submit(context),
                child: const Text(
                  'Сохранить',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RatesScreen extends StatefulWidget {
  const RatesScreen({super.key});
  @override
  State<RatesScreen> createState() => _RatesScreenState();
}

class _RatesScreenState extends State<RatesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RatesViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RatesViewModel>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? AppColors.cardDark : Colors.white;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Курсы валют',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => vm.load(),
          ),
        ],
      ),
      body: vm.loading
          ? const Center(child: CircularProgressIndicator())
          : vm.error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off, size: 72),
                      const SizedBox(height: 16),
                      Text(vm.error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => vm.load(),
                        child: const Text('Обновить'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    if (vm.isCached)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        color: Colors.orange.withAlpha(50),
                        child: const Text(
                          'Офлайн-режим. Данные могут быть неактуальны.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: vm.rates?.length ?? 0,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final r = vm.rates![i];
                          return Container(
                            decoration: BoxDecoration(
                              color: card,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.accent.withAlpha(30),
                                child: Text(
                                  r.code,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.accent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(r.name),
                              subtitle: Text('${r.nominal} ${r.code}'),
                              trailing: Text(
                                '${r.value.toStringAsFixed(2)} ₽',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  final bool dark;
  final Future<void> Function() onClearAll;
  final VoidCallback onLogout;

  const SettingsScreen({
    super.key,
    required this.dark,
    required this.onClearAll,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text(
              'Сбросить все данные',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Удалить все?'),
                  content: const Text('Это действие нельзя отменить.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Отмена'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Удалить'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await onClearAll();
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Завершить сеанс'),
            onTap: () {
              onLogout();
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Версия'),
            subtitle: Text('1.0.0 (Finance Tracker)'),
          ),
        ],
      ),
    );
  }
}