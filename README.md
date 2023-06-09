# ClickHouse_test_task
Тестовое задание на позицию "ClickHouse DBA"
## Условие
Кластер 30 шардов по 2 реплики

На кластере таблица wbdailydata, куда записываются данные формата
date, sku, name, sells
таблица шардирована по sku

Ежедневно мы получаем данные о том, что товар A похож на товар B, на товар C, на товар D и тд. Товар B похож на товар AA, на товар CC и на товар DD

На странице товара A нам необходимо отобразить все товары, которые за последние 30 суток оказывались в списке товаров, похожих на товар A, или на любой товар, который похож на товар А (т.е. похож на товар А или похож на товар, похожий на товар А), т.е. для товара А это будут B, C, D, а так же AA, CC и DD.
Список товаров необходимо дополнить информацией о суммарной выручке по каждому из товаров за последние 30 дней.

Прошу составить схему хранения данных и привести пример запроса для отображения списка товаров.

## Решение
* Будем считать, что отношение товаров "похож на" [симметрично](https://ru.wikipedia.org/wiki/%D0%A1%D0%B8%D0%BC%D0%BC%D0%B5%D1%82%D1%80%D0%B8%D1%87%D0%BD%D0%BE%D0%B5_%D0%BE%D1%82%D0%BD%D0%BE%D1%88%D0%B5%D0%BD%D0%B8%D0%B5) и [транзитивно](https://ru.wikipedia.org/wiki/%D0%A2%D1%80%D0%B0%D0%BD%D0%B7%D0%B8%D1%82%D0%B8%D0%B2%D0%BD%D0%BE%D1%81%D1%82%D1%8C), те если товар A похож на B, то товар B похож на A. Если товар A похож на B, а B похож на C, то A похож на C.
* Тогда такие отношения можно представить в виде [неориентированного графа](http://pco.iis.nsk.su/grapp/index.php/%D0%93%D1%80%D0%B0%D1%84_(%D0%BD%D0%B5%D0%BE%D1%80%D0%B8%D0%B5%D0%BD%D1%82%D0%B8%D1%80%D0%BE%D0%B2%D0%B0%D0%BD%D0%BD%D1%8B%D0%B9_%D0%B3%D1%80%D0%B0%D1%84)) и будем его хранить в виде списка ребер (таблица `similar_goods_edges`), которые поддерживает какой-то ML-сервис, который по многим критериям определяет "схожесть" товаров. Он же и будет вставлять эти ребра в таблицу `similar_goods_edges`.
* На таблице `similar_goods_edges` установлен `TTL` в 30 дней, тк по условию отношение "похож на" протухает через этот промежуток времени. Для эффективности установлена настройка `ttl_only_drop_parts`, чтобы при протухании, партиция просто дропалась, а не запускалась мутация `DELETE`. Таблица партицирована по полю `date` (все есть в  [schema.sql](schema.sql)).
* Другой сервис, будет считывать список ребер из `similar_goods_edges` и строить внутри себя граф товаров с отношением "похож на". Он будет вычислять [компоненты связности графа](https://ru.wikipedia.org/wiki/%D0%9A%D0%BE%D0%BC%D0%BF%D0%BE%D0%BD%D0%B5%D0%BD%D1%82%D0%B0_%D1%81%D0%B2%D1%8F%D0%B7%D0%BD%D0%BE%D1%81%D1%82%D0%B8_%D0%B3%D1%80%D0%B0%D1%84%D0%B0), где в каждой компоненте будут товары друг на друга похожие (В [schema.sql](schema.sql) есть пример заполнения на данных из условия) и складывать результат в таблицу `similar_goods`. Сложность такого алгоритма - `O(V + E)`, где V - кол-во товаров, E - кол-во связей "похож на", те для сотен миллонов товаров отработает довольно быстро (линейно).
* Для оптимизации запроса по суммам продаж товаров используется `SummingMergeTree` по полям `name` и `date`, так что все покупки по товару в рамках одного дня будут сжаты в одну строчку, что должно дать хороший прирост, тк покупок по одному товару могут быть сотни в рамках дня (тогда получим в 100 раз меньше строк и соответственно почти 100x ускорение запроса, по сравнению с исходной таблицей. Для заполнения `SummingMergeTree` в автоматическом режиме используется `materialized view`.
* Финальный запрос с ответом на вопрос из условия представлен [здесь](https://github.com/artem-pershin/ClickHouse_test_task/blob/main/schema.sql#L75). Для тестовых данных он выведет (для товара A):

|name  |sum(sells)  |
-------|-------------
| A    |          1 |
| AA   |          5 |
| B    |          2 |
| C    |          3 |
| CC   |          7 |
| DD   |          8 |

Считаем, что кластер сконфигурирован корректно и на каждой ноде определены макросы (`select * from systemm.macros`). `{cluster}`, `{replica}`, `{shard}`, `{cluster_all_replica}` (Для кластера, состоящего и 1 шарда и 60 реплик).

Как сделать такое полностью на SQL эффективно - я не знаю (тем более что в `ClickHouse` нет конструкции 'WITH RECURSIVE', как в `PostgreSQL`, например). Но даже с рекурсивными `CTE` он будет работать оч долго на том же `PostgreSQL`, и это не спасет от циклов в графе, которые случайно может нагенерить ML-сервис.

Для оптимизации поиска по массиву оператором `has` в таблице `similar_goods` можно уменьшить ее гранулярность и сделать [блум-фильтр](https://clickhouse.com/docs/en/optimize/skipping-indexes#bloom-filter-types)
