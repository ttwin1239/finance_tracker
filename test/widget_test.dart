import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart'; // <-- Добавлен импорт
import 'package:test_app/main.dart';

class FakeRepository implements ExpenseRepository {
  @override
  Future<void> add(Expense e) async {}
  @override
  Future<void> clearAll() async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<List<Expense>> getAll() async => [];
  @override
  Future<void> update(Expense e) async {}
}

void main() {
  testWidgets('Главный экран отображает пустое состояние', (WidgetTester tester) async {
    isTestMode = true;

    // Инициализируем локализованные данные для русского языка
    await initializeDateFormatting('ru_RU', null);

    final viewModel = ExpenseViewModel(FakeRepository());

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: viewModel),
            ChangeNotifierProvider(create: (_) => RatesViewModel(ApiRatesRepository())),
          ],
          child: const MainScreen(
            dark: false,
            onToggleTheme: _dummyToggle,
            onLogout: _dummyLogout,
          ),
        ),
      ),
    );

    // Даем время виджету прогрузиться
    await tester.pump();

    expect(find.text('Нет записей о расходах'), findsOneWidget);
    expect(find.byIcon(Icons.account_balance_wallet_outlined), findsOneWidget);
    expect(find.text('Добавить'), findsOneWidget);
  });
}

void _dummyToggle(bool v) {}
void _dummyLogout() {}