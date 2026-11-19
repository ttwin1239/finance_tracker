import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:test_app/main.dart';

void main() {
  group('Тесты форматирования', () {
    test('Форматирование даты', () {
      final date = DateTime(2026, 11, 12);
      expect(DateFormat('dd.MM.yyyy').format(date), '12.11.2026');
    });

    test('Форматирование валюты', () {
      final formatter = NumberFormat.currency(
        locale: 'ru_RU',
        symbol: '₽',
        decimalDigits: 0,
      );
      expect(formatter.format(1000).contains('₽'), isTrue);
    });
  });

  group('Тесты SpendingAnalyzer', () {
    test('Анализ пустого списка', () {
      final insights = SpendingAnalyzer.getInsights([], DateTime.now());
      expect(insights.first, contains('Добавьте расходы'));
    });

    test('Анализ аномальной траты', () {
      final now = DateTime.now();
      final expenses = [
        Expense(id: '1', title: 'Еда', amount: 10, category: 'Еда', date: now),
        Expense(id: '2', title: 'Еда', amount: 10, category: 'Еда', date: now),
        Expense(id: '3', title: 'Еда', amount: 10, category: 'Еда', date: now),
        Expense(id: '4', title: 'Еда', amount: 10, category: 'Еда', date: now),
        Expense(id: '5', title: 'Еда', amount: 10, category: 'Еда', date: now),
        Expense(id: '6', title: 'Телефон', amount: 1000, category: 'Другое', date: now),
      ];

      final insights = SpendingAnalyzer.getInsights(expenses, now);

      expect(insights.any((i) => i.contains('аномальная')), isTrue);
    });
  });
}