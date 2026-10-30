# Проблема JOIN_UNIQUE_OUTER/JOIN_UNIQUE_INNER

Мы можем увидеть запрос, где нужен SEMI JOIN:

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM t1 WHERE x IN (SELECT unnest(array[5, 5, 5]));
```

Здесь происходит трансформация IN в SEMI JOIN. SEMI JOIN часто можно преобразовать в INNER JOIN:

```sql
SELECT t1.* FROM t1 JOIN t2 USING (x);
```

Единственное - источник t2 должен быть уникален по x - если будут возвращаться дубликаты, то тогда одна и та же строка t1 появится в выводе больше одного раза, что противоречит смыслу полусоединения.

Поэтому очевидная стратегия - вставить в pathlist RelOptInfo альтернативы:

1. `a SEMI JOIN b`
2. ` a INNER JOIN make_unique(b)`

> Важно понимать, что "уникализация" не всегда возможна. Операция должна быть аналогом DISTINCT, а значит иметь оператор EQ и возможность либо быть отсортированным, либо хэшированым.

Функция `populate_joinrel_with_paths()` собственно и пробует такой подход, вызывая `add_paths_to_joinrel()` дважды, пробуя `a INNER JOIN make_unique(b)` и `make_unique(b) INNER JOIN a`.

В свою очередь, экспортируемая `add_paths_to_joinrel()` в самом начале имеет спецобработку для `JOIN_UNIQUE_*`, проверяет уникальность входа и выставляет флаг `extra.inner_unique`. Потом вызывает `match_unsorted_outer(JOIN_UNIQUE_*, extra)` передавая ему накопленную информацию.

Теперь `match_unsorted_outer()` видит, что нужно предложить стратегию для `JOIN_UNIQUE_*`. Переключается в режим `JOIN_INNER` имея save_jointype как контекст операции. Далее, выбирает самый дешёвый путь и строит над ним ещё один `inner_cheapest_total = create_unique_path()`. Этот path создаётся поверх переданного subpath и не в какой RelOptInfo не попадает.

# В чём собственно проблема

Наш код вызывает `try_nestloop_path`, чтобы построить joinpath(sorted, inner) и добавить его в RelOptInfo. Когда тип джойна SEMI_JOIN - всё норм, мы же легально отсортировали аутер и теперь просто выполняем операцию. Однако по коду выше, `match_unsorted_outer()` подменил jointype и мы по факту вставляем INNER JOIN(sorted, inner) в RelOptInfo для SEMI_JOIN. Это точно некорректно.

# Вопросы

* А нужна ли фича для любого jointype? Может стоит подсократить пространство поиска?