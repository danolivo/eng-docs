# ТЗ: Outer Rows Matched в EXPLAIN ANALYZE

Nov 5, 2026 · @Andrei Lepikhov

## Цель

Добавить в EXPLAIN ANALYZE для узлов Nested Loop, Hash Join и Merge Join строку `Outer Rows Matched`: сколько прочитанных внешних строк нашли хотя бы одну пару. Строки без пары — производная величина: `rows` внешнего узла минус это число. Метрика не зависит от типа join-узла, поэтому планы одного запроса становятся сравнимыми.

Зачем:

- Планировщик оценивает долю внешних строк с парой (`eqjoinsel_semi`), но фактическое значение после выполнения сейчас не видно. После Hash Join или Merge Join его нельзя вывести даже из всех существующих счётчиков.
- Большой разрыв между `rows` внешнего узла и `Outer Rows Matched` на большой стороне при маленькой второй — сигнал, что не хватает индекса на ключе соединения и параметризованный Nested Loop прочитал бы только строки с парой.
- Существующий `Rows Removed by Join Filter` считает только остаточный `joinqual`, поэтому у разных узлов он несравним (`990` у Nested Loop против отсутствующей строки у Hash Join на одном запросе). Его не меняем.

Контекст: [тред на pgsql-hackers](https://www.postgresql.org/message-id/e1073bc5-bde7-400c-b7ea-275d6567fb6f@gmail.com). Код сверен с master `e50ace7c12`.

## Определения

Внешняя строка **matched**, если для неё нашлась хотя бы одна внутренняя строка, на которой истинны все join keys и `Join Filter`. `Filter` на это не влияет. Так executor уже определяет match для outer joins (`plannodes.h`, комментарий к `struct Join`); мы ничего нового не вводим.

**Unmatched outer** — производная величина: внешние строки, которые join-узел получил от outer child, но не смог сопоставить, то есть `rows` outer-узла − `Outer Rows Matched`. Строки, которые узел не прочитал (ранний выход Merge Join, пустая хеш-таблица), не учитываются.

Условия join-узла и их роль:

| Условие | Где в плане | В EXPLAIN | Влияет на match |
| --- | --- | --- | --- |
| Join keys, Nested Loop | Во внутреннем параметризованном скане (`nestParams`) | `Index Cond` / `Filter` у inner-узла | Да |
| Join keys, Hash Join | `hashclauses` | `Hash Cond` | Да |
| Join keys, Merge Join | `mergeclauses` | `Merge Cond` | Да |
| Остаточный предикат | `join.joinqual` | `Join Filter` | Да |
| Фильтр результата (только outer/semi/anti) | `plan.qual` | `Filter` | Нет |

Внешние строки с NULL в ключе считаются unmatched: пары у них быть не может.

## Вывод в EXPLAIN

Новая строка `Outer Rows Matched` показывается только при `ANALYZE`: сколько внешних строк нашли хотя бы одну пару, в среднем на loop, как `rows`. Это физический счётчик события, которое executor уже отмечает флагом `*_MatchedOuter`. Сравнивается напрямую с `rows` outer-узла на том же экране.

1. **Узлы:** Nested Loop, Hash Join, Merge Join, все jointype, кроме `JOIN_RIGHT_SEMI` (см. «Особые случаи»).
2. **Значение:** `nmatched_outer / nloops`, без дробной части, как в `show_instrumentation_count`.
3. **Текстовый формат:** строка печатается, только если фильтрация ненулевая — хотя бы одна внешняя строка осталась без пары (Outer Rows Matched < rows outer-узла).
4. **JSON / XML / YAML:** ключ `"Outer Rows Matched"` печатается всегда.
5. **Порядок строк узла:** `Hash Cond` / `Merge Cond` → `Join Filter` → `Rows Removed by Join Filter` → **`Outer Rows Matched`** → `Filter` → `Rows Removed by Filter`.
6. **Старые строки не меняются** ни по смыслу, ни по формату.

Ожидаемый вывод для примера из треда (100 × 10, внешняя сторона — 100 строк, пара есть у 10 из них):

```
Hash Join (actual rows=10.00 loops=1)
  Hash Cond: (x.x = y.y)
  Outer Rows Matched: 10
  ->  Function Scan on generate_series x (actual rows=100.00 loops=1)
  ->  Hash (actual rows=10.00 loops=1)
        ->  Function Scan on generate_series y (actual rows=10.00 loops=1)

Nested Loop (actual rows=10.00 loops=1)
  Join Filter: (x.x = y.y)
  Rows Removed by Join Filter: 990
  Outer Rows Matched: 10
  ->  Function Scan on generate_series x (actual rows=100.00 loops=1)
  ...
```

Решение: в текстовом формате строка выводится только при ненулевой фильтрации, когда хотя бы одна внешняя строка осталась без пары. Если пару нашли все, `Outer Rows Matched` совпадает с `rows` outer-узла и ничего не добавляет. Поэтому expected существующих тестов меняются только там, где строки без пары действительно есть.

Строки без пары читаются прямо с экрана: `rows` у `generate_series x` минус `Outer Rows Matched`, 100 − 10 = 90.

## Реализация

Считаем matched и выводим как есть: это физическое событие с одним путём в каждом узле. Путей «не нашла пару» десяток (NULL-ключи, конец inner, пропуск в Merge Join, null-хранилища Hash Join), и считать их по отдельности ненадёжно.

**Хранение.** Существующее поле `ntuples2` в `NodeInstrumentation` (*secondary node-specific tuple counter*). Оно per-node, join-узлы его не используют, а matched outer rows — как раз счётчик кортежей. Инкремент — готовый макрос `InstrCountTuples2` (`execnodes.h`), суммирование по воркерам уже есть в `InstrAggNode` (`instrument.c`). Новых полей и DSM-ключей нет. ModifyTable использует `ntuples2` по той же схеме: `Tuples Inserted = outer.ntuples − ntuples2`.

Почему не новое поле `nfiltered3`: для join имя вводило бы в заблуждение — там лежали бы matched, а не отфильтрованные строки.

**Места инкремента** — переход флага `*_MatchedOuter` из false в true после прохождения `joinqual`:

| Узел | Файл и место | Замечание |
| --- | --- | --- |
| Nested Loop | `nodeNestloop.c`, `nl_MatchedOuter = true` в `ExecNestLoop` | Сейчас флаг ставится на каждую пару — нужен guard `if (!...)` |
| Hash Join | `nodeHashjoin.c`, `hj_MatchedOuter = true` в `HJ_SCAN_BUCKET` | Один код для serial и parallel |
| Merge Join | `nodeMergejoin.c`, `mj_MatchedOuter = true` в `EXEC_MJ_JOINTUPLES`, **только там** | В `NEXTOUTER`, `SKIPOUTER_ADVANCE`, `ENDINNER` флаг означает «null-extended уже выдан», там считать нельзя |

```c
if (!node->nl_MatchedOuter)
{
    node->nl_MatchedOuter = true;
    InstrCountTuples2(node, 1);
}
```

**EXPLAIN.** В `ExplainNode`, в ветках `T_NestLoop`, `T_MergeJoin`, `T_HashJoin`: сначала `InstrEndLoop(outerPlanState(planstate)->instrument)` (как делает ModifyTable, иначе текущий loop child ещё не сложен в `ntuples`), потом проверка условия показа (matched < outer ntuples) и печать. Логику вынести в функцию `show_join_matched()`, чтобы не дублировать в трёх ветках.

**Стоимость.** Без ANALYZE — ноль: макрос проверяет `instrument != NULL`. С ANALYZE — одно сложение на совпавшую внешнюю строку, а не на пару; это дешевле существующего `nfiltered1`.

## Особые случаи

| Случай | Поведение | Требование |
| --- | --- | --- |
| `JOIN_RIGHT_SEMI` (только Hash Join) | Проверка `HeapTupleHeaderHasMatch` делает `continue` до `joinqual`; внешняя строка с парой может не выставить `hj_MatchedOuter` | Не показывать метрику |
| SEMI, ANTI, `inner_unique` (`single_match`) | Счётчик срабатывает на первом совпадении, дальше executor идёт к следующей строке | Корректно, особых действий не нужно |
| NULL во внешнем ключе | Hash Join отбрасывает строку в `ExecHashJoinOuterGetTuple` или кладёт в `hj_NullOuterTupleStore`; Merge Join — `MJEVAL_NONMATCHABLE` | Автоматически unmatched: child строку отдал, match не было |
| Многобатчевый Hash Join | Строка из batch-файла читается мимо child; matched решается один раз, в её батче | Корректно; покрыть тестом |
| Parallel (в т.ч. Parallel Hash) | И `ntuples` child, и `ntuples2` суммируются по воркерам в `InstrAggNode` | Корректно; покрыть тестом |
| Rescan, `loops > 1` | Оба счётчика накапливаются, делим на `nloops` join-узла | Корректно |
| Ранний выход (пустая хеш-таблица, конец входа у Merge Join) | Непрочитанные строки не учитываются | Задокументировать: метрика считается от прочитанных строк |
| LIMIT выше по плану | Последняя внешняя строка с незаконченным поиском может попасть в unmatched (ошибка ≤ 1 на loop) | Задокументировать; в тестах не ставить LIMIT над проверяемым join |

## Тесты и критерии приёмки

Регрессионные тесты — в `join.sql` (или отдельный файл), через `EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)`. Тип узла фиксируется `enable_*`; что внешняя сторона та же, видно по форме плана в expected.

- [ ] **Инвариантность:** один запрос с одной внешней стороной даёт одинаковый `Outer Rows Matched` на Nested Loop, Hash Join и Merge Join — для INNER, LEFT, SEMI, ANTI, FULL.
- [ ] **Перекрёстные проверки без `Filter`:** SEMI — `Outer Rows Matched = rows`; ANTI — `Outer Rows Matched = outer rows − rows`; INNER с `Inner Unique` — `Outer Rows Matched = rows`.
- [ ] **Параметризованный Nested Loop:** то же значение, что у Hash Join, хотя условие ушло в `Index Cond`.
- [ ] **Остаточный `Join Filter`:** строка, прошедшая `Hash Cond`, но не `Join Filter`, считается unmatched; строка, не прошедшая только `Filter`, — matched.
- [ ] **NULL-ключи** во внешней стороне для INNER и LEFT на всех трёх узлах.
- [ ] **Многобатчевый Hash Join** (`work_mem = 64kB`, в плане `Batches > 1`) даёт то же число, что однобатчевый.
- [ ] **Parallel Hash Join** даёт то же число, что serial (в `select_parallel.sql`, с маскировкой `Workers Launched`).
- [ ] **Rescan:** join внутри Nested Loop с `loops > 1`, значение корректно усреднено.
- [ ] **RIGHT\_SEMI:** строки нет.
- [ ] **Форматы:** в тексте строки нет, если пару нашли все внешние строки; в JSON ключ есть всегда.
- [ ] **Старые тесты:** `make check-world` зелёный; изменения expected — только новые строки `Outer Rows Matched` там, где есть внешние строки без пары; список затронутых файлов приложить к письму.
- [ ] **Накладные расходы:** EXPLAIN ANALYZE хеш-соединения 10M × 10M с патчем и без — разница в пределах шума (медиана 10 прогонов).
- [ ] **Документация:** абзац в `perform.sgml` («Using EXPLAIN»): определение, «от прочитанных строк», оговорка про LIMIT, исключение RIGHT\_SEMI.

## Вне рамок

- **`Inner Rows Matched`** — кандидат во второй параметр по той же схеме. Для Hash Join он почти бесплатен там, где match-биты уже сканируются (RIGHT, FULL, RIGHT\_ANTI). Для Merge Join сравнение с `rows` inner-узла ломается: после `ExecRestrPos` child повторно отдаёт строки. Для Nested Loop дешёвого способа нет. Отдельный патч.
- **Разбивка «отсеяно ключами / отсеяно Join Filter».** По определению зависит от плана; если вернёмся — только под `VERBOSE`.
- **Изменение `Rows Removed by Join Filter`.** Остаётся как есть.
- **Накопительная статистика** (pg\_stat\_statements и подобное). Только EXPLAIN и auto\_explain, который получает метрику бесплатно.

**Запасной вариант хранения.** Если ревьюеры возразят против переиспользования `ntuples2`, первый запасной вариант — новое общее поле `nfiltered3` в `NodeInstrumentation` с макросом `InstrCountFiltered3`, которое другие узлы смогут использовать по-своему. Второй — `JoinInstrumentation` / `SharedJoinInstrumentation` (`instrument_node.h`) по образцу `IndexScanInstrumentation`: счётчик в `JoinState`, четыре функции `Exec*Instrument*` и три `case` в `execParallel.c`. Семантика, вывод и тесты при этом не меняются.
