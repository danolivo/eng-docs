# Предикаты по numeric в планах 1С на PostgreSQL

**Дата:** 2026-11-18
**Объект:** нагрузка 1С (базы `erp_v`, `cherkizovo`), корпус запросов и планов
`erp_v-run1` и `cherkizovo-run1`, стенд 10.200.100.103, кластер `pgdev-1c`, PG 18.
**Статус:** предварительный обзор по материалам ранее подготовленных отчётов
корпуса; новых запросов к корпусу не выполнялось.

## Цель

Установить, где в схеме 1С используется тип `numeric`, в каких формах
numeric-предикаты появляются в узлах сканирования (Index Cond и Filter у
Index Scan, Index Only Scan, Seq Scan), и наметить, что нужно посчитать
по корпусу для количественной оценки.

## Numeric в схеме 1С

| Колонка | Тип | Где встречается | Типичное использование в предикате |
|---|---|---|---|
| `_FldNNNN` — разделитель (в обеих базах `_Fld4617`) | `numeric(7,0)` | все таблицы; **ведущая колонка каждого индекса** | `= CAST(? AS NUMERIC)`, фактически всегда `= 0` |
| `_RecordKind` (приход/расход) | `numeric(1,0)` | регистры накопления | внутри `CASE` в агрегатах |
| `_LineNo` | `numeric(5..9,0)` | табличные части, регистры | хвостовая колонка индекса по регистратору; `ORDER BY` |
| `_Splitter` | `numeric(10,0)` | таблицы итогов `_AccumRgT*` | колонка индекса итогов |
| `_EnumOrder` | `numeric(10,0)` | перечисления | `ORDER BY` |
| `_FldNNN_N` | `numeric` | числовая часть составного типа | в паре с `_FldNNN_TYPE = '\x03'` |
| ресурсы и реквизиты | `numeric(15,2)` и т.п. | регистры, документы | `<> 0` в Filter итогов и в HAVING |

Размерности типов указаны по памяти и с каталогом стенда не сверялись.

## Наблюдаемые формы предикатов

### Разделитель в Index Cond [корпус]

`cherkizovo-run1`, `text_hash = f63b7b4abf77eafc`.

```sql
LEFT OUTER JOIN _Reference840 T3
  ON (T1._Q_000_F_001RRef = T3._IDRRef) AND (T3._Fld4617 = CAST(? AS NUMERIC))
LEFT OUTER JOIN _Reference840 T4
  ON (T3._IDRRef = T4._IDRRef) AND (T4._Fld4617 = CAST(? AS NUMERIC))
```

```json
{ "Alias": "t3", "Node Type": "Index Only Scan",
  "Relation Name": "_reference840", "Index Name": "_reference840_s_hpk",
  "Index Cond": "((t3._fld4617 = '0'::numeric) AND (t3._idrref = t1._q_000_f_001rref))",
  "Actual Rows": 1.0, "Actual Total Time": 0.009 },
{ "Alias": "t4", "Node Type": "Index Scan",
  "Relation Name": "_reference840", "Index Name": "_reference840_s_hpk",
  "Index Cond": "((t4._fld4617 = '0'::numeric) AND (t4._idrref = t3._idrref))",
  "Actual Rows": 1.0, "Actual Total Time": 0.003 }
```

Это самая массовая numeric-форма в нагрузке. Селективность предиката равна
1.0, потому что все строки имеют значение 0. При этом сравнение
`numeric = numeric` выполняется на каждом спуске по B-дереву.

### Чтение движений регистра по регистратору [реконструкция]

```sql
SELECT ... FROM _AccumRg50090 T1
WHERE T1._Fld4617 = CAST(? AS NUMERIC)
  AND T1._RecorderTRef = ? AND T1._RecorderRRef = ?
ORDER BY T1._LineNo
```
```
Index Scan using <индекс по регистратору: _fld4617, _recordertref, _recorderrref, _lineno>
  Index Cond: ((_fld4617 = '0'::numeric) AND (_recordertref = '\x...'::bytea)
               AND (_recorderrref = '\x...'::bytea))
```

Имя индекса и порядок колонок нужно проверить по `\d`.

### Фильтр по ресурсам вне индекса [корпус]

`erp_v`. В исходном плане одна и та же дизъюнкция повторена дважды.

```
(((t9._fld50098 <> '0'::numeric) OR (t9._fld50100 <> '0'::numeric) OR (t9._fld50099 <> '0'::numeric))
 AND
 ((t9._fld50098 <> '0'::numeric) OR (t9._fld50100 <> '0'::numeric) OR (t9._fld50099 <> '0'::numeric)))
```

Форма «хотя бы один ресурс ненулевой» типична для таблиц итогов и остатков.
Тип узла и таблица в исходном отчёте не зафиксированы. Ожидается, что
Index Cond покрывает разделитель и период, а `<> 0` остаётся в Filter;
при Seq Scan весь предикат переходит в Filter.

### Numeric-флаги на временных таблицах [корпус]

Класс FLAG_CASE; на вход узла поступает **13 107 982 строки**.

```
max(CASE WHEN (_q_000_f_000 = '-1'::numeric) THEN '1'::numeric ELSE '0'::numeric END)
max(CASE WHEN ((_q_000_f_009 <> '0'::numeric) OR (_q_000_f_011 <> '0'::numeric))
         THEN '1'::numeric ELSE '0'::numeric END)
```

Формально это не условие сканирования, но по стоимости эквивалентно ему:
numeric-сравнение выполняется на каждую строку.

### `_RecordKind` в расчёте остатков [корпус]

`cherkizovo`, HAVING над `UNION ALL`.

```
(((sum('0'::numeric))::numeric(27,3) <> '0'::numeric)
 OR (sum(CASE WHEN (t3._recordkind = '0'::numeric) THEN t3._fld122796 ELSE '0'::numeric END) <> '0'::numeric)
 OR …)
```

### Составной тип с числовой частью [реконструкция]

```
Filter: ((t1._fld123_type = '\x03'::bytea) AND (t1._fld123_n = '5'::numeric))
```

## Выводы

1. **Index Cond.** Numeric почти всегда представлен равенством
   `разделитель = 0` в ведущей колонке индекса. Предикат присутствует
   в каждом индексе и, при наличии разделителя, в каждом обращении к таблице.
   Его селективность равна 1.0.
2. **Filter (Seq Scan, Index Scan).** Основные формы: `ресурс <> 0`,
   флаги `= -1` / `= 0` на временных таблицах `ttNNN`, `_RecordKind = 0`.
3. **Диапазоны по numeric** в просмотренных материалах не встречались.
   Диапазонные условия в 1С стоят на `_Period` (timestamp). Это наблюдение
   не подкреплено подсчётом.
4. **Тяжёлые Seq Scan по временным таблицам** фильтруют в основном по
   `bytea` (`_q_001_f_NNN_type`, `_rrref`), а не по numeric. Пример —
   77-минутный `Seq Scan on tt896` в cherkizovo.
5. **Контекст по типам узлов** (`erp_v`, 208 648 планов): Index Scan — 93 683,
   Seq Scan — 84 451.
