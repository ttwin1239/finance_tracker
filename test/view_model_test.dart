import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/main.dart';

// Фейковый репозиторий для тестов
class FakeRepository implements ExpenseRepository {
  List<Expense> _items = [];

  @override
  Future<void> add(Expense e) async => _items.add(e);

  @override
  Future<void> clearAll() async => _items.clear();

  @override
  Future<void> delete(String id) async => _items.removeWhere((e) => e.id == id);

  @override
  Future<List<Expense>> getAll() async => _items;

  @override
  Future<void> update(Expense e) async {
    final index = _items.indexWhere((item) => item.id == e.id);
    if (index != -1) _items[index] = e;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  isTestMode = true; // Отключаем уведомления для тестов

  group('Тесты ExpenseViewModel', () {
    late ExpenseViewModel viewModel;
    late FakeRepository fakeRepo;

    setUp(() {
      fakeRepo = FakeRepository();
      viewModel = ExpenseViewModel(fakeRepo);
    });

    test('Успешная загрузка данных', () async {
      await viewModel.load();
      expect(viewModel.state, LoadState.success);
      expect(viewModel.items.isEmpty, isTrue);
    });

    test('Добавление расхода', () async {
      final expense = Expense(
        id: '1', title: 'Кофе', amount: 200.0, category: 'Еда', date: DateTime.now()
      );
      await viewModel.addOrUpdate(expense);
      expect(viewModel.items.length, 1);
      expect(viewModel.items.first.title, 'Кофе');
      expect(viewModel.total, 200.0);
    });

    test('Удаление расхода', () async {
      final expense = Expense(
        id: '1', title: 'Кофе', amount: 200.0, category: 'Еда', date: DateTime.now()
      );
      await viewModel.addOrUpdate(expense);
      await viewModel.remove('1');
      expect(viewModel.items.isEmpty, isTrue);
    });

    test('Поиск по названию', () async {
      await viewModel.addOrUpdate(Expense(id: '1', title: 'Кофе', amount: 200, category: 'Еда', date: DateTime.now()));
      await viewModel.addOrUpdate(Expense(id: '2', title: 'Такси', amount: 300, category: 'Транспорт', date: DateTime.now()));

      viewModel.setQuery('Кофе');
      expect(viewModel.filteredItems.length, 1);
      expect(viewModel.filteredItems.first.title, 'Кофе');
    });
  });
}