8种常见SQL错误用法
db匠  Spark学习技巧  3天前
来源：https://yq.aliyun.com/articles/72501

1、LIMIT 语句
分页查询是最常用的场景之一，但也通常也是最容易出问题的地方。比如对于下面简单的语句，一般 DBA 想到的办法是在 type, name, create_time 字段上加组合索引。这样条件排序都能有效的利用到索引，性能迅速提升。

SELECT *
FROM   operation
WHERE  type = 'SQLStats'
       AND name = 'SlowLog'
ORDER  BY create_time
LIMIT  1000, 10;
好吧，可能90%以上的 DBA 解决该问题就到此为止。但当 LIMIT 子句变成 “LIMIT 1000000,10” 时，程序员仍然会抱怨：我只取10条记录为什么还是慢？

要知道数据库也并不知道第1000000条记录从什么地方开始，即使有索引也需要从头计算一次。出现这种性能问题，多数情形下是程序员偷懒了。

在前端数据浏览翻页，或者大数据分批导出等场景下，是可以将上一页的最大值当成参数作为查询条件的。SQL 重新设计如下：

SELECT   *
FROM     operation
WHERE    type = 'SQLStats'
AND      name = 'SlowLog'
AND      create_time > '2017-03-16 14:00:00'
ORDER BY create_time limit 10;
在新设计下查询时间基本固定，不会随着数据量的增长而发生变化。

2、隐式转换
SQL语句中查询变量和字段定义类型不匹配是另一个常见的错误。比如下面的语句：

mysql> explain extended SELECT *
     > FROM   my_balance b
     > WHERE  b.bpn = 14000000123
     >       AND b.isverified IS NULL ;
mysql> show warnings;
| Warning | 1739 | Cannot use ref access on index 'bpn' due to type or collation conversion on field 'bpn'
其中字段 bpn 的定义为 varchar(20)，MySQL 的策略是将字符串转换为数字之后再比较。函数作用于表字段，索引失效。

上述情况可能是应用程序框架自动填入的参数，而不是程序员的原意。现在应用框架很多很繁杂，使用方便的同时也小心它可能给自己挖坑。

3、关联更新、删除
虽然 MySQL5.6 引入了物化特性，但需要特别注意它目前仅仅针对查询语句的优化。对于更新或删除需要手工重写成 JOIN。

比如下面 UPDATE 语句，MySQL 实际执行的是循环/嵌套子查询（DEPENDENT SUBQUERY)，其执行时间可想而知。

UPDATE operation o
SET    status = 'applying'
WHERE  o.id IN (SELECT id
                FROM   (SELECT o.id,
                               o.status
                        FROM   operation o
                        WHERE  o.group = 123
                               AND o.status NOT IN ( 'done' )
                        ORDER  BY o.parent,
                                  o.id
                        LIMIT  1) t);
执行计划：

+----+--------------------+-------+-------+---------------+---------+---------+-------+------+-----------------------------------------------------+
| id | select_type        | table | type  | possible_keys | key     | key_len | ref   | rows | Extra                                               |
+----+--------------------+-------+-------+---------------+---------+---------+-------+------+-----------------------------------------------------+
| 1  | PRIMARY            | o     | index |               | PRIMARY | 8       |       | 24   | Using where; Using temporary                        |
| 2  | DEPENDENT SUBQUERY |       |       |               |         |         |       |      | Impossible WHERE noticed after reading const tables |
| 3  | DERIVED            | o     | ref   | idx_2,idx_5   | idx_5   | 8       | const | 1    | Using where; Using filesort                         |
+----+--------------------+-------+-------+---------------+---------+---------+-------+------+-----------------------------------------------------+
重写为 JOIN 之后，子查询的选择模式从 DEPENDENT SUBQUERY 变成 DERIVED，执行速度大大加快，从7秒降低到2毫秒。

UPDATE operation o
       JOIN  (SELECT o.id,
                            o.status
                     FROM   operation o
                     WHERE  o.group = 123
                            AND o.status NOT IN ( 'done' )
                     ORDER  BY o.parent,
                               o.id
                     LIMIT  1) t
         ON o.id = t.id
SET    status = 'applying'
执行计划简化为：

+----+-------------+-------+------+---------------+-------+---------+-------+------+-----------------------------------------------------+
| id | select_type | table | type | possible_keys | key   | key_len | ref   | rows | Extra                                               |
+----+-------------+-------+------+---------------+-------+---------+-------+------+-----------------------------------------------------+
| 1  | PRIMARY     |       |      |               |       |         |       |      | Impossible WHERE noticed after reading const tables |
| 2  | DERIVED     | o     | ref  | idx_2,idx_5   | idx_5 | 8       | const | 1    | Using where; Using filesort                         |
+----+-------------+-------+------+---------------+-------+---------+-------+------+-----------------------------------------------------+
4、混合排序
MySQL 不能利用索引进行混合排序。但在某些场景，还是有机会使用特殊方法提升性能的。

SELECT *
FROM   my_order o
       INNER JOIN my_appraise a ON a.orderid = o.id
ORDER  BY a.is_reply ASC,
          a.appraise_time DESC
LIMIT  0, 20
执行计划显示为全表扫描：

+----+-------------+-------+--------+-------------+---------+---------+---------------+---------+-+
| id | select_type | table | type   | possible_keys     | key     | key_len | ref      | rows    | Extra
+----+-------------+-------+--------+-------------+---------+---------+---------------+---------+-+
|  1 | SIMPLE      | a     | ALL    | idx_orderid | NULL    | NULL    | NULL    | 1967647 | Using filesort |
|  1 | SIMPLE      | o     | eq_ref | PRIMARY     | PRIMARY | 122     | a.orderid |       1 | NULL           |
+----+-------------+-------+--------+---------+---------+---------+-----------------+---------+-+
由于 is_reply 只有0和1两种状态，我们按照下面的方法重写后，执行时间从1.58秒降低到2毫秒。

SELECT *
FROM   ((SELECT *
         FROM   my_order o
                INNER JOIN my_appraise a
                        ON a.orderid = o.id
                           AND is_reply = 0
         ORDER  BY appraise_time DESC
         LIMIT  0, 20)
        UNION ALL
        (SELECT *
         FROM   my_order o
                INNER JOIN my_appraise a
                        ON a.orderid = o.id
                           AND is_reply = 1
         ORDER  BY appraise_time DESC
         LIMIT  0, 20)) t
ORDER  BY  is_reply ASC,
          appraisetime DESC
LIMIT  20;
5、EXISTS语句
MySQL 对待 EXISTS 子句时，仍然采用嵌套子查询的执行方式。如下面的 SQL 语句：

SELECT *
FROM   my_neighbor n
       LEFT JOIN my_neighbor_apply sra
              ON n.id = sra.neighbor_id
                 AND sra.user_id = 'xxx'
WHERE  n.topic_status < 4
       AND EXISTS(SELECT 1
                  FROM   message_info m
                  WHERE  n.id = m.neighbor_id
                         AND m.inuser = 'xxx')
       AND n.topic_type <> 5
执行计划为：

+----+--------------------+-------+------+-----+------------------------------------------+---------+-------+---------+ -----+
| id | select_type        | table | type | possible_keys     | key   | key_len | ref   | rows    | Extra   |
+----+--------------------+-------+------+ -----+------------------------------------------+---------+-------+---------+ -----+
|  1 | PRIMARY            | n     | ALL  |  | NULL     | NULL    | NULL  | 1086041 | Using where                   |
|  1 | PRIMARY            | sra   | ref  |  | idx_user_id | 123     | const |       1 | Using where          |
|  2 | DEPENDENT SUBQUERY | m     | ref  |  | idx_message_info   | 122     | const |       1 | Using index condition; Using where |
+----+--------------------+-------+------+ -----+------------------------------------------+---------+-------+---------+ -----+
去掉 exists 更改为 join，能够避免嵌套子查询，将执行时间从1.93秒降低为1毫秒。

SELECT *
FROM   my_neighbor n
       INNER JOIN message_info m
               ON n.id = m.neighbor_id
                  AND m.inuser = 'xxx'
       LEFT JOIN my_neighbor_apply sra
              ON n.id = sra.neighbor_id
                 AND sra.user_id = 'xxx'
WHERE  n.topic_status < 4
       AND n.topic_type <> 5
新的执行计划：

+----+-------------+-------+--------+ -----+------------------------------------------+---------+ -----+------+ -----+
| id | select_type | table | type   | possible_keys     | key       | key_len | ref   | rows | Extra                 |
+----+-------------+-------+--------+ -----+------------------------------------------+---------+ -----+------+ -----+
|  1 | SIMPLE      | m     | ref    | | idx_message_info   | 122     | const    |    1 | Using index condition |
|  1 | SIMPLE      | n     | eq_ref | | PRIMARY   | 122     | ighbor_id |    1 | Using where      |
|  1 | SIMPLE      | sra   | ref    | | idx_user_id | 123     | const     |    1 | Using where           |
+----+-------------+-------+--------+ -----+------------------------------------------+---------+ -----+------+ -----+
6、条件下推
外部查询条件不能够下推到复杂的视图或子查询的情况有：

聚合子查询；

含有 LIMIT 的子查询；

UNION 或 UNION ALL 子查询；

输出字段中的子查询；

如下面的语句，从执行计划可以看出其条件作用于聚合子查询之后：

SELECT *
FROM   (SELECT target,
               Count(*)
        FROM   operation
        GROUP  BY target) t
WHERE  target = 'rm-xxxx'
+----+-------------+------------+-------+---------------+-------------+---------+-------+------+-------------+
| id | select_type | table      | type  | possible_keys | key         | key_len | ref   | rows | Extra       |
+----+-------------+------------+-------+---------------+-------------+---------+-------+------+-------------+
|  1 | PRIMARY     | <derived2> | ref   | <auto_key0>   | <auto_key0> | 514     | const |    2 | Using where |
|  2 | DERIVED     | operation  | index | idx_4         | idx_4       | 519     | NULL  |   20 | Using index |
+----+-------------+------------+-------+---------------+-------------+---------+-------+------+-------------+
确定从语义上查询条件可以直接下推后，重写如下：

SELECT target,
       Count(*)
FROM   operation
WHERE  target = 'rm-xxxx'
GROUP  BY target
执行计划变为：

+----+-------------+-----------+------+---------------+-------+---------+-------+------+--------------------+
| id | select_type | table | type | possible_keys | key | key_len | ref | rows | Extra |
+----+-------------+-----------+------+---------------+-------+---------+-------+------+--------------------+
| 1 | SIMPLE | operation | ref | idx_4 | idx_4 | 514 | const | 1 | Using where; Using index |
+----+-------------+-----------+------+---------------+-------+---------+-------+------+--------------------+
关于 MySQL 外部条件不能下推的详细解释说明请参考文章：

http://mysql.taobao.org/monthly/2016/07/08

7、提前缩小范围
先上初始 SQL 语句：

SELECT *
FROM   my_order o
       LEFT JOIN my_userinfo u
              ON o.uid = u.uid
       LEFT JOIN my_productinfo p
              ON o.pid = p.pid
WHERE  ( o.display = 0 )
       AND ( o.ostaus = 1 )
ORDER  BY o.selltime DESC
LIMIT  0, 15
该SQL语句原意是：先做一系列的左连接，然后排序取前15条记录。从执行计划也可以看出，最后一步估算排序记录数为90万，时间消耗为12秒。

+----+-------------+-------+--------+---------------+---------+---------+-----------------+--------+----------------------------------------------------+
| id | select_type | table | type   | possible_keys | key     | key_len | ref             | rows   | Extra                                              |
+----+-------------+-------+--------+---------------+---------+---------+-----------------+--------+----------------------------------------------------+
|  1 | SIMPLE      | o     | ALL    | NULL          | NULL    | NULL    | NULL            | 909119 | Using where; Using temporary; Using filesort       |
|  1 | SIMPLE      | u     | eq_ref | PRIMARY       | PRIMARY | 4       | o.uid |      1 | NULL                                               |
|  1 | SIMPLE      | p     | ALL    | PRIMARY       | NULL    | NULL    | NULL            |      6 | Using where; Using join buffer (Block Nested Loop) |
+----+-------------+-------+--------+---------------+---------+---------+-----------------+--------+----------------------------------------------------+
由于最后 WHERE 条件以及排序均针对最左主表，因此可以先对 my_order 排序提前缩小数据量再做左连接。SQL 重写后如下，执行时间缩小为1毫秒左右。

SELECT *
FROM (
SELECT *
FROM   my_order o
WHERE  ( o.display = 0 )
       AND ( o.ostaus = 1 )
ORDER  BY o.selltime DESC
LIMIT  0, 15
) o
     LEFT JOIN my_userinfo u
              ON o.uid = u.uid
     LEFT JOIN my_productinfo p
              ON o.pid = p.pid
ORDER BY  o.selltime DESC
limit 0, 15
再检查执行计划：子查询物化后（select_type=DERIVED)参与 JOIN。虽然估算行扫描仍然为90万，但是利用了索引以及 LIMIT 子句后，实际执行时间变得很小。

+----+-------------+------------+--------+---------------+---------+---------+-------+--------+----------------------------------------------------+
| id | select_type | table      | type   | possible_keys | key     | key_len | ref   | rows   | Extra                                              |
+----+-------------+------------+--------+---------------+---------+---------+-------+--------+----------------------------------------------------+
|  1 | PRIMARY     | <derived2> | ALL    | NULL          | NULL    | NULL    | NULL  |     15 | Using temporary; Using filesort                    |
|  1 | PRIMARY     | u          | eq_ref | PRIMARY       | PRIMARY | 4       | o.uid |      1 | NULL                                               |
|  1 | PRIMARY     | p          | ALL    | PRIMARY       | NULL    | NULL    | NULL  |      6 | Using where; Using join buffer (Block Nested Loop) |
|  2 | DERIVED     | o          | index  | NULL          | idx_1   | 5       | NULL  | 909112 | Using where                                        |
+----+-------------+------------+--------+---------------+---------+---------+-------+--------+----------------------------------------------------+
8、中间结果集下推
再来看下面这个已经初步优化过的例子(左连接中的主表优先作用查询条件)：

SELECT    a.*,
          c.allocated
FROM      (
              SELECT   resourceid
              FROM     my_distribute d
                   WHERE    isdelete = 0
                   AND      cusmanagercode = '1234567'
                   ORDER BY salecode limit 20) a
LEFT JOIN
          (
              SELECT   resourcesid， sum(ifnull(allocation, 0) * 12345) allocated
              FROM     my_resources
                   GROUP BY resourcesid) c
ON        a.resourceid = c.resourcesid
那么该语句还存在其它问题吗？不难看出子查询 c 是全表聚合查询，在表数量特别大的情况下会导致整个语句的性能下降。

其实对于子查询 c，左连接最后结果集只关心能和主表 resourceid 能匹配的数据。因此我们可以重写语句如下，执行时间从原来的2秒下降到2毫秒。

SELECT    a.*,
          c.allocated
FROM      (
                   SELECT   resourceid
                   FROM     my_distribute d
                   WHERE    isdelete = 0
                   AND      cusmanagercode = '1234567'
                   ORDER BY salecode limit 20) a
LEFT JOIN
          (
                   SELECT   resourcesid， sum(ifnull(allocation, 0) * 12345) allocated
                   FROM     my_resources r,
                            (
                                     SELECT   resourceid
                                     FROM     my_distribute d
                                     WHERE    isdelete = 0
                                     AND      cusmanagercode = '1234567'
                                     ORDER BY salecode limit 20) a
                   WHERE    r.resourcesid = a.resourcesid
                   GROUP BY resourcesid) c
ON        a.resourceid = c.resourcesid
但是子查询 a 在我们的SQL语句中出现了多次。这种写法不仅存在额外的开销，还使得整个语句显的繁杂。使用 WITH 语句再次重写：

WITH a AS
(
         SELECT   resourceid
         FROM     my_distribute d
         WHERE    isdelete = 0
         AND      cusmanagercode = '1234567'
         ORDER BY salecode limit 20)
SELECT    a.*,
          c.allocated
FROM      a
LEFT JOIN
          (
                   SELECT   resourcesid， sum(ifnull(allocation, 0) * 12345) allocated
                   FROM     my_resources r,
                            a
                   WHERE    r.resourcesid = a.resourcesid
                   GROUP BY resourcesid) c
ON        a.resourceid = c.resourcesid
总结
数据库编译器产生执行计划，决定着SQL的实际执行方式。但是编译器只是尽力服务，所有数据库的编译器都不是尽善尽美的。

上述提到的多数场景，在其它数据库中也存在性能问题。了解数据库编译器的特性，才能避规其短处，写出高性能的SQL语句。

程序员在设计数据模型以及编写SQL语句时，要把算法的思想或意识带进来。

编写复杂SQL语句要养成使用 WITH 语句的习惯。简洁且思路清晰的SQL语句也能减小数据库的负担 。


mysql的性能优化包罗甚广： 索引优化，查询优化，查询缓存，服务器设置优化，操作系统和硬件优化，应用层面优化（web服务器，缓存）等等。

建立索引的几个准则：

1、合理的建立索引能够加速数据读取效率，不合理的建立索引反而会拖慢数据库的响应速度。 2、索引越多，更新数据的速度越慢。 3、尽量在采用MyIsam作为引擎的时候使用索引（因为MySQL以BTree存储索引），而不是InnoDB。但MyISAM不支持Transcation。 4、当你的程序和数据库结构/SQL语句已经优化到无法优化的程度，而程序瓶颈并不能顺利解决，那就是应该考虑使用诸如memcached这样的分布式缓存系统的时候了。 5、习惯和强迫自己用EXPLAIN来分析你SQL语句的性能。

1. count的优化

计算id大于5的城市 a. select count(*) from world.city where id > 5; b. select (select count(*) from world.city) – count(*) from world.city where id <= 5; a语句当行数超过11行的时候需要扫描的行数比b语句要多， b语句扫描了6行，此种情况下，b语句比a语句更有效率

当没有where语句的时候直接select count(*) from world.city这样会更快，因为mysql总是知道表的行数。

2. 避免使用不兼容的数据类型。

例如float和int、char和varchar、binary和varbinary是不兼容的。数据类型的不兼容可能使优化器无法执行一些本来可以进行的优化操作。 在程序中，保证在实现功能的基础上，尽量减少对数据库的访问次数；通过搜索参数，尽量减少对表的访问行数,最小化结果集，从而减轻网络负担；能够分开的操作尽量分开处理，提高每次的响应速度；在数据窗口使用SQL时，尽量把使用的索引放在选择的首列；算法的结构尽量简单；在查询时，不要过多地使用通配符如 SELECT * FROM T1语句，要用到几列就选择几列如：SELECT COL1,COL2 FROM T1；在可能的情况下尽量限制尽量结果集行数如：SELECT TOP 300 COL1,COL2,COL3 FROM T1,因为某些情况下用户是不需要那么多的数据的。不要在应用中使用数据库游标，游标是非常有用的工具，但比使用常规的、面向集的SQL语句需要更大的开销；按照特定顺序提取数据的查找。

3. 索引字段上进行运算会使索引失效。

尽量避免在WHERE子句中对字段进行函数或表达式操作，这将导致引擎放弃使用索引而进行全表扫描。如： SELECT * FROM T1 WHERE F1/2=100 应改为: SELECT * FROM T1 WHERE F1=100*2

4. 避免使用!=或＜＞、IS NULL或IS NOT NULL、IN ，NOT IN等这样的操作符.

因为这会使系统无法使用索引,而只能直接搜索表中的数据。例如: SELECT id FROM employee WHERE id != “B%” 优化器将无法通过索引来确定将要命中的行数,因此需要搜索该表的所有行。在in语句中能用exists语句代替的就用exists.

5. 尽量使用数字型字段.

一部分开发人员和数据库管理人员喜欢把包含数值信息的字段 设计为字符型，这会降低查询和连接的性能，并会增加存储开销。这是因为引擎在处理查询和连接回逐个比较字符串中每一个字符，而对于数字型而言只需要比较一次就够了。

6. 合理使用EXISTS,NOT EXISTS子句。如下所示：

1.SELECT SUM(T1.C1) FROM T1 WHERE (SELECT COUNT(*)FROM T2 WHERE T2.C2=T1.C2>0) 2.SELECT SUM(T1.C1) FROM T1WHERE EXISTS(SELECT * FROM T2 WHERE T2.C2=T1.C2) 两者产生相同的结果，但是后者的效率显然要高于前者。因为后者不会产生大量锁定的表扫描或是索引扫描。如果你想校验表里是否存在某条纪录，不要用count(*)那样效率很低，而且浪费服务器资源。可以用EXISTS代替。如： IF (SELECT COUNT(*) FROM table_name WHERE column_name = ‘xxx’)可以写成：IF EXISTS (SELECT * FROM table_name WHERE column_name = ‘xxx’)

7. 能够用BETWEEN的就不要用IN

8. 能够用DISTINCT的就不用GROUP BY

9. 尽量不要用SELECT INTO语句。SELECT INTO 语句会导致表锁定，阻止其他用户访问该表。

10. 必要时强制查询优化器使用某个索引

SELECT * FROM T1 WHERE nextprocess = 1 AND processid IN (8,32,45) 改成： SELECT * FROM T1 (INDEX = IX_ProcessID) WHERE nextprocess = 1 AND processid IN (8,32,45) 则查询优化器将会强行利用索引IX_ProcessID 执行查询。

11. 消除对大型表行数据的顺序存取

尽管在所有的检查列上都有索引，但某些形式的WHERE子句强迫优化器使用顺序存取。如： SELECT * FROM orders WHERE (customer_num=104 AND order_num>1001) OR order_num=1008 解决办法可以使用并集来避免顺序存取： SELECT * FROM orders WHERE customer_num=104 AND order_num>1001 UNION SELECT * FROM orders WHERE order_num=1008 这样就能利用索引路径处理查询。【jacking 数据结果集很多，但查询条件限定后结果集不大的情况下，后面的语句快】

12. 尽量避免在索引过的字符数据中，使用非打头字母搜索。这也使得引擎无法利用索引。

见如下例子： SELECT * FROM T1 WHERE NAME LIKE ‘%L%’ SELECT * FROM T1 WHERE SUBSTING(NAME,2,1)=’L’ SELECT * FROM T1 WHERE NAME LIKE ‘L%’ 即使NAME字段建有索引，前两个查询依然无法利用索引完成加快操作，引擎不得不对全表所有数据逐条操作来完成任务。而第三个查询能够使用索引来加快操作，不要习惯性的使用 ‘%L%’这种方式(会导致全表扫描)，如果可以使用`L%’相对来说更好;

13. 虽然UPDATE、DELETE语句的写法基本固定，但是还是对UPDATE语句给点建议：

a) 尽量不要修改主键字段。 b) 当修改VARCHAR型字段时，尽量使用相同长度内容的值代替。 c) 尽量最小化对于含有UPDATE触发器的表的UPDATE操作。 d) 避免UPDATE将要复制到其他数据库的列。 e) 避免UPDATE建有很多索引的列。 f) 避免UPDATE在WHERE子句条件中的列。

14. 能用UNION ALL就不要用UNION

UNION ALL不执行SELECT DISTINCT函数，这样就会减少很多不必要的资源 在跨多个不同的数据库时使用UNION是一个有趣的优化方法，UNION从两个互不关联的表中返回数据，这就意味着不会出现重复的行，同时也必须对数据进行排序，我们知道排序是非常耗费资源的，特别是对大表的排序。 UNION ALL可以大大加快速度，如果你已经知道你的数据不会包括重复行，或者你不在乎是否会出现重复的行，在这两种情况下使用UNION ALL更适合。此外，还可以在应用程序逻辑中采用某些方法避免出现重复的行，这样UNION ALL和UNION返回的结果都是一样的，但UNION ALL不会进行排序。

15. 字段数据类型优化：

a. 避免使用NULL类型：NULL对于大多数数据库都需要特殊处理，MySQL也不例外，它需要更多的代码，更多的检查和特殊的索引逻辑，有些开发人员完全没有意识到，创建表时NULL是默认值，但大多数时候应该使用NOT NULL，或者使用一个特殊的值，如0，-1作为默认值。 b. 尽可能使用更小的字段，MySQL从磁盘读取数据后是存储到内存中的，然后使用cpu周期和磁盘I/O读取它，这意味着越小的数据类型占用的空间越小，从磁盘读或打包到内存的效率都更好，但也不要太过执着减小数据类型，要是以后应用程序发生什么变化就没有空间了。修改表将需要重构，间接地可能引起代码的改变，这是很头疼的问题，因此需要找到一个平衡点。 c. 优先使用定长型

16. 关于大数据量limit分布的优化见下面链接（当偏移量特别大时，limit效率会非常低）：

http://ariyue.iteye.com/blog/553541 附上一个提高limit效率的简单技巧，在覆盖索引(覆盖索引用通俗的话讲就是在select的时候只用去读取索引而取得数据，无需进行二次select相关表)上进行偏移，而不是对全行数据进行偏移。可以将从覆盖索引上提取出来的数据和全行数据进行联接，然后取得需要的列，会更有效率，看看下面的查询： mysql> select film_id, description from sakila.film order by title limit 50, 5; 如果表非常大，这个查询最好写成下面的样子： mysql> select film.film_id, film.description from sakila.film inner join(select film_id from sakila.film order by title liimit 50,5) as film usinig(film_id);

17. 程序中如果一次性对同一个表插入多条数据，比如以下语句：

insert into person(name,age) values(‘xboy’, 14); insert into person(name,age) values(‘xgirl’, 15); insert into person(name,age) values(‘nia’, 19); 把它拼成一条语句执行效率会更高. insert into person(name,age) values(‘xboy’, 14), (‘xgirl’, 15),(‘nia’, 19);

18. 不要在选择的栏位上放置索引，这是无意义的。应该在条件选择的语句上合理的放置索引，比如where，order by。

SELECT id,title,content,cat_id FROM article WHERE cat_id = 1;

上面这个语句，你在id/title/content上放置索引是毫无意义的，对这个语句没有任何优化作用。但是如果你在外键cat_id上放置一个索引，那作用就相当大了。

19. ORDER BY语句的MySQL优化： a. ORDER BY + LIMIT组合的索引优化。如果一个SQL语句形如：

SELECT [column1],[column2],…. FROM [TABLE] ORDER BY [sort] LIMIT [offset],[LIMIT];

这个SQL语句优化比较简单，在[sort]这个栏位上建立索引即可。

b. WHERE + ORDER BY + LIMIT组合的索引优化，形如：

SELECT [column1],[column2],…. FROM [TABLE] WHERE [columnX] = [VALUE] ORDER BY [sort] LIMIT [offset],[LIMIT];

这个语句，如果你仍然采用第一个例子中建立索引的方法，虽然可以用到索引，但是效率不高。更高效的方法是建立一个联合索引(columnX,sort)

c. WHERE + IN + ORDER BY + LIMIT组合的索引优化，形如：

SELECT [column1],[column2],…. FROM [TABLE] WHERE [columnX] IN ([value1],[value2],…) ORDER BY [sort] LIMIT [offset],[LIMIT];

这个语句如果你采用第二个例子中建立索引的方法，会得不到预期的效果（仅在[sort]上是using index，WHERE那里是using where;using filesort），理由是这里对应columnX的值对应多个。 目前哥还木有找到比较优秀的办法，等待高手指教。

d.WHERE+ORDER BY多个栏位+LIMIT，比如:

SELECT * FROM [table] WHERE uid=1 ORDER x,y LIMIT 0,10;

对于这个语句，大家可能是加一个这样的索引:(x,y,uid)。但实际上更好的效果是(uid,x,y)。这是由MySQL处理排序的机制造成的。

20. 其它技巧：

http://www.cnblogs.com/nokiaguy/archive/2008/05/24/1206469.html http://www.cnblogs.com/suchshow/archive/2011/12/15/2289182.html http://www.cnblogs.com/cy163/archive/2009/05/28/1491473.html http://www.cnblogs.com/younggun/articles/1719943.html http://wenku.baidu.com/view/f57c7041be1e650e52ea9985.html


MySQL的万能嵌套循环并不是对每种查询都是最优的。不过MySQL查询优化器只对少部分查询不适用，而且我们往往可以通过改写查询让MySQL高效的完成工作。

1 关联子查询
MySQL的子查询实现的非常糟糕。最糟糕的一类查询时where条件中包含in()的子查询语句。因为MySQL对in()列表中的选项有专门的优化策略，一般会认为MySQL会先执行子查询返回所有in()子句中查询的值。一般来说，in()列表查询速度很快，所以我们会以为sql会这样执行

select * from tast_user where id in (select id from user where name like '王%');
我们以为这个sql会解析成下面的形式
select * from tast_user where id in (1,2,3,4,5);
实际上MySQL是这样解析的
select * from tast_user where exists
(select id from user where name like '王%' and tast_user.id = user.id);
MySQL会将相关的外层表压缩到子查询中，它认为这样可以更高效的查找到数据行。

这时候由于子查询用到了外部表中的id字段所以子查询无法先执行。通过explin可以看到，MySQL先选择对tast_user表进行全表扫描，然后根据返回的id逐个执行子查询。如果外层是一个很大的表，那么这个查询的性能会非常糟糕。当然我们可以优化这个表的写法：

select tast_user.* from tast_user inner join user using(tast_user.id) where user.name like '王%'
另一个优化的办法就是使用group_concat()在in中构造一个由逗号分隔的列表。有时这比上面使用关联改写更快。因为使用in()加子查询，性能通常会非常糟糕。所以通常建议使用exists()等效的改写查询来获取更好的效率。

如何书写更好的子查询就不在介绍了，因为现在基本都要求拆分成单表查询了，有兴趣的话可以自行去了解下。

2 UNION的限制
有时，MySQL无法将限制条件从外层下推导内层，这使得原本能够限制部分返回结果的条件无法应用到内层查询的优化上。

如果希望union的各个子句能够根据limit只取部分结果集，或者希望能够先排好序在合并结果集的话，就需要在union的各个子句中分别使用这些子句。例如，想将两个子查询结果联合起来，然后在取前20条，那么MySQL会将两个表都存放到一个临时表中，然后在去除前20行。

(select first_name,last_name from actor order by last_name) union all
(select first_name,last_name from customer order by  last_name) limit 20;
这条查询会将actor中的记录和customer表中的记录全部取出来放在一个临时表中，然后在取前20条，可以通过在两个子查询中分别加上一个limit 20来减少临时表中的数据。

现在中间的临时表只会包含40条记录了，处于性能考虑之外，这里还需要注意一点：从临时表中取出数据的顺序并不是一定，所以如果想获得正确的顺序，还需要在加上一个全局的order by操作

3 索引合并优化
前面文章中已经提到过，MySQL能够访问单个表的多个索引以合并和交叉过滤的方式来定位需要查找的行。

4 等值传递
某些时候，等值传递会带来一些意想不到的额外消耗。例如，有一个非常大的in()列表，而MySQL优化器发现存在where/on或using的子句，将这个列表的值和另一个表的某个列相关联。

那么优化器会将in()列表都赋值应用到关联的各个表中。通常，因为各个表新增了过滤条件，优化器可以更高效的从存储引擎过滤记录。但是如果这个列表非常大，则会导致优化和执行都会变慢。

5 并行执行
MySQL无法利用多核特性来并行执行查询。很多其他的关系型数据库鞥能够提供这个特性，但MySQL做不到。这里特别指出是想提醒大家不要花时间去尝试寻找并行执行查询的方法。

6 哈希关联
在2013年MySQL并不执行哈希关联，MySQL的所有关联都是嵌套循环关联。不过可以通过建立一个哈希索引来曲线实现哈希关联如果使用的是Memory引擎，则索引都是哈希索引，所以关联的时候也类似于哈希关联。另外MariaDB已经实现了哈希关联。

7 松散索引扫描
由于历史原因，MySQL并不支持松散索引扫描，也就无法按照不连续的方式扫描一个索引。通常，MySQL的索引扫描需要先定义一个起点和重点，即使需要的数据只是这段索引中很少的几个，MySQL仍需要扫描这段索引中每个条目。

例：现有索引（a,b）

select * from table where b between 2 and 3;

因为索引的前导字段是a，但是在查询中只指定了字段b，MySQL无法使用这个索引，从而只能通过全表扫描找到匹配的行。

MySQL全表扫描：


了解索引的物理结构的话，不难发现还可以有一个更快的办法执行上面的查询。索引的物理结构不是存储引擎的API使得可以先扫描a列第一个值对应的b列的范围，然后在跳到a列第二个不同值扫描对应的b列的范围



这时就无需在使用where子句过滤，因为松散索引扫描已经跳过了所有不需要的记录。

上面是一个简单的例子，处理松散索引扫描，新增一个合适的索引当然也可以优化上述查询。但对于某些场景，增加索引是没用的，例如，对于第一个索引列是范围条件，第二个索引列是等值提交建查询，靠增加索引就无法解决问题。

MySQL5.6之后，关于松散索引扫描的一些限制将会通过索引条件吓退的分行是解决。

8 最大值和最小值优化
对于MIN()和MAX()查询，MySQL的优化做的并不好，例：

select min(actor_id) from actor where first_name = 'wang'
因为在first_name字段上并没有索引，因此MySQL将会进行一次全表扫描。如果MySQL能够进行主键扫描，那么理论上，当MySQL读到第一个太满足条件的记录的时候就是我们需要的最小值了，因为主键是严哥按照actor_id字段的大小排序的。但是MySSQL这时只会做全表扫描，我们可以通过show status的全表扫描计数器来验证这一点。一个区县优化办法就是移除min()函数，然后使用limit 1来查询。

这个策略可以让MySQL扫描尽可能少的记录数。这个例子告诉我们有时候为了获得更高的性能，就得放弃一些原则。

9 在同一个表上查询和更新
MySQL不允许对同一张表同时进行查询和更新。这并不是优化器的限制，如果清楚MySQL是如何执行查询的，就可以避免这种情况。例：

update table set cnt = (select count(*) from table as tb where tb.type = table.type);
这个sql虽然符合标准单无法执行，我们可以通过使用生成表的形式绕过上面的限制，因为MySQL只会把这个表当做一个临时表来处理。

update table inner join
(select type,count(*) as cnt from table group by type) as tb using(type)
set table.cnt = tb.cnt;
实际上这执行了两个查询：一个是子查询中的select语句，另一个是夺标关联update，只是关联的表时一个临时表。子查询会在update语句打开表之前就完成，所以会正常执行。

10 查询优化器的提示（hint）
如果对优化器选择的执行计划不满意，可以使用优化器提供的几个提示（hint）来控制最终的执行计划。下面将列举一些常见的提示，并简单的给出什么时候使用该提示。通过在查询中加入响应的提示，就可以控制该查询的执行计划。

① HIGH_PRIORITY 和 LOW_PRIORITY

这个提示告诉MySQL，当多个语句同时访问某一表的时候，哪些语句的优先级相对高些，哪些语句优先级相对低些。

HIGH_PRIORITY用于select语句的时候，MySQL会将此select语句重新调度到所有正在表锁以便修改数据的语句之前。实际上MySQL是将其放在表的队列的最前面，而不是按照常规顺序等待。HIGH_PRIORITY还可以用于insert语句，其效果只是简单的体校了全局LOW_PRIORITY设置对该语句的影响。

LOW_PRIORITY则正好相反，它会让语句一直处于等待状态，只要在队列中有对同一表的访问，就会一直在队尾等待。在CRUD语句中都可以使用。

这两个提示只对使用表锁的存储引擎有效，不能在InnoDB或其他有细粒度所机制和并发控制的引擎中使用。在MyISAM中也要慎用，因为这两个提示会导致并发插入被禁用，可能会严重降低性能。

HIGH_PRIORITY和LOW_PRIORITY其实只是简单的控制了MySQL访问某个数据表的队列顺序。

② DELAYED

这个提示对insert和replace有效。MySSQL会将使用该提示的语句立即返回给客户端，并将插入的行数据放入缓冲区，然后在表空闲时批量将数据写入。日志型系统使用这样的提示非常有效，或者是其他需要写入大量数据但是客户端却不需要等待单条语句完成I/O的应用。这个用法有一些限制。并不是所有的存储引擎都支持，并且该提示会导致函数last_insert_id()无法正常工作。

③ STRAIGHT_JOIN

这个提示可以防止在select语句的select关键字之后，也可以防止在任何两个关联表的名字之间。第一个用法是让查询中所有的表按照在语句中出现的顺序进行关联。第二个用法则是固定其前后两个表的关联顺序。

当MySQL没能选择正确的关联顺序的时候，或者由于可能的顺序太多导致MySQL无法评估所有的关联顺序的时候，STRAIGHT_JOIN都会很有用，在MySQL可能会发给大量时间在statistics状态时，加上这个提示则会大大减少优化器的搜索空间

④ SQL_SMALLRESULT和SQL_BIG_RESULT

这个两个提示只对select语句有效。他们告诉优化器对group by或者distinct查询如何使用临时表及排序。SQL_SMALL_RESULT告诉优化器结果集会很小，可以将结果集放在内存中的索引临时表，以避免排序操作。如果是SQL_BIG_RESULT，则会告诉优化器结果集可能会非常大，建议使用磁盘临时表做排序操作。

⑤ SQL_BUFFER_RESULT

这个提示告诉优化器将查询结果放入一个临时表，然后尽可能快速释放表锁。这和前面提到的由客户端缓存结果不同。当你无法使用客户端缓存的时候，使用服务器端的缓存通常很有效。好处是无需在客户端上消耗过多内存，还能尽快释放表锁。代价是服务器端将需要更多的内存。

⑥ SQL_CACHE和SQL_NO_CACHE

这个提示告诉MySQL这个结果集是否应该放入查询缓存中。

⑦ SQL_CALC_FOUND_ROWS

严哥来说，这并不是一个优化器提示。它不会告诉优化器任何关于执行计划的东西。它会让MySQL返回的结果集包含更多的信息。查询中加上该提示MySQL会计算limit子句之后这个查询要返回的结果集总数，而实际上值返回limit要求的结果集。可以通过函数found_row()获得这个值。慎用，后面会说明为什么。

⑧ FOR UPDATE和LOCK IN SHARE MODE

这两个提示主要控制select语句的锁机制，但只对实现了行级锁的存储引擎有效。使用该提示会对符合查询条件的数据行加锁。对于insert/select语句是不需要这两个提示的因为5.0以后会默认给这些记录加上读锁。

唯一内置的支持这两个提示的引擎就是InnoDB，可以禁用该默认行为。另外需要记住的是，这两个提示会让某些优化无法正常使用，例如索引覆盖扫描。InnoDB不能在不访问主键的情况下排他的锁定行，因为行的版本信息保存在主键中。

如果这两个提示被经常滥用，很容易早晨服务器的锁争用问题。

⑨ USE INDEX、IGNORE INDEX和FORCE INDEX

这几个提示会告诉优化器使用或者不使用那些索引来查询记录。

在5.0版本以后新增了一些参数来控制优化器的行为：

① optimizer_search_depth

这个参数控制优化器在穷举执行计划时的限度。如果查询长时间处于statistics状态，那么可以考虑调低此参数。

② optimizer_prune_level

该参数默认是打开的，这让优化器会根据需要扫描的行数来决定是否跳过某些执行计划。

③optimizer_switch

这个变量包含了一些开启/关闭优化器特性的标志位。

前面两个参数时用来控制优化器可以走的一些捷径。这些捷径可以让优化器在处理非常复杂的SQL语句时，可以更高效，但也可能让优化器错过一些真正最优的执行计划，所以慎用。

修改优化器提示可能在MySQL更新后让新版的优化策略失效，所以一定要谨慎


1 优化count()查询
count()聚合函数，以及如何优化使用了该函数的查询，很可能是MySQL中最容易被误解的前10个话题之一。网上随便搜搜就能看到很多错误的理解。

在优化之前，先来看看count()函数的真正作用是什么。

count()的作用
count()是一个特殊的函数，有两种非常不同的作用：它可以统计某个列值的数量，也可以统计行数。在统计列值时要求列值时非空的，并不统计null值。如果在

count()的括号中指定了列或者列的表达式，则统计的就是这个表达式有值的结果数。因为很多人对null理解有问题，所以这里很容易产生误解。如果先更了解更过关于sql语句中null的含义，建议阅读一些关于sql语句基础的书籍。网上的一些信息是不够精确的。

count()的另一个作用是统计结果集的行数。当MySQL确认括号内的表达式不可能为空时，实际上就是在统计行数。最简单的就是当我们使用count(*)的时候，这种情况下通配符*并不会像我们想的那样扩展成所有的列，实际上，它会忽略所有的列而直接统计所有的行数。

我们发现一个最常见的错误就是，在括号内指定了一个列却希望统计结果集的行数。如果希望指定的是结果集的行数最好是用count(*)，这样写意义清晰，性能也会很好。

关于MyISAM的神话
一个容易产生误解的就是是MyISAM的count()函数总是非常快的，不过这是由前提条件的，即只有没有任何where条件的count(*)才非常快，因为此时无需实际的去计算表的行数。MySQL可以利用存储引擎的特性直接获得这个值。如果MySQL知道某列不可能为null值，那么MySQL内部会将count(col)优化为count(*)。

当统计带有where子句的结果集行数，可以是统计某个列的数量时，MyISAM的count()和其他存储引擎没有任何不同，就不在有神话般的速度了。所以在MyISAM引擎表上执行count()有时候比别的引擎快，着受很多因素的影响，视情况而定。

简单的优化
有时候可以使用MyISAM在count(*)全表非常快的这个特性，来加速一些特定条件的count()查询。

在邮件组和IRC聊天频道中，通常会看到这样的问题：如何在同一个查询中统计一个列的不同值的数量，以减少查询的语句量。例如，假设可能需要通过一个查询返回各种不同颜色的商品数量，此时不能是用or语句，因为这样无法区分不同颜色的商品数量，也不能在where条件中指定颜色，因为颜色条件时互斥的。下面这个查询可以在一定程度上解决这个问题。

select sum(if(color = 'blue',1,0)) as blue,sum(if(color = 'red',1,0)) as red from table
也可以使用count()而不是sum()实现同样的目的，只需要将满足条件设置为真，不满足添加设置为null即可：

select count(color = 'blue' or null) as blue,count(color = 'red' or null) as red from table
使用近似值
有时候某些业务场景并不要求完全精确的count值，因此可以用近似值来代替。explain出来的优化器估算的行数就是一个很不错的金色之，执行explain并不需要真正的去执行查询，所以成本很低。

很多时候，计算精确值的成本非常高，而计算近似值则非常简单。

例如统计一个网站的当前活跃用户数是多少，这个活跃用户数保存在缓存中，每隔30分钟计算一次。因此这个活跃用户数本身就不是精确值，所以使用近似值代替是可以接受的。另外，如果要精确统计在线人数，通常where条件会很复杂，一方面要提出当前非活跃用户，还要提出系统中某些特定id的默认用户，去掉这些约束条件对中枢的影响很少，但却可能很好的提升该查询的性能。更进一步的优化则可以尝试删除distinct这样的约束来避免文件排序。这样重写过的查询要比原来的精确统计的查询快很多，返回结果则几乎相同。

复杂的优化
通常来说，count()都需要扫描大量的行才能获得精确的结果，因此是很难优化的。除了前面的方法，在MySQL层面还能做的就只有索引覆盖扫描了。如果这还不够，就需要考虑修改应用的架构，可以增加汇总表或者类似Memcached这样的外部缓存系统。可能你很快就会发现陷入到一个熟悉的问题，“快速，精确和实现简单”，三者永远只能满足其二，必须舍弃一个。

2 优化关联查询
这里需要特别提到的是以下几点：

① 确保on或using子句中的列上有索引。

在创建索引的时候就要考虑到关联的顺序。当表A和表B用列c关联的时候，如果优化器的关联顺序是B A那么久不需要在B列的对应列上建立索引。没有用到的索引只会带来额外的负担。一般来说，除非有其他理由，否则值需要在关联顺序中的第二个表的响应列上创建索引。

② 确保任何group by和order by中的表达式只涉及到一个表的列，这样MySQL才有可能使用索引来优化这个过程。

③ 当升级MySQL的时候需要注意：关联语法、运算符优先级等其他可能会发生变化的地方。因为以前是普通关联的地方可能会变成笛卡尔积，不同类型的关联可能会生成不同的结果等。

3 优化子查询
关于子查询优化我们给出的最重要的优化建议就是尽可能使用关联查询代替，尽可能使用关联并不是绝对的，5.6以后的版本或MariaDB就可以忽略这个建议了。

4 优化GROUP BY和DISTINCT
在很多场景下，MySQL都使用同样的办法优化这两种查询，试试上，MySQL优化器会在内部处理的时候互相转化这两类查询。他们都可以使用索引来优化，这也是最有效的优化办法。

在MySQL中，当无法使用索引的时候，group by使用两种策略来完成：使用临时表或者文件排序来做分组。对于任何查询语句，这两种策略的性能都有可以提升的地方。可以使用提示SQL_BIG_RESULT和SQL_SMALL_RESULT来让优化器按照你希望的方式运行。

如果需要对关联查询做分组，并且是按照查找表中的某个列进行分组，那么通常采用查找表的标识列分组的效率会比其他列更高。例如下面这个查询效率就不会很好：

select first_name,last_name,count(*)
from tast_user inner join actor using(actor_id)
group by actor.first_name,actor.last_name
可以优化为：

select actor.first_name,actor.last_name,count(*)
from tast_user inner join actor using(actor_id)
group by tast_user.actor_id
使用actor.actor_id列分组的效率会比使用tast_user.actor_id更好。这一点通过简单的测试即可验证。

这个查询利用了演员的姓名和id直接相关的特点，因此改写后的结果不收影响，但显然不是所有的关联语句的分组查询都可以改写成select中直接使用费分组列的形式的。甚至可能会在服务器上设置SQL_MODE来禁止这样的写法。如果是这样，也可以通过min()或max()函数来绕过这种限制，但一定要清楚，select后面出现的非分组列一定是直接依赖分组列，并且在每个组内的值是唯一的，或者是业务上根本不在乎这个值是什么。

select min(actor.first_name),max(actor.last_name),count(*)
from tast_user inner join actor using(actor_id)
group by tast_user.actor_id
当然这种写法只在乎查询效率，如果实在较真的话也可以改写成下面的形式

select actor.first_name,actor.last_name,c.cnt
from actor
inner join (select actor_id ,count(*) as cnt from tast_user group by actor_id) c
using(actor_id);
这样写更满足关系理论，但成本有点高，因为子查询需要创建和填充临时表，而子查询中创建的临时表是没有任何索引的。

在分组查询的select中直接使用费分组列通常都不是什么好主意，因为这样的结果通常是补丁的，当索引改变，或者优化器选择不同的优化策略时都可能导致结果不一样。我们碰到的大多数这种查询最后都导致了故障，而且这种写法大部分是由于偷懒而不是为优化而故意这么设计的。建议使用含义明确的语法。事实上，我们建议将MySQL的SQL_MODE设置为包含ONLY_FULL_GROUP_BY，这时MySQL会对这类查询直接返回一个错误，提醒你需要重写查询。

如果没有通过order by子句显示的指定培训列，当使用group by子句的时候，结果集会自动按照分组的字段进行排序。如果不关心结果集的顺序，而这种默认排序有导致了需要文件排序，则可以使用order by null，让MySQL不在进行文件排序。也可以在group by子句中直接使用desc或asc关键字让分组的结果集按需要的方向排序。

优化GROUP BY WITH ROLLUP
分组查询的一个变种就是要求MySQL对返回的分组结果在做一次超级聚合。可以使用WITH ROLLUP子句来实现这种逻辑，但可能会不够优化。可以通过explain来观察其执行计划，特别要注意分组是否是通过文件排序或临时表实现的。然后在去掉WITH ROLLUP子句看看执行计划是否相同。也可以通过前面介绍的优化器提示来固定执行计划。

很多时候，如果可以，在应用程序中做超级聚合是更好的，虽然这需要返回给客户端更多的结果。也可以在from子句中嵌套使用子查询，或者通过临时表存放中间数据，然后和临时表执行union来得到最终结果。

最好的办法是尽可能的将WITH ROLLUP功能转移到应用程序中处理。

5 优化LIMIT分页
在系统中需要进行分页操作的时候，我们通常会使用limit加上偏移量的方法实现，同时加上合适的order by子句，如果有对应的索引，通常效率会不错，否则MySQL需要做大量的文件排序操作。

一个非常常见的问题就是，在偏移量非常大的时候，例如可能是limit 1000,10这样的查询，前面1000条记录都被抛弃，这样的代价非常高。如果所有的页面被访问的频率都相同，那么这样的查询平均需要访问半个表的数据。要优化这种查询，要么是在页面中限制分页的数量，要么是优化大偏移量的性能。

优化此类分页查询的一个最简单的办法就是尽可能的使用索引覆盖扫描，而不是查询所有的列。然后根据需要做一次关联操作再返回所需的列。对于偏移量很大的时候，这样的效率会提升非常大，例：

select id,name from tast_user order by create_date limit 50,5;
如果这个表非常大，那么这个查询最好改写成这个样子：

select id,name from tast_user inner join(
    select id from tast_user order by create_date limit 50,5
    ) as usr using(id);
这里的延迟关联将大大提升查询效率，它让MySQL扫描尽可能少的页面，获取需要访问的记录后在根据关联列回原表查询需要的所有列。这个技术也可以用于优化关联查询中的limit子句。

有时候也可以将limit查询转换为已知位置的查询，让MySQL通过范围扫描获得到对应的结果。例如，如果一个位置列上有索引，并且预先计算出了边界值，上面的查询就可以改写为：

select id,name from tast_user where id between 50 and 54 order by create_date;
对数据进行排名的问题也与此类似，但往往还会同时和group by混合使用。在这种情况下通常都需要先计算并存储排名信息。

limit和offset的问题，offset会导致MySQL扫描大量不需要的行然后在抛弃掉。如果可以使用书签记录上次取数据的位置，那么下次就可以直接从该书签记录的位置开始扫描，这样就可以避免使用offset。例如，在翻页时根据最新的一条记录向后追溯，这种做法可行是因为记录的主键是单调增长的：

select id,name from tast_user order by create_date desc limit 20;
假设上面的查询返回的主键为16049 到 16030 ，那么下一页就可以从16030这个点开始：

select id,name from tast_user where id < 16030 order by create_date desc limit 20;
这个sql的好处就是无论翻页到多么大的数据条数性能都会很好。

其他优化办法还包括使用预先计算的汇总表，或者关联到一个冗余表，冗余表只包含主键列和需要做排序的数据列。还可以使用sphinx优化一些搜索操作。

6 优化SQL_CALC_FOUND_ROWS
分页的时候，另一个常用的技巧是在limit语句中加上SQL_CALC_FOUND_ROWS提示（hint），这样就可以获得去掉limit以后满足条件的行数，因此可以作为分页的总数。看起来，MySQL做了一些非常高深的优化，像是通过某种方法预测了总行数。但实际上，MySQL只有在扫描了所有满足条件的行以后，才会知道行数，所以加上这个提示以后，不管是否需要，MySQL都会扫描所有满足条件的行，然后在抛弃掉不需要的行，而不是在满足limit的行数就终止扫描。所以该提示的代价可能非常高。

一个更好的设计是将具体的页数韩城下一些按钮，假设每页显示20记录，那么我们每次查询都使用limit返回21条记录并只显示20条，如果第21条存在，那么我们就显示下一些按钮，否则就说明没有更多的数据，那么下一页按钮就不会出现了。

另一种做法是先获取并缓存较多的数据；例如，缓存1000条；然后每次分页都从这个缓存中获取。这样做可以让应用程序根据结果集的大小采取不同的策略，如果结果集少于1000，就可以在页面上显示所有的分页链接，因为数据都在缓存中，所以这样做性能不会有问题。如果结果集大于1000，则可以在页面上设计一个额外的找到结果多余1000条这类的按钮。这两种策略都比每次生成全部结果集在抛弃掉不需要的数据的效率要高很多。

有时候也可以考虑使用explain的结果中的rows列的值作为结果集总数的近似值（google的搜索结果总数也是近似值）。当需要精确结果的时候，在单独使用count（*）来满足需求，这时如果能够使用索引覆盖扫描则通常也会比SQL_CALC_FOUND_ROWS快的多。

7 优化UNION查询
MySQL总是通过创建并填充临时表的方式来执行UNION查询。因此很多优化策略在UNION查询中都没法很好的使用。经常需要手工的将where、limit、order by等子句下推到union的各个子查询中，以便于优化器可以充分利用这些条件进行优化。

除非确实需要服务器消除重复的行否则就一定要使用UNION ALL，这一点很重要。如果没有ALL关键字，MySQL会给临时表加上distinct选项，这会导致对整个零食表的数据做唯一性检查。这样做的代价非常高。即使有ALL关键字，MySQL仍然会使用临时表存储结果。事实上，MySQL总是将结果放入临时表，然后在独处，在返回给客户端。

虽然有时候没必要这样做。

8 静态查询分析
Percona Toolkit中的pt-query-advisor能够解析查询日志、分析查询模式，然后给出所有可能存在潜在问题的查询，并给出足够详细的建议。这像是给MySQL所有的查询做健康检查。它能检测出许多常见问题。

9 使用用户自定义变量
用户自定义变量使一个很容易被遗忘的特性，但是如果能够用好，发挥其潜力，在某些场景可以写出非常搞笑的查询语句。在查询中混合使用过程化和关系化逻辑的时候，自定义变量可能会非常有用。单纯的关系查询将所有的东西都当成无需的数据集合，并且一次性操作他们。MySQL则采用了更加程序化的处理方式。MySQL的这种方式有它的弱点，但如果能熟练的掌握，则会发现其强大之处，而用户自定义变量可以给这种法师带来很大的帮助。

用户自定义变量使一个用来存储内容的临时容器，在链接MySQL的整个过程中都存在。可以使用下面的set和select语句来定义它们。

set @one := 1;
set @hundred := 100;
select * from tast_user where id between @one and @hundred;
注意，它们也有一些资深的属性和限制：

① 使用自定义变量的查询，无法使用查询缓存。

② 不能在使用常量或者标识符的地方使用自定义变量，例如表名、列名和limit子句中

③ 用户自定义变量的声明周期是在一个连接中有效，所以不能用他们来做连接间的通信。

④ 如果使用连接池或者持久化连接，自定义变量可能让看起来毫无关系的代码发生交互。

⑤ 在5.0以前的版本，是大小写敏感的，所以要注意在不同版本中的兼容性问题。

⑥ 补鞥呢显示的声明自定义变量的类型。确定未定义变量的具体类型的时机在不同MySQL版本中也可能不一样。如果你希望变量使正数类型，那么最好在初始化的时候就赋值为0，浮点数则赋值0.0，字符串赋值为''，用户自定义变量的类型在赋值的时候回改变。MySQL的用户自定义变量是一个动态类型。

⑦ MySQL优化器在某些场景下可能会将这些变量优化掉，这可能导致代码不会正常执行。

⑧ 赋值的顺序和赋值的时间点并不时固定的，这依赖于优化器的决定。

⑨ 赋值符号 := 的优先级非常低，所以需要注意，赋值表达式应该使用明确的括号。

⑩ 使用未定义变量不会产生任何语法错误，如果没意思到这一点，很容易犯错。

如果对自定义变量感兴趣可以自己测试下下面的用法：

① 查询运行时计算总数和平均值

② 模拟group语句中的函数first()和last()

③ 对大量数据做一些数据计算

④ 计算一个达标的md5散列值

⑤ 编写一个样本处理函数，当样本中的数值超过某个边界值的时候将其变为0

⑥ 模拟读/写游标。

⑦ 在show语句中的where子句加入变量值

==============

当希望MySQL能够以更高的性能运行查询时，最好的办法就是弄清楚MySQL是如何优化和执行查询的。一旦理解这一点，很多查询优化工作实际上就是遵循一些原则让优化器能够按照预想的合理的方式运行。

MySQL执行查询过程：



① 客户端发送一条查询给服务器。

② 服务器先检查查询缓存，如果命中缓存，则立即返回结果。否则进入下一阶段。

③ 服务器端进行sql解析、预处理，在由优化器生成对应的执行计划。

④ MySQL根据优化器生成的执行计划，调用存储引擎的API来执行查询。

⑤ 将结果返回给客户端和查询缓存

上面的每一步都比相像的复杂，我们在后续继续讨论。我们会看到在每一个阶段查询处于何种状态。查询优化器是其中特别复杂也是特别难理解的部分。还有很多例外情况，例如，当查询使用绑定变量后，执行路径会有所不同。

一 MySQL客户端/服务器通信协议
一般来说，不需要去理解MySQL通信协议的内部实现细节，只需要大致理解通信协议是如何工作的。MySQL客户端和服务器之间的通信洗衣是半双工的，这意味着在任何一个时刻，要么是由服务器想客户端发送数据，要么是由客户端想服务器发送数据，这两个动作不能同时发生。所以，我们无法也无需将一个消息切成小块来独立发送。

这种协议让MySQL通信简单快速，但是也从很多地方限制了MySQL。一个明显的限制是，这以为着无法进行流量控制。一点一端开始发送消息，另一端要接收完整个消息才能响应它。这就想来回抛球的游戏：在任何时刻，只有一个人能控制球，而且只有控制球的人才能将球抛回去。

客户端用一个单独的数据包将查询传给服务器。这也是为什么当查询的语句很长的时候，参数max_allowed_packet就特别重要了。一旦客户端发送了请求，它能做的事情就只是等待结果了。

相反的，一般服务器响应给用户的数据通常很多，由多个数据包组成。当服务器开始响应客户端请求时，客户端必须完整的接收整个返回结果，而不能简单的只取前面几条结果，然后让服务器停止发送数据。这种情况下，客户端若接收完整的结果，然后取消前面几条需要的结果，或者接收完几条结果后就断开链接，都不是好主意。这也是在必要的时候一定要在查询中加上limit限制的原因。

换一种方式解释这种行为：当客户端从服务器去数据时，看起来是一个拉取数据的过程，但实际上是MySQL在想哭独断推送数据的过程。客户端不断的接收从服务器推送的数据，客户端也没办法让服务器停止。

多数链接MySQL的库函数都可以获得全部结果集并缓存到内存里，还可以逐行获取需要的数据。默认一般是获得全部结果集并缓存到内存中。MySQL通常需要等所有的数据都已经发送给客户端才能释放这条查询所占用的资源，所以接收全部结果并缓存通常可以减少服务器的压力，让查询能够早点结束、早点释放相应资源。

当使用多数链接MySQL的库函数从MySQL获取数据时，其结果看起来都像是从MySQL服务器获取数据，实际上都是从这个库函数的缓存获取数据。多数情况下这没什么问题，但是如果需要返回一个很大的结果集的时候，这样做并不好，因为库函数会花费很多时间和内存来存储所有的结果集。如果能够尽早开始处理这些结果集，就能大大减少内存的消耗，这种情况下可以补使用缓存来记录结果而是直接处理。这样做的缺点是，对于服务器来说，需要查询完成后才能释放资源，所以在和客户端交互的整个过程中，服务器的资源都是被这个查询所占用的。

1 查询状态
对于一个MySQL链接，或者说一个线程，任何时刻都有一个状态，该状态标识了MySQL当前正在做什么。有很多种方式能查看当前的状态，最简单是使用 show full processlist命令，该命令返回结果中的Command列就标识当前的状态。在一个查询的声明周期中，状态会变化很多次。MyQL官方手册中对这些状态表名了最权威的解释：

① Sleep：线程正在等待哭护短发送新的请求

② Query：线程正在执行查询或者正在讲结果发送给客户端

③ Locked：在MySQL服务器层，该线程正在等待表锁。在存储引擎级别实现的锁，例如InnoDB的行锁，并不会提现在线程状态中。对于没有行锁的引擎中会经常出现。

④ Analyzing and statistics：线程正在收集存储引擎的统计信息，并生成查询执行计划。

⑤ Copying to tmp table[on disk]：线程正在执行查询，并且将其结果集都赋值到一个临时表中，这种状态一般要么是在group by操作，要么是文件培训操作，或union操作。如果这个状态后面还有on disk标记，那标识MySQL正在讲一个内存临时表放到磁盘上。

⑥ Sorting result：线程正在对结果集进行排序。

⑦ Sending data：这标识多种情况；线程可能在多个状态之间传送数据，或者在生成及国际，或在想客户端返回数据。

了解这些状态的基本含义非常有用，这可以让你很快的了解“当前谁在拿着球”。在一个繁忙的服务器上，可能会看到大量的不正常的状态，例如statistics正占用大量的时间。这通常标识，某个地方有异常了。

二 查询缓存
在解析一个查询语句之前，如果查询缓存使打开的，那么MySQL会优先检查这个查询是否命中查询缓存中的数据。这个检查是通过一个队大小写敏感的哈希查找实现的。查询和缓存中的查询即使只有一个字节不同，那也不会匹配缓存结果，这种情况下查询就会进入下一阶段处理。

如果当前的查询恰好命中了查询缓存，那么在返回查询结果之前MySQL会检查一次用户权限。这然然是无需解析查询SQL语句的，因为在查询缓存中已经存放了当前查询需要访问的表信息。如果权限没有问题，MySQL会跳过所有其他截断，直接从缓存中拿到结果并返回给客户端。这种情况下，查询不会被解析，不用生成执行计划，不会被执行。

三 查询优化处理
查询的声明周期的下一步是将一个SQL转换成一个执行计划，MySQL在依照这个执行计划和存储引擎进行交互。这包括多个子阶段：解析SQL、预处理、优化SQL执行计划。这个过程中任何错误都可能终止查询。在实际执行中，这几部分可能一起执行也可能单独执行。我们目的是帮助大家理解MySQL如何执行查询，以便写出更优秀的查询。

1 语法解析器和预处理
首先，MySQL通过关键字将SQL语句进行解析，并生成一颗对应的解析树。

MySQL解析器将使用MySQL语法规则验证和解析查询。例如，它将验证是否使用错误的关键字，或者使用关键字的顺序是否正确等，喊会验证引号是否能前后匹配。

预处理器则根据一些MySQL规则进一步检查解析树是否合法，例如，这里讲检查数据表和数据列是否存在，还会解析名字和别名，看看他们是否有歧义。

下一步预处理器会验证权限。这通常很快，除非服务器上有非常多的权限配置。

2 查询优化器
现在语法树被认为是合法的了，并且由优化器将其转化成执行计划。一条查询可以有很多种执行方式，最后都返回相同的结果。优化器的作用就是找到这其中最好的执行计划。

MySQL使用基于成本的优化器，它将尝试预测一个查询使用某种执行计划时的成本，并选择其中成本最小的一个。最初，成本的最小单位是随机读取一个4K数据也的成本，后来成本计算公式变得更加复杂，并且引入了一些因子来估算某些操作的代价，例如执行一次where条件比较的成本。可以通过查询当前会话的last_query_cost的值来得知mySQL计算当前查询的成本

select count(*) from tast_user;
show status like 'last_query_cost';


这个结果标识MySQL的优化器认为需要做10个数据页的随机查找才能完成上面的查询。这是根据一系列的统计信息计算得来的：每个表或者索引的页面个数、索引的基数、索引和数据行的长度、索引分布情况等。优化器在评估成本的时候并不考虑任何层面的缓存，它假设读取任何数据都需要一次磁盘I/O。

有很多种原因会导致MySQL优化器选择错误的执行计划：

① 统计信息不准确。

MySQL依赖存储引擎提供的统计信息来评估成本，但是有的存储引擎提供的信息是准确的，有的可能会有很大偏差。例如InnoDB因为其MVCC的架构，并不能维护一个数据表的行数的精确统计信息。

② 执行计划中的成本估算不等同于实际执行的成本。

所以即使统计信息精确，优化器给出的执行计划也可能不是最优的。例如有时候猴哥执行计划虽然需要读取更多的页面，但是它的成本却更小。因为如果这些页面都是顺序读或这些页面都已经在内存中的话，那么它的访问成本将很小。MySQL层面并不知道那些页面在内存中、那些在磁盘上，所以查询实际执行过程中到底需要多少次物理I/O是未知的。

③ MySQL的最优可能和你想的最优不一样。

你可能希望执行时间尽可能的短，但是MySQL只是基于其成本模型选择最优的执行计划，而有些时候这并不是最快的执行方式。所以，这里我们看到根据执行成本来选择执行计划并不是完美的模型。

④ MySQL从不考虑其他并发执行的查询，这可能会影响到当前查询的速度。

⑤ MySQL也并不是任何时候都是基于成本的优化。

有时也会基于一些固定的规则，例如，如果存在全文检索的match()字句，则在存在全文索引的时候就使用全文索引。即使有时候使用别的索引和where条件可以原比这种方式要快，MySQL也仍然会使用对应的全文索引。

⑥ MySSQL不会考虑不收其控制的操作的成本，例如执行存储过程或者用户自定义函数的成本。

⑦ 优化器有时候无法去估算所有可能的执行计划，所以它可能错过实际上最优的执行计划。

 

MySQL的查询优化器是一个非常复杂的不见，它使用了很多优化策略来生成一个最优的执行计划。优化策略可以简单的分为两种，一种是静态优化，一种是动态优化。静态优化可以直接对解析树进行分析，并完成优化。例如，优化器可以通过一些简单的代数变换将where条件装换成另一种等价形式。静态优化不依赖于特别的数值，如where条件中带入的一些常熟等。静态优化在第一次完成后就一直有效，即使使用不同的参数重复执行查询也不会发生变化。可以认为这是一种编译时优化。

相反，的动态优化则和查询的上下文有关，也可能和很多其他因素有关，例如where条件中的取值、索引中条目对应的数据行数等。这需要在每次查询的时候都重新评估，可以认为这是运行时优化。

在执行语句和存储过程的时候，动态优化和静态优化的区别非常重要。MySQL对查询的静态优化只需要做一次，但对查询的动态优化则在每次执行时都需要重新评估。有时甚至在查询的执行过程中也会重新优化。

下面是一些MySQL能够处理的优化类型：

① 重新定义关联表的顺序。

数据表的关联并不总是按照在查询中指定的顺序执行。决定关联的顺序是优化器很重要的一部分功能。

② 将外连接转换成内连接。

并不是所有的outer join 语句都必须以外连接的方式执行。例如where条件、库表结构都可能会让外连接等价一个内连接。MySQL能够识别这点并重写查询，让其可以调整关联顺序。

③ 使用等价变换规则。

MySQL可以使用一些等价变换来简化并规范表达式。它可以合并和减少一些比较，还可以移除一些恒成立和一些恒不成立的判断例如（5=5 and a>5）将被改写成 a>5。

④ 优化count()  min()和max().

索引和列是否可以为空通常可以帮助MySQL优化这类表达式。例如，要找到某一列的最小值，值需要查询对应的B-Tree索引最左端的记录，MySQL可以直接获取索引的第一行记录。在优化器生成执行计划的时候就可以利用这一点，在B-Tree索引中，优化器会将这个表达式作为一个常数对待。类似的，如果要找到一个最大值，也只需读取B-Tree索引的最后一条记录。如果MySQL使用了这种类型的优化，那么在EXPLAIN中就可以看到select tables optimized away。从字面意思可以看出，它标识优化器已经从执行计划中移除了该表，并以一个常数取代。

类似的，没有任何where条件的count(*)查询通常也可以使用存储引擎提供的一些优化。

⑤ 预估并转化为常数表达式。

当MySQL检测到一个表达式可以转化为常数的时候，就会一直把该表达式作为常数进行优化处理。例如，一个用户自定义变量在查询中没有发生变化时就可以转换为一个常数。数学表达式则是另一种典型的例子。

让人惊讶的是，在优化截断，有时候甚至一个查询也能够转化为一个常数。一个例子是在索引列上执行min()函数。甚至是主键或者唯一键查找语句也可以转换为常数表达式。如果where子句中使用了这类索引的常数条件，MySQL可以在查询开始阶段就先查找到这些值，这样优化器就能够知道并转换为常数表达式。

另一种会看到常数条件的情况是通过等式将常熟之从一个表传到另一个表，这可以通过where/using或on语句来限制某列取值为常数。

⑥ 覆盖索引扫描。

当索引中的列包含所有查询中需要使用的列的时候，MySQL就可以使用索引返回需要的数据，而无需查询对应的数据行。

⑦ 子查询优化。

MySQL在某些情况下可以将子查询转换一种效率更高的形式，从而减少多个查询多次对数据进行访问。

⑧ 提前终止查询。

在发现已经满足查询需求的时候，MySQL总是能够like终止查询。比如说使用了limit子句的时候。初次之外，MySQL还有几种情况也会提前终止查询，例如发现了一个不成立的条件，这时MySQL可以立刻返回一个空结果。例如：

explain select * from test_user where id = -1;
这个例子看到查询在优化截断就已经终止。除此之外，MySQL在执行过程中，如果发现某些特殊的条件，则会提前终止查询。当存储引擎需要检索不同取值或者判断存在性的时候，MySQL都可以使用者类优化。类似这种不同值/不存在的列的优化一般可用distinct、not exist()或left join类型的查询类型的查询。

⑨ 等值传播。

如果两个列的值通过等式关联，那么MmSQL能够把其中一个列的where条件传递到另一个裂伤。

⑩ 列表in()的比较。

在很多数据库系统中，in()完全等同于多个or条件的子句，因为这两者是完全等价的。在MySQL中这点是不成立的，MySQL将in()列表中的数据线进行排序，然后通过二分查找的方式来确定列表中的值是否满足条件，这是一个O(log n)复杂度的操作，等价的转换成or 查询的复杂度为O(n)，对于in()列表中有大量取值的时候，MySQL的处理速度将会更快。

 

上面列举的不是MySQL优化器的全部，MySQL还会做大量其他的优化，但上面的这些例子已经足以上大家明白优化器的复杂性和智能性了。如果说从上面这段讨论中我们能学到什么，那就是不要自以为比优化器更聪明。

当然，虽然优化器已经很智能了，但是有时候也无法给出最优的结果。有时候你可能比优化器更了解数据，例如，由于应用逻辑使得某些条件总是成立的；还有时，优化器缺少某种功能特性，如哈希索引；在例如前面提到的，从优化器执行成本评估出来的执行计划，实际运行中可能比其他执行计划更慢。

如果能够确认优化器给出的不是最佳选择，并且清楚背后的原理，那么也可以帮助优化器做进一步优化，例如，可以在查询中添加hint提示，也可以重写查询，或者重新设计更优的库表结构，或者添加更合适的索引。

3 数据和索引的统计信息
MySQL架构由多个层次组成。在服务器层有查询优化器，却没有保存数据和索引的统计信息。统计信息由存储引擎实现，不同的存储引擎可能会存储不同的统计信息。例如Archive引擎，则没有存储任何信息。

因为服务器层没有任何统计信息，所以MySQL查询优化器再生成查询的执行计划时，需要向存储引擎获取响应的统计信息。存储引擎则提供给优化器对应的统计信息，包括：每个表或者索引有多少个页面、每个表的每个索引的基数是多少、数据行和索引长度、索引的分布信息等。优化器根据这些信息来选择一个最优的执行计划。在后面的小姐中我们将看到统计信息是如何影响优化器的。

4 MySQL如何执行关联查询
MySQL中关联一次所包含的意义比一般意义上理解的要更广泛。总的来说，MySQL认为任何一个查询都是一次关联；并不仅仅是一个查询需要到两个表匹配才叫关联，所以在MySQL中，每一个查询，每一个片段都可能是关联。

当前MySQL关联执行的侧率很贱但：MySQL对任何关联都执行嵌套循环关联操作，即MySQL先在一个表中循环去除单条数据，然后再嵌套循环到下一个表中虚招匹配的行，依次下去，知道找到所有表中匹配的行为止。然后根据各个表匹配的行，返回查询中需要的各个列。MySQL会尝试在最后一个关联表中找到所有匹配的行，如果最后一个关联表无法找到更多的行以后，MySQL返回到上一层此关联表，看是否能够找到更多的匹配记录，以此类推迭代执行。

按照这样的方式查找到第一个表记录，在嵌套查询下一个关联表，然后回溯到上一个表，在MySQL中是通过嵌套循环的方式实现

从本质上说，MySQL对所有的类型的查询都以同样的方式运行。例如，MySQL在from子句中遇到子查询时，先执行子查询并将其结果放到一个临时表中，然后将这个临时表当做一个普通表对待。MySQL在执行union查询时也使用类似的临时表，在遇到右外连接的时候，MySQL将其改写成等价的左外连接，但也有例外情况无法通过嵌套循环和回溯的方式完成。

5 执行计划
和很多其他关系数据库不同，MySQL并不会生成查询字节码来执行查询。MySQL生成查询的一颗指令树，然后通过存储引擎执行完成这棵指令树并返回结果。最终的执行计划包含了重构查询的全部信息。如果对某个查询执行explain extended后，在执行show warnings，就可以看到重构出的查询。

热河夺标查询都可以使用一颗树表示：多表关联的一种方式



在计算机科学中这被称为一颗平衡树。但是，这并不是MySQL执行查询的方式。正如我们前面章节介绍的，MySQL总是从一个表开始一直嵌套循环、回溯完成所有表关联。所以，是一颗左侧深度优先树。

MySQL如何实现多表关联：



6 关联查询优化器
MySQL优化器最重要的一部分就是关联查询优化，它决定了多个表关联时的顺序。通常夺标关联的时候，可以有多重不同的关联顺序来获得相同的执行结果。关联查询优化器则通过评估不同顺序时的成本来选择一个代价最小的关联顺序。所以sql中书写的关联顺序不一定就是生成执行计划时的关联顺序，这个顺序也不一定就是不变的。

重新定义关联的顺序是优化器非常重要的一部分功能。不过有时候，优化器给出的并不是最优的关联顺序。这时可以使用straight_join关键字重写查询，让优化器按照你认为最优的关联顺序执行。

关联优化器会尝试在所有的关联顺序中选一个执行成本最小的来生成执行计划书。如果可能，优化器会遍历每一个表然后逐个做嵌套循环计算每一棵可能的执行计划树的成本，最后返回一个最优的执行计划。

不过，如果有n个表的关联，那么需要检查n的阶乘种关联顺序。我们称之为所有可能的执行计划的收缩空间，搜索空间的增长速度非常快；例如如果是10个表的关联那么共有3628800种不同的关联顺序。当搜索空间非常大的时候，优化器不可能注意评估每一种关联顺序的成本，这时，优化器选择使用贪婪搜索的方式查找最优的关联顺序。实际上，当关联的表超哥optimizer_search_depth的限制的时候，就会选择贪婪搜索模式了。

在MySQL这些年的发展过程中，优化器积累了很多启发式的优化策略来加速执行计划的生成。绝大多数情况下，这都是有效的，但因为不会去计算每一种关联顺序的成本，所以偶尔也会选择一个不是最优的执行计划。

有时，每个查询的顺序并不能随意安排，这时关联优化器可以根据这些规则大大减少搜索空间，例如左连接。这是因为，后面的表的查询需要依赖于前面表的查询结果。这种依赖关系通常可以帮助优化器大大减少需要扫描的执行计划数量。

7 排序优化
无论如何排序都是一个成本很高的操作，所以从性能角度考虑，应尽可能避免排序或尽可能避免对大量数据进行排序。

之前我们已经看过如何通过索引进行排序。当不能使用索引生成排序结果的时候，MySQL需要自己进行排序，如果数据量小则在内存中进行，如果数据量大则需要使用磁盘，不过MySQL将这个过程同一称为文件排序，即使完全是内存排序不需要任何磁盘文件时也是如此。

如果需要排序的数据量小于排序缓冲区，MySQL使用内存进行快速排序操作。如果内存不够排序，那么MySQL会先将数据分块，对每个独立的块是用快速排序进行排序，并将各个块的排序结果存放在磁盘上，然后将各个排好序的块进行合并，返回结果

MySQL有如下两种排序算法

① 两次传输排序（旧版本）

读取行指针和需要排序的字段，对其进行排序，然后在根据排序结果读取所需要的数据行。

这需要进行两次数据传输，及需要从数据表中读取两次数据，第二次读取数据的时候，因为是读取排序列进行排序后的所有记录，这会产生大量的随机I/O，所以两次数据传输的成本非常高。当使用的是MyISAM表的时候，成本可能会更高，因为MyISAM使用系统调用进行数据的读取，MyISAM非常依赖操作系统对数据的缓存。不过这样做的优点是，在排序的时候存储尽可能少的数据，这就让排序缓冲区中可能容乃尽可能多的行数进行排序。

② 单词传输排序（新版本）

先读取查询所需要的所有列，然后在根据给定列进行排序，最后直接返回排序结果。

这个算法只在4.1版本以后引入。因为不在需要从数据表中读取两次数据，对于I/O密集型应用，这样做的效率高了很多。另外，相比两次传输排序，这个算法只需要一次顺序I/O读取所有的数据，而无需任何的随机I/O。缺点是如果需要返回的列非常多、非常大，会占用大量的空间，而这些列队排序操作本身来说是没有任何作用的。因为单条排序记录很大，所以可能会有更多的排序块需要合并。

很难说那个排序效率更高，两种算法都有各自最好的最糟的场景。当查询需要所有列的总长度不超过参数max_length_for_sort_data时，MySQL使用单词传输排序，可以通过调整这个参数来影响MySSQL排序算法的选择。

 

MySQL在进行文件排序的时候需要使用的临时存储空间可能会比相像的大的多。因为在MySQL排序时，对每一个排序记录都会分配一个足够长的定长空间来存放。这个定长空间必须足够长才容纳其中最长的字符串，例如，如果是varchar列则需要分配其完整长度；如果使用UTF-8字符集，那么MySQL将会为每个字符预留三个字节。我们曾经在一个库表结构设计不合理的案例中看到，排序消耗的临时空间比磁盘上原表要大很多倍。

在关联查询的时候如果需要排序，MySQL会分两种情况来处理这样的文件排序。如果order by子句中的所有列都来自关联的第一个表，那么MySQL在关联处理第一个表,那么MySQL在关联处理第一个表的时候就进行文件排序。如果是这样，那么在MySQL的explain结果中可以看到Extra字段会有Using filesort。除此之外的所有情况，MySQL都会先将关联的结果存放到一个临时表中，然后在所有的关联都结束后，在进行文件排序。这种情况下，在MySQL的explain结果的Extra字段都可以看到Using temporary；Using filesort。如果查询中有limit的话，limit也会在排序之后应用，所以即使需要返回较少的数据，临时表和需要排序的数据量任然会非常大。

MySQL5.6在这里做了很多重要的改进。当只需要返回部分排序结果的时候，例如使用了limit子句，MySQL不在对所有结果进行排序，而是根据实际情况，选择抛弃不满足条件的结果，然后在进行排序。

四 查询执行引擎
在解析和优化截断，MySQL将生成查询对应的执行计划，MySQL的查询执行引擎则根据这个执行计划来完成整个查询。这里执行计划是一个数据结构，而不是和很多其他的关系型数据库那样会生成对应的字节码。

相对于查询优化截断，查询执行截断不是那么复杂：MySQL只是简单的根据执行计划给出的指令逐步执行。在根据执行计划逐步执行的过程中，有大量的操作需要通过调用存储引擎实现的接口来完成，这些接口也就是我们成为handler API的接口。查询中的每一个表由一个handler的实例标识。前面我们有意忽略了这点，实际上，MySQL在优化截断就为每个表创建了一个handler实例，优化器根据这些实际的接口可以获取表的相关信息，包括表的所有列名、索引统计信息等。

存储引擎接口有着非常丰富的功能，但是底层接口却只有几十个，这些接口像搭积木一样能够完成查询的大部分操作。例如，有一个查询某个索引的第一行的接口，在有一个查询某个索引条目的下一个条目的功能，就可以完成全索引扫描工作了。这种简单的接口模式，让MySQL的存储引擎插件式架构成为可能，但也给优化器带来了一定的限制。

执行查询，MySQL只需要重复执行计划中的各个操作，直到完成所有的数据查询。

注意：并不是所有的操作都有handler完成。例如，当MySQL需要进行表锁的时候，handler可能会实现自己的级别的、更细粒度的锁，如InnoDB就实现了自己的行基本锁，但这并不能代替服务层的表锁。如果是所有存储引擎共有特性则由服务器层实现。

五 返回结果给客户端
查询执行的最后一个阶段但是将结果返回给客户端。即使查询不需要返回结果集给客户端，MySQL仍然会返回这个查询的一些信息，如该查询影响到的行数。

如果查询可以被缓存，那么MySQL在这个阶段也会将结果存放到查询缓存中。

MySql将结果集返回客户端是一个增量、逐步返回的过程。例如，前面的关联操作，一旦服务器处理完最后一个关联表，开始生成第一条结果时，MySQL就可以开始像客户端逐步返回结果集了。

这样处理有两个好处：服务器端无需存储太多的结果集，也就不会因为结果集过多而消耗更多内存。另外，这样处理也让MySQL客户端第一时间获得返回的结果。

结果集中每一行都会以一个满足MySQL客户端/服务器通信协议的封包发送，在通过TCP协议进行传输，在TCP传输的过程中，可能对MySQL的封包进行缓存然后批量传输。

========

一 为什么查询速度会慢
在尝试编写快速的查询之前，需要清除一点，真正重要是响应时间。如果把查询看作是一个任务，那么它由一系列子任务组成，每个子任务都会消耗一定的时间。如果要优化查询，实际上要优化其子任务，要么消除其中一些子任务，要么减少子任务的执行次数，要么让子任务运行更快。

MySQL在执行查询的时候有哪些子任务，哪些子任务运行的速度很慢？这很难给出一个完整的列表，通常来说，查询的生命周期大致可以按照顺序来看：从客户端，到服务器，然后在服务器上进行解析，生成执行计划，执行，返回给结果给客户端。其中执行可以认为是整个生命周期中最重要的截断，这其中包括了大量未了检索数据到存储引擎的调用以及调用后的数据处理，包括排序、分组等。

在完成这些任务的时候，查询需要在不同的地方话费时间，包括网路，CPU计算，生成统计信息和执行计划、锁等待等操作，尤其是向底层存储引擎检索数据的调用操作，这些调用需要在内存操作，CPU操作和内存不足时导致的I/O操作上消耗时间。根据存储引擎不同，可能还会产生大量的上下文切换以及系统调用。

在每一个消耗大量时间的查询案例中，我们都能看到一些不必要的额外操作、某些操作被额外的重复了很多次、某些操作执行的太慢等。优化查询的目的就是减少和消除这些操作所花费的时间。

对于一个查询的全部生命周期，上面列的并不完整。这里只是想说明链接查询的生命周期、清楚查询的时间消耗情况对于优化查询有很大的意义。有了这些概念，我们在来看如何优化查询。

二 慢查询基础：优化数据访问
查询性能地下最基本的原因是访问的数据太多。某些查询可能不可避免的需要筛选大量数据，但这并不常见。大部分性能地下的查询都可以通过减少访问的数据量的方式进行优化。对于低效的查询，我们发现通过以下两个步骤来分析更有效：

① 确认应用程序是否在检索大量超过需要的数据。这意味着访问了太多的行，有时候也可能是过多的列。

② 确认MySQL服务器是否在分析大量超过需要的数据行。

1 是否向数据库请求了不需要的数据
有些查询会请求超过实际需要的数据，然后这些多余的数据会被应用程序丢弃。这会给MySQL服务器带来额外的负担，并增加网络开销，另外也会消耗应用服务器的CPU和内存资源。

① 查询不需要的记录

一个常见的错误是尝尝会误以为MySQL会只返回需要的数据，实际上MySQL却是先返回全部结果集在进行计算。我们经常会看到一些了解其他数据库系统的人会设计出这类应用程序。这些开发者习惯使用者杨的技术，先使用select语句查询大量的结果，然后获取前面的N行后关闭结果集，例如取出100条只显示10条。他们认为MySQL会执行查询，并只返回他们需要的10条数据，然后停止查询。实际情况是MySQL会查询出全部的结果集，客户端的应用程序会结构全部的结果集数据，然后抛弃其中大部分数据。最简单有效的解决方法就是在这样的查询后面加上limit。

② ：多表关联时返回全部列

由于返回了大量的无用数据会倒是浪费大量资源所以在查询时，最好只取出所需要的就好。

③ ：总是取出全部列

每次看到类似select * 或者在MyBatis中使用sql片段查出所有列时，都要确认一下是不是真的需要返回全部的列？很可能是不必要的。取出全部列，会让优化器无法完成索引覆盖扫描这类优化。还会为服务器带来额外的I/O、内存和CPU的消耗。

当然，查询返回所有列也不总是坏事，这种浪费数据库资源的方式可以简化开发，因为能提高相同代码片段的复用性，如果清楚这样做的性能影响，那么这种做法也是值得考虑的。如果应用程序使用了某种缓存机制，或有其他考虑，获取超过所需列也可能有其他好处，但不要忘记这样做的代价是什么。获取并缓存所有的列的查询，相比多个独立的只获取部分列的查询可能就更有好处。

④ ：重复查询相同的数据

如果你不太小心，很容易出现这样的错误；不断的重复执行相同的查询，然后每次都返回完全相同的数据。例如，在用户评论的地方需要查询用户桐乡的URL，那么用户多次评论的时候，可能就会反复查询这个数据。比较好的方案是使用缓存。

2 MySQL是否在扫描额外的记录
在确定查询只返回需要的数据后，接下来应该看看查询为了返回结果是否扫描了过多的数据。对于MySQL，最贱的衡量查询开销的有三个指标： 响应时间、扫描行数、返回行数。

没有那个指标能够完美的衡量查询的开销，但它们大致反应了MySQL在内部执行查询时需要访问多少数据，并可以大概推算出查询运行的时间。这三个指标都会记录到MySQL的慢日志中，所以检查慢日志记录是找出扫描函数过多的查询的好办法。

响应时间
要记住，响应时间只是一个表面上的值。这样说可能看起来和前面关于响应时间的说法并不矛盾，响应时间仍然是最重要的指标

响应时间是两个部分之和：服务时间和排队等待时间。服务时间是指数据库处理这个查询真正花费了多长时间。排队等待时间是指服务器因为等待某些资源而没有真正执行查询的时间；可能是等I/O操作完成，也可能是等待行锁等。遗憾的是，我们无法把响应时间细分到这部分，除非有什么办法能够逐个测量上面这些小号，不过很难做到。一般常见和重要的等待是I/O和锁等待，但实际情况会更加复杂。

所以在不同类型的应用压力下，响应时间并没有什么一直的规律或公示。注入存储引擎的锁、高并发资源竞争、硬件原因的因素都会影响响应时间。所以，响应时间即可能是一个问题的结果也可能是一个问题的原因，不同案例情况不同。

当你看到一个查询的响应时间的时候，首先需要问问自己，这个响应时间是否是一个合理的值。实际上可以使用快速上限估计法来估算查询的响应时间，这是由TapioLahdenmaki和Mike Leach编写的Relational Database Index Design and the Optimizers一书中提到的技术，概括的说，了解这个查询需要哪些索引以及它的执行计划是什么，然后计算大概需要多少个顺序和随机I/O，再用其乘以在具体硬件条件下一次I/O的消耗时间。最后把这些消耗加起来，就可以获得一个大概参考值来判断是不是一个合理的值。

扫描的行数和返回的行数
分析查询时，查看该查询扫描的行数是非常有帮助的。这在一定程度上能够说明该查询找到需要的数据的效率高不高。

对于找出那些糟糕的查询，这个指标可能还不够完美，因为并不是所有的行的访问代价都是相同的。较短的行的访问速度更快，内存中的行业比磁盘中的行的访问速度快很多。

理想情况下扫描的行数和返回的行数应该是相同的。但实际情况中这种理想情况并不多。例如一个关联查询，服务器必须要扫描多行才能生成结果集中的一行。扫描的行数对返回的行数的比例通常很小，一般在10% ~ 100%之间，不过有时候这个值也可能非常大。

扫描的行数和访问类型
在评估查询开销的时候，需要考虑一下从表中找到某一行数据的成本。MySQL有好几种方式可以朝赵并返回一行结果。有些访问方式可能需要扫描很多行才能返回一行结果，也有些访问方式可能无需扫描就能返回结果。

在EXPLAIN语句中type列反应了访问类型。访问类型有很多种，从全表扫描到索引扫描、范围扫描、唯一索引查询、常熟引用等。这里列的这些速度从慢到快，扫描的行数从大到小。不需要记住这些访问类型，但需要明白扫描表、扫描索引、范围访问和单值访问的概念。

如果查询没有办法找到合适的访问类型，那么解决的最好办法通常就是增加一个合适的索引，素银让MySQL以最搞笑、扫描行数最少的方式找到需要的记录。

一般MySQL能够使用一下三种方式应用where条件，从好到坏依次为：

① 在索引中使用where添加来过滤不匹配的记录。这是在存储引擎层完成的

② 使用索引覆盖扫描来返回记录，直接从索引中过滤不需要的记录并返回命中的结果。这是在MySQL服务层完成的，但无需在回表查询记录。

③ 从数据表中返回数据，然后过滤不返租条件的记录。这在MySQL服务器层完成，MySQL需要先从数据表独处记录然后过滤。

好的索引可以让查询使用合适的访问类型，尽可能的只扫描需要的数据行。但也不能说增加索引就能让扫描的行数等于返回的行数。

不幸的是，MySQL不会告诉我们生成结果实际上需要扫描多少行数据，而只会告诉我们生成结果时一共扫描了多少行数据。扫描的行数中的大部分都很可能是被where条件过滤掉的，对最终的结果集并没有贡献。理解一个查询需要扫描多少行和实际需要使用的行数需要先去理解这个查询背后的逻辑和思想。

如果发现查询需要扫描大量的数据单只返回少数的行，那么可以使用下面的技巧去优化它：

① 使用索引覆盖扫描，把所有需要用的列都放到索引中，这样存储引擎无需回表获取对应行就可以返回结果了。

② 改变库表结构。例如使用单独的汇总表。

③ 重写这个复杂的查询，让MySQL优化器能够以更优化的方式执行这个查询。

三 重构查询的方式
在优化有问题的查询时，目标应该是找到一个更优的方法获得市级需要的结果；而不一定总是需要从MySQL获取一模一样的结果集。有时候，可以将查询转换一种写法让其返回一样的结果，但是性能更好。但也可以通过修改应用代码，用另一种方式完成查询，最终达到一样的目的。

1 一个复杂查询还是多个简单查询
设计查询的时候一个需要考虑的重要问题是，是否需要将一个复杂的查询分成多个简单的查询。在传统实现中，总是强调需要数据库层完成尽可能多的工作，这样做的逻辑在于以前总是人文网络通信、查询解析和 优化是一件代价很高的事情。

但是这样的想法对于MySQL并不使用，MySQL从设计上让链接和断开链接都很轻量级，在返回一个小的查询结果方面很搞笑。现代的网络速度比以前要快很多，无论是带宽还是延迟。在某些版本的MySQL上，即使在一个通用服务器上，也能够运行每秒超过10万的查询，即使是一个千兆玩咖也能够轻松满足每秒超过2000次的查询。所以运行多个小查询现在已经不是大问题了。

MySQL内部每秒能够扫描内存中上百万行数据，相比之下，MySQL响应数据给客户端就慢得多了。在其他条件都相同的时候，使用尽可能少的查询当然是更好的。但是有时候，将一个大查询分解为多个小查询是很有必要的。别害怕这样做，好好衡量一下这样做是不是会减少工作量。

不过，在应用设计的时候，如果一个查询能够胜任时还写成多个独立查询时不明智的。

例如，我们看到有些应用对一个数据表做10此独立的查询来返回10行数据，每个查询返回一条结果，查询10次~~

for(int i = 0;i < userIdList.size();i++){
    User user = userMapper.findUserById(userIdList.get(i));
}
这是一个新手经常使用的方法，会占用更多的数据库连接，并且效率很低。

2 切分查询
有时候对于一个大查询我们需要分而治之，将大查询切分成效查询，每个查询功能完全一样，只完成一小部分，每次只返回一小部分查询结果。

删除旧的数据就是一个很好的例子。定期的清理大量数据时，如果用一个大的语句一次性完成的话，则可能需要一次锁住很多数据、占满整个事物日志、好近系统资源、阻塞很多小的但重要的查询。将一个大的delete语句切分成多个较小的查询可以尽可能小的影响MySQL性能，同时还可以减少MySQL赋值的延迟。例如，我们需要每个月运行一次下面的查询

delete from messages where created < date_sub(now(),interval 3 month);
那么可以用类似下面的办法来完成同样的工作；

rows_affected = 0
do{
    rows_affected = do_query(
        "delete form messages where created < dete_sub(now(),interval 3 month limit 10000)"
    )
}while rows_affected > 0;
一次删除一万航数据一般来说是一个比较高效而且对服务器影响也最小的做法，如果是服务型引擎，很多时候小事物能够更高效。同时，需要注意的是，如果每次删除数据后，都暂停一会在做下一次删除，这样也可以将服务器上原本一次性的压力分散到一个很长的时间段中，就可以大大降低对服务器的影响，还可以大大减少删除时 锁的持有时间。

3 分解关联查询
很多高性能的应用都会对关联查询进行分解。简单的，可以对每一个表进行一次单表查询，然后将结果在应用程序中进行关联。例如下面这个查询：

select * from tag
join tag_post on tag_post.tag_id = tag.id
join post on tag_post.post_id = post.id
where tag.tag = "mysql";
可以分解成下面这些查询来代替

select * from tag where tag = "mysql";(假设结果为1234)
select * from tag_post where tag_id = 1234;(假设结果为123,456,789)
select * from post where post.id in (123,456,789);
为什么这样做？乍一看这么做并没有什么好处，原本一条查询，这里却变成多条查询，返回的结果又是一模一样的。事实上，用分解关联查询的方式重构查询有一下优势：

① 让缓存的效率更高。许多应用程序可以方便的缓存单表查询对应的结果对象，对于MySQL的查询缓存来说，如果关联中的某个表发生了变化，那么久无法使用查询缓存了，而拆分后，如果某个表很少改变，那么基于该表的查询就可以重复利用查询缓存结果了。

② 将查询分解后，执行单个查询可以减少锁的竞争。

③ 在应用层做关联，可以更容易对数据库进行拆分，更容易做到高性能和可扩展。

④ 查询本身效率也可能会有所提升。使用in()替代关联查询，可以让MySQL按照ID顺序进行查询，这可能比随机的关联要更高效

⑤ 可以减少冗余记录的查询。在应用层做关联查询，一位置对于某条记录应用值需要查询一次，而在数据库中做关联查询，则可能需要重复的访问一部分数据。从这点看，这样的重构还可能会减少网络和内存的消耗。

⑥ 更进一步，这样做相当于在应用中实现了哈希关联，而不是使用MySQL的嵌套循环关联。某些场景哈希关联的效率要高很多

在很多场景下，通过重构查询将关联放到应用程序中将会更加高效

正确的创建和使用索引是实现高性能查询的基础。前面已经介绍了各种类型的索引及其对应的优缺点。现在我们一起来看看如果真正的发挥这些索引的优势。

高效的选择和使用索引有很多种方式，其中有些是针对特殊案例的优化方法，有些则是针对特定行为的优化。使用哪个索引，以及如何评估选择不同索引的性能影响的技巧则需要持续不断的学习。

一 独立的列
我们通常会看到一些查询不当的使用索引，或者使得MySQL无法使用已有的索引。如果查询中的列不是独立的，则MySQL就不会使用索引。独立的列是指索引列不能是表达式的一部分，也不能是函数的参数。

例：select id from test_table where id + 1 = 3;

凭肉眼很容易看出表达式其实等价于id = 2,但是MySQL无法自动解析这个方程式。这是完全的用户行为。我们应该养成简化where条件的习惯，始终将索引列单独放在比较符号的右侧。

下面是另一个常见错误：select id from test_table where to_days(current_date) - to_days(date_col) <= 10;

二 前缀索引和索引选择性
有时候需要索引很长的字符列，这会让索引变大且慢。一个策略是前面提到过的模拟哈希索引。但是有时候这样做还不够。

通常可以索引开始的部分字符，这样可以大大节约索引空间，从而提高索引效率。但这样也会降低索引的选择性。索引的选择性是指，不重复的索引值也称为基数（cardinality）和数据表的记录总数（#T）的比值，范围从1/#T到1之间。索引的选择性越高则查询效率越高，因为选择性高的索引可以让MySQL在查找时过滤掉更多的行。唯一索引的选择性是1，这是最好的索引选择性，性能也是最好的。

一般情况下某个列的前缀的前缀的选择性也是足够高的，足以满足查询性能。对于BLOB、TEXT或很长的VARCHAR类型的列，必须使用前缀索引，因为MySQL不允许索引这些列的完整长度。

诀窍在于要选择足够长的前缀以保证较高的选择性，同时又不能太长以便节约索引空间。前缀应该足够长，以使得前缀索引的选择性接近与索引整个列。换句话说，前缀的技术应该接近与完整的技术。

为了决定前缀的合适长度，需要找到最常见的值的列表，然后和最常见的前缀列表进行比较。我们可以使用下面sql来进行测试

select count(*) as num,left(address,3) as name from test_user group by name order by cnt limit 10;

然后慢慢的增加前缀数量直到所得的num数量差距之间不是很大，并且数量在一个可接受的范围。

计算合适的前缀长度的另一个办法就是计算完整列的选择性，并是前缀的选择性接近与完整列的选择性。

例：select count(distinct address)/count(*) from test_table;

通常来说这个例子中如果前缀的选择性能够接近0.031，基本上就可以使用了（例外情况除外）。可以在一个查询中针对不同前缀长度进行计算，这对于大表非常有用。下面给出了如何在同一个查询中计算不同前缀长度的选择性

select count(distinct left(address,3))/count(*) ,

          count(distinct left(address,4))/count(*) ,

          count(distinct left(address,5))/count(*) ,

          count(distinct left(address,6))/count(*) ,

          count(distinct left(address,7))/count(*) ,

from test_table;

当然只看平均选择性是不够的，也有例外情况，需要考虑到最坏的情况下的选择性。平均选择会让你以为一个较短的长度就足够了，但如果数据分布不均与，可能就会碰到个坑。比如你查找一个长度limit 10 的时候看到第一个和最后一个的数量相差超过1倍以上，这就是一个很明显的不均匀情况。那么这些值的选择性就比平均选择性要低的多。

如何创建前缀索引：

alter table test_table add key(address(7));

前缀索引是一种能使索引更小、更宽的有效办法，但也有其缺点：

MySQL无法使用前缀索引做order by 和 group by，也无法使用前缀索引做覆盖扫描。

常见的场景就是针对一个很长的16进制的唯一ID使用前缀索引。例如使用基于MySQL的应用在存储网站的session时，需要在一个很长的16进制字符串上创建索引。此时如果采用长度为8的前缀索引通常可以显著的提升性能，并且这种发发对上层应用完全透明。

有时候后缀索引（suffix index）也有用途，例如查询某个域名的所有电子邮件地址。MySQL原生并不支持反向索引，但是可以把字符串反转后存储，并给予此简历前缀索引。可以通过触发器来维护这种索引。可以参考前面文章中的创建自定义哈希索引部分的内容。

三 多列索引
很多人对多列索引的理解都不够。一个常见的错误就是，为每个列单独常见索引，或者没有按照逻辑顺序创建索引。

1 为每个列创建独立的索引
可以使用show create table查询

如果你发现一个表中含有很多索引，那么这种索引策略，一般是由于人们听到一些“专家”诸如 把where条件里面的列都建立索引，这样模糊的建议导致的。实际上这个建议是非常错误的。这样一来最好的情况下也只能是一星索引，其性能比起真正最优的索引可能差几个数量级。有时如果无法设计一个三星索引，那么不如忽略掉where子句，精力优化索引列的顺序，或者创建一个全覆盖索引。

在多个列上建立独立的单列索引大部分情况下并不能提升MySQL的查询性能。MySQL5.0以上版本引入了一种叫索引合并的策略（index merge），一定程度上可以使用表上的多个单列索引来定位指定的行。更早的版本中只能使用其中某一个单列索引，然而这种情况下没有哪一个独立的单列索引是非常有效的。

在MySQL5.0以上版本中，查询能够同时使用两个单列索引进行扫描，并将结果进行合并。这种算法有三个变种or条件的联合 and条件的相交，组合前两种情况的联合及相交。

MySQL会使用这类技术优化复杂查询，所以在某些语句的Extra列中还可以看到嵌套操作。

索引合并策略有时候是一种优化的结果，但实际上更多时候说明了表上的索引建的很糟糕：

① 当出现服务器对多个索引做相交操作时（通常有多个AND条件），通常意味着需要一个包含所有相关列的多列索引，而不是多个独立的单列索引。

② 当服务器需要对多个索引做联合操作时（通常有多个OR条件），通常需要耗费大量的CPU和内存资源在算法的缓存、排序和合并操作上。特别是当其追踪有些索引的选择性不高，需要合并扫描返回的大量数据的时候。

③ 更重要的是，优化器不会吧这些计算到查询成本中，优化器只关心随机页面读取。这会使得查询的成本被低估，导致该执行计划还不如直接全表扫描。这样做不但会消耗更多的CPU和内存资源，还可能会影响查询的并发性，但如果是单独运行这样的查询则往往会忽略对并发性的影响。通常来说，还不如在MySQL4.1或更早的版本一样，将查询改为UNION的方式。

如果在EXPLAIN中看到有索引合并，应该好好检查一下查询和表的结构，看是不是已经是最优的。也可以通过参数optimizer_switch来关闭索引合并功能。也可以使用IGNORE INDEX提示让优化器忽略掉某些索引。

四 选择合适的索引列顺序
我们遇到的最容易引起困惑的问题就是多列索引的顺序。正确的顺序依赖与使用该索引的查询，并且同时需要考虑如何更好的满足排序和分组的需要（主要针对B-Tree索引讨论，哈希或其他类型索引并不会像B-Tree一样按顺序存储）。

在一个多列B-Tree索引中，索引列的顺序意味着索引首先按照最左列进行排序，其次是第二列，等待。所以，索引可以按照升序或降序进行扫描，以满足精确符合列顺序的order by、group bu和distinct等子句的查询需求。

所以多列索引的顺序是很重要的。在Lahdenmaki和Leach的三星索引系统中，列顺序也决定了一个索引是否能够不称为一个三星索引。

对于如何选择索引的列顺序有一个经验法则：将选择性最高的列放到索引最前面。但这个法则没有避免随机IO和排序那么重要，考虑问题需要更全面，主要还是需要根据业务场景来考虑。

当不需要考虑排序和分组时，将选择性最高的列放在前面通常是很好的。这时候索引的作用只是用于优化where条件的查找。在这种情况下，河阳的设计的索引确实能够最快的过滤出需要的行，对于在where子句中只使用了索引部分前缀列的查找来说选择性也更高。然而，性能不只是依赖于所有索引列的选择性，也和查询条件的具体值有关，也就是和值的分布有关。这和前面介绍的选择前缀的长度需要考虑的地方一样。可能需要根据哪些运行频率最高的查询来调整索引列的顺序，让这种情况下索引的选择性最高。

当使用前缀索引的时候，在某些条件值的技术比正常值高的时候，问题就来了。例如，在某些应用程序中，对于没有登陆的用户，都将其用户名记录为guset，在记录用户session表和其他记录用户活动的表中guest就成了一个特殊用户id。一旦查询设计到这个用户，那么对于正常用户的查询就大有不同了，因为通常有很多会话都是没有登陆的。系统账号也会导致类似的问题。一个应用通常都有一个特殊的管理员账号，和普通账号不同，它并不是一个具体的用户，系统中所有的其他用户都是这个用户的好友，所以系统往往通过它想网站的所有与用户发送状态通知和其他消息。这个账号的巨大的好友列表很容易导致网站出现服务器性能问题。

这是一个非常典型的问题。任何的异常用户，不仅仅是哪些用于管理应用的设计糟糕的账号会有相同的问题；哪些拥有大量好友图片、状态、收藏的用农户，也会出现这样的系统账号问题。这个问题会导致查询运行的非常慢。

我们会用EXPLAIN的结果看到这个查询也选择了最喝水的索引，如果不考虑列的技术，这看起来是一个非常合理的选择。但如果考虑一下这个条件查询的匹配行数，可能就会有不同的想法了。

因为当一个条件满足大部分记录的时候，那么这个条件基本上已经没用了。

尽管关于选择性和基数的经验法尔值得去研究和分析，但一定要记住别忘了where子句中的排序、分组和范围条件等其他因素，这些因素可能对哈讯的性能造成非常大的影响。

五  聚簇索引
聚簇索引并不是一种单独的索引类型，而是一种数据存储方式。具体的细节依赖于其实现方式，但InnoDB的聚簇索引实际山在同一个结构中保存了B-Tree索引和数据航。

当表有聚簇索引时，它的数据行实际山存放在索引的叶子页中。术语中的聚簇表示数据行和相邻的键值紧凑的存储在一起。因为无法同时把数据行存放在两个不同的地方，所以一个表只能有一个聚簇索引（不过，覆盖索引可以模拟多个聚簇索引的情况）。

因为是存储引擎负责实现索引，因此不是所有的存储引擎都支持聚簇索引。



上图追踪记录了聚簇索引是如何存放记录的。注意到叶子页包含了行的所有数据，但是节点页只包含了索引列。例子中索引是整数值。

一些数据库服务器允许选择哪个索引作为聚簇索引，目前MySQL内建的村吃醋引擎好像还没有支持者一点。InnoDB将通过主键聚集数据，也就是说上图中被索引的列就是主键列。

如果没有定义主键，InnoDB会选择一个唯一的非空索引代替。如果没有这样的索引，InnoDB会隐式定义一个主键来作为聚簇索引。InnoDB只聚集在同一个页面中的记录。包含了相邻键值页面可能会相距甚远。

聚集主键可能对性能有帮助，但也可能导致严重的性能问题。所以需要仔细考虑聚簇索引，尤其是将表的存储引擎改变的时候。

聚集的数据有以下优点：

① 可以把相关数据保存在一起。例如保存消息时，可以根据用户ID来聚集数据。没有聚簇索引可能每个消息读一次磁盘I/O。

② 数据访问更快。聚簇索引将索引和数据保存在同一个B-Tree中，因此从聚簇索引中获取数据通常会快很多。

③ 使用覆盖索引扫描的查询可以直接使用页节点中的主键值。

如果在设计表和查询时能宠妃利用上面的优点，那就能极大的提升性能。同时，聚簇索引也有一些缺点：

① 聚簇数据最大限度的提高了I/O密集型应用的性能，但是，如果数据全部放在内存中，那么访问顺序就不重要了，聚簇索引也没有什么用处了。

② 插入速度严重依赖与插入顺序按照主键的顺序插入是加载数据到InnoDB表中速度最快的方式。但如果不是按照主键顺序加载数据，那么在加载完成后最好使用OPTIMIZE TABLE命令重新组织一下表。

③ 更新聚簇索引列的代价很高，因为会强制InnoDB将每个被更新的行移动到新的位置上。

④ 基于聚簇索引的表在插入新行，或者主键被更新导致需要移动行时，可能会面临页分裂的问题。当行的主键值要求必须将这一行插入到某个已满的页中时，存储引擎会将该也分成两个页面来容纳该行，这就是一次页分裂操作。会导致表占用更多的磁盘。

⑤ 聚簇索引可能导致全表扫描变慢，尤其是行比较稀疏，或者由于页分裂导致数据存储不连续时。

⑥ 二级索引可能比想象的更大，因为二级索引的叶子节点包含了引用行的主键列。

⑦ 二级索引访问需要两次索引查找，而不是一次。

为什么二级索引需要两次索引查找呢？因为二级索引中保存的是行指针。二级索引椰子汁节点保存的不是指向行物理位置的指针，而是行的主键值。

这以为着通过二级索引查找行，存储引擎需要找到二级索引的叶子节点获得对应的主键值，然后根据这个值去聚簇做一年中找到对应的行。这里做了重复的工作；查找了B-Tree两次。对于InnoDB，自适应哈希索引能够减少这样的重复工作。

六 覆盖索引
通常大家都会根据查询的where条件来创建合适的索引，不过这只是索引优化的一个方面。设计优秀 的索引应考虑到整个查询，而不是单单是erhere小件部分。索引确实是一种查找数据的高效方式，但是MySQL也可以使用索引来直接获取列的数据，这样就不在需要读取数据行。如果索引的叶子节点中已经包含要查询的数据，那么还有必要再回表查询么？如果一个索引包含所有需要查询的字段值，我们就称之为覆盖索引。

覆盖索引是非常有用的工具，能够极大的提高性能：

① 索引条目通常远小于数据行大小，所以如果只需要读取索引，那MySQL就会极大的减少数据访问量。这对缓存的负载非常重要，因为这种情况下响应时间大部分花费在数据考贝上。覆盖索引对于I/O秘籍性应用也有帮助，因为索引比数据更小，更容易全部放入内存中（在MyISAM中能压缩索引）。

② 因为索引是按照列值顺序存储的（单页内是如此），所以对于I/O密集型的范围查询会比随机从磁盘读取每一行数据的I/O要少的多。对于某些存储引擎，例如MyISAM和Percona XtraDB，甚至可以通过OPTIMIZE命令使索引完全顺序排列，这让简单的范围查询能使用完全顺序的索引访问。

③ 一些村吃醋引擎如MyISAM在内存中只缓存索引，数据则依赖与操作系统来缓存，因此要访问数据需要一次系统调用。这可能会导致CPU占用问题。

④ 由于InnoDB的聚簇索引，覆盖索引对InnoDB表特别有用。InnoDB的二级索引在叶子节点中保存了行的主键值，所以如果二级主键能够覆盖查询，则可以避免对主键索引的二次查询。

在所有这些场景中，在索引中满足查询的成本一般比查询行小的多。

不是所有类型的索引都可以称为覆盖索引。覆盖索引必须要存储索引列的值，而哈希索引、空间索引和全文索引等都不村吃醋索引列的值，所以MySQL只能使用B-Tree索引做覆盖索引。另外，不同的存车处引擎实现覆盖索引的方式也不同，而且不是所有的引擎都支持覆盖索引。

索引覆盖查询还有很多坑可能会导致无法实现优化。MySQL查询优化器会在执行查询前判断是够有一个索引能进行覆盖。假设索引覆盖了where条件红的字段，但不是整个查询设计的字段。如果条件为false，MySQL5.5以前也ong是会回表获取数据行，尽管执行后这一行会被过滤掉。

例如使用了where name = "abc" address like “%abc%” \G 这样的查询，这里有两个原因导致无法使用索引：

① 没有任何索引能够覆盖这样的查询。因为查询中从表中选择了所有的列，而没有任何索引覆盖所有的列。不过理论上MySQL还有一个捷径可以利用；where条件中的列是有索引可以覆盖的，因此MySQL可以使用该索引找到对应的name并检查address是否匹配，过滤之后再读取需要的数据行。

② MySQL不能在索引中执行like操作。这是底层存储引擎API的限制，MySQL5.5以前版本中只允许爱索引红做简单的比较操作（>  <  =  !=）。MySQL能再索引中做最左前缀匹配的like比较，因为该操作可以转换为简单的比较操作，但是如果是通过通配符开头的like查询，存储就无法做比较匹配。这种情况下，MySQL服务器只能提取数据行的值而不是索引值来做比较。

不过也有办法可以解决上述两个问题，需要重写查询并建立一个3列的索引。(name,address,book_id)

select * from user join(select book_id from user where name = "abc" address like “%abc%” ) as t1 on(t1.book_id = user.book_id)\G

我们吧这种方式叫做延迟关联（deferred join），因为延迟了对列的访问。在查询的第一阶段MySQL可以使用覆盖索引，在from子句的子查询中找到匹配的book_id，然后根据这些book_id值在外层查询匹配获取需要的所有值。虽然无法使用索引覆盖整个查询，但总比完全无法利用索引覆盖的好。

这样优化效果取决于where条件匹配返回的行数。假设这个表中有100W行，那么只有当条件一的数据匹配行数远远超过条件二的匹配行数才能看到优化效果。

① 当两个匹配量都很大的时候那么大部分时间都花在读取和发送数据上了。

② 当条件一的匹配行数远超于条件二的匹配行数的时候，那么只需要读取很少的完整数据行。

③ 当条件一的匹配行数不是很多时，那么查询成本会比从表中直接提取行更高。

七 使用索引扫描来做排序
MySQL有两种凡是可以生成有序的结果；通过排序操作或按照索引顺序扫描。如果EXPLAIN出来的type列的值为index，则说明MySQL使用了索引扫描来做排序。

扫描索引本身是很快的，因为只需要从一条索引记录移动到紧接着的下一条记录。但如果索引不能覆盖查询所需的全部列，那就不得不每扫描一条索引记录都回表查询一次对应的行。这基本上都是随机I/O，因此按索引顺序读取数据的速度通常要比顺序的全表扫描慢，尤其是在I/O密集型的工作负载时。

MySQL可以使用同一个索引及马努排序，又用于查找行。因此，如果可能，设计索引时应该尽可能的同时满足这两种任务。

只有当索引的列顺序和order by子句的顺序完全一致，并且所有列的排序方向都一样时，MySQL才能够使用索引来对结果做排序。如果查询需要关联多张表，则只有当order by子句引用的字段全部为第一个表时，才能使用索引做排序。order by子句和查找型查询的限制是一样的。需要满足索引的最左前缀的要求，否则，MySQL都需要执行排序操作，而不乏利用索引排序。

当前导列为常量的时候，order by子句可以不满足索引的最左前缀要求。如果where子句或join子句中对这些列指定了常量，就可以弥补索引的不足。

八 压缩索引（前缀压缩）
MyISAM使用前缀压缩来减少索引的大小，从而让更多的索引可以放入内存中，这在某些情况下能极大的提高性能。默认只压缩子字符串，但通过参数设置也可以对整数进行压缩。

M有ISAM压缩每个索引块的方式是，先完全保存索引块中的第一个值，然后将其他值和第一个值进行比较得到想通过前缀的字节数和剩余的不同后缀部分，把这部分存储起来即可。例如，索引块中的第一个值是perform，第二个值是performance，那么第二个值的前缀压缩后存储的是类似7，ance这样的形式。MyISAM对行指针也采用类似的前缀压缩方式。

压缩块使用更少的空间，但是某些操作可能更名。因为每个值的压缩前缀都依赖前面的值，所以MyISAM查找时无法在索引块中使用二分查找而只能从头开始扫描。郑旭的扫描速度还不错，但是如果是倒序扫描就不是很好了。所有在块中查找某一行的操作平均都需要扫描半个索引块。

测试表名，对于CPU密集型应用，因为扫描需要随机查找，压缩索引使MyISAM在索引查找上要慢好几倍。压缩索引的倒序扫描更慢。压缩索引需要在CPU内存资源与磁盘之间做权衡。压缩索引可能值需要十分之一的磁盘空间，但如果是I/O密集型应用，对某些查询带来的好处会比成本多很多。

可以在create table 语句中指定pack_keys参数来控制索引压缩的方式

九 冗余和重复索引
MySQL允许在相同列上创建多个索引，无论是有意还是无意的。MySQL需要单独维护重复的索引，并且优化器在优化查询的时候也需要诸葛的进行考虑，这会影响性能。

重复索引是指在相同的列上按照相同的顺序创建相同类型的索引。我们使用时应该避免这样的重复创建。

例如主键上就有非空、不可重复、唯一这样的约束就不许要在主键上在建立唯一索引了。

冗余索引和重复索引有一些不同。如果创建了索引（a,b），在创建索引（a）就是冗余索引，因为这只是一个索引的前缀索引。因此索引（a，b）也可以当做索引（a）来使用，这种冗余只是对B-Tree索引来说的。但是如果在创建索引（b，a）则不是冗余索引，索引（b）也不是，因为b不是索引（a，b）的最左前缀列。另外，其他不同类型的索引例如哈希索引或全文索引也不会使B-Tree索引的冗余索引，而无论覆盖的索引列时什么。

冗余索引通常发生在为表添加新索引的时候。例如有人可能会增加一个新的索引（a，b）而不是扩展已有的索引（a）。还有一种情况是将一个索引扩展为（a，id），其中id是主键，对于InnoDB来说主键列已经在二级索引中了，所以这也是冗余的。

大多数情况下都不需要冗余索引，应该尽量扩展已有的索引而不是创建新索引。但也有时候处于性能方面的考虑需要冗余索引，因为扩展已有的说因会导致其变得太大，从而影响其他使用该索引的查询性能。

例如在一个现有整数索引上添加一个很长的varchar列来扩展该索引，那性能可能会急剧下降。特别是有查询吧这个索引当做覆盖索引，或MyISAM表并且有很多范围查询的时候，由于MyISAM的前缀压缩导致的。

例，有以下两个查询sql,假设state上有一个索引：

例1：select count(*) from user where state = 2;

例2：select state,city,address from user where state = 2;

对于这两个查询，如果想优化 例2的sql可以创建索引为（state,city,address），让索引能覆盖查询，这样不会影响到 例1的sql查询性能，这样原来的单列索引就是冗余的。

表中的索引越多插入速度回越慢。一般来说，增加新索引会导致insert、update、delete等操作的速度变慢，特别是当新增索引后导致到达了内存瓶颈的时候。

解决冗余索引和重复索引的方法很简单，删除这些索引就可以，但首先做的是找出这样的索引，可以通过写一些复杂的访问INFORMATION_SCHEMA表来查找，不过还有两个更简单的方法。可以使用Shlomi Noach的common_schema中的一些视图来定位，common_schema是一系列可以安装到服务器上的存储和视图（http://code.google.com/p/coommon-schema/）。这比自己编写查询要快而且简单。另外也可以使用Percona Toolkit中的pt-duplicate-key-checker，该工具通过分析表结构来找出冗余和重复的索引。对于大型服务器来说，使用外部的工具可能更合适些；如果服务器上游大量的数据或大量的表，那么查询INFORMATION_SCHEMA表可能会导致性能问题。

在决定哪些索引可以办删除的时候要非常小心。建议使用Percona工具中的pt-upgrade来仔细检查计划中的索引变更。

十 未使用的索引
除了冗余索引和重复索引，可能还会有一些服务器永远用不到的索引。这样的索引完全是累赘，建议考虑删除。有两个工具可以帮助定位为只用的索引。最简单的方法是在Percona Server或MariaDB中先打开userstates服务器变量（默认关闭），然后让服务器正常运行一段时间，在通过查询INFORMATION_SCHEMA.INDEX_STATISTICS就能查到每个索引的使用频率。

另外，还可以使用Percona Toolkit中的pt-index-usage，该工具可以读取查询日志，并对日志中的每条查询进行EXPLAIN操作，然后打印出关于索引和查询的报告。这个工具不仅可以找出那些索引是未使用的，还可以了解查询的执行计划--例如在某些情况有些类似的查询的执行方式不一样，这可以帮助你定位到那些偶尔服务质量差的查询，可以优化他们得到进一步的性能提升。该工具也可以将结果写入MySQL的表中，方便查询结果。

十一 索引和锁
索引可以让查询锁定更少的行。如果你的查询从不访问那些不需要的行，那么久会锁定更少的行，从两个方面来看着对性能都有好处。首先，虽然InnoDB的行锁效率很高，内存使用也很少，但是锁定行的时候仍然会带来额外开销；其次，锁定超过需要的行辉增加所征用并减少并发性能。

InnoDB只有在访问行的时候才会对其加锁，而索引能够减少InnoDB访问的行数，从而减少锁的数量。但这只有当InnoDB在存储引擎层能够过滤掉所有不需要的行时才会有效。如果索引无法过滤掉无用的行，那么在InnoDB检索到数据并返回给服务器层以后，MySQL服务器才能应用where子句。这时已经无法避免锁定行了；InnoDB已经锁住了这些行，到适当的时候才释放。在5.1以后版本中，InnoDB可以在服务器端过滤掉行后就释放锁，但早期版本中，InnoDB只有在事物提交后才能释放锁。

关于InnoDB、索引和锁有协议很少有人知道的细节：InnoDB在二级索引上使用共享锁，但访问主键索引需要排它锁。这消除了使用覆盖索引的可能性，并且使得select  for  update比lock  in  share  mode或非锁定查询要慢很多



索引可以让服务器快速的定位到表的指定位置。但是这并不是索引的唯一作用，到目前位置可以看到，根据创建索引的数据结构不同，索引页有一些其他的附加作用。

最常见的B-Tree索引，按照顺序存储数据，所以MySQL可以用来做order by和group by 操作。因为数据是有序的，所以B-Tree也就会将相关的列值都存储在一起。最后，因为索引中村吃醋了实际的列值，所以某些查询只使用索引就能够完成全部查询。根据此特性，索引有以下三个优点：

① 索引大大减少了服务器需要扫描的数据量。

② 索引可以帮助服务器避免排序和临时表。

③ 索引可以将随机I/O变为顺序I/O

如果想深入理解索引推荐阅读有Tapio Lahdenmaki和Mike Leach编写的Relational Database Index Design AND THE oPTIMIZERS(Wiley出版社)这本书，书中详细介绍了如何计算索引的成本和作用、如何评估查询速度、如何分析索引维护的代价等

注意：索引不一定是最好的解决方案

总的来说，真自由当索引帮助村吃醋引擎快速查找到记录带来的好处大于其带来的额外工作时，索引才是有效的。对于非常小的表，大部分情况下简单的全表扫描效率更高。对于中大型的表，索引才是有效的。但对于特大类型的表，简历和使用索引的代价将随之增长。这种情况下，则需要一种技术可以直接群分出查询需要的一组数据，而不是一条记录一条记录的匹配。这就是分区。

如果表的数量特别多，可以建立一个元数据信息表，用来查询需要用到的某些特性。例如执行哪些需要聚合多个应用分布在多个表的数据查询，则需要记录那个用户的信息存储在哪个表中的元数据，这样查询时就可以直接忽略哪些不报汗指定用户信息的表。这对于大型系统，是一个常用的技巧。事实上Infobright就是使用类似的实现。对于TB级别的数据，定位单条记录的意义不大，所以京城会使用块级别元数据技术来替代索引。

例：

之前在一家小公司，由于项目是从外包做得，所以架构不是很好，一条常用的数据经常需要查询好几张表。后来给我提了一个需求要按天做一个产品的统计信息并用Echarts生成图表，这个产品分3~5个级别大概1000多个种类，几十万的数据量，当时的开始时间到结束时间的跨度是2年左右，要统计每个种类的数量并展示每个大类别的所占比例及每个种类的TOP5，这一系列查询大概涉及到5个表。所以我并没有使用建立索引的方式来做即时查询而是建立了一张新的汇总表，定时计算每个种类的数量信息，在拿这些数据进行简单的算数运算，每次页面刷新大概3~5秒左右，后来我又使用redis做了一次结果的缓存，这时候每次页面刷新耗时1~2秒。

这种处理是我当时能想到的最好的处理办法，也能满足一些后续可能出现的其他类似的需求。如果大家有更好的解决方案可以给我留言，共同进步。（产品表、产品类别表、产品详情表（名称在这里所以必须查）、出库表、入库表）。

MySQL优化二：如何创建高性能索引之索引基础
置顶 2019年01月10日 19:43:08 yongqi_wang 阅读数：148
索引是存储引擎用于快速找到记录的一种数据结构。这是索引的基本功能。

索引对于良好的性能非常关键。尤其是当表中的数据量越来越大时，索引对性能的影响越发重要。在数据量较小且负载较低时，不恰当的索引对性能的影响可能还不明显，但当数据量主键增大时，性能则会急剧下降。

索引优化应该是对查询性能优化最有效的手段了。索引能够轻易将查询性能提高几个数量级。最优的索引有时比一个好的索引要高两个数量级。创建一个真正最优的索引经常需要重写查询。

要理解MySQL中索引是如何工作的，最简单的方法就是看一本书的目录；如果想在一本书中找到某个特定主体，一般会看书的目录找到对应的页面。

在MySQL中，存储引擎用类似的方法使用索引，其先在索引中找到对应值，然后根据匹配的索引记录找到对应的数据行。

索引可以包含一个或多个列的值。如果索引包含多个列，那么列的顺序也很重要，因为MySQL只能高效的使用索引的最左前缀列。创建一个包含两个列的索引和创建两个包含一个列的索引不是完全一样的。

注意：使用ORM一样需要理解索引。

ORM工具能够生产负荷逻辑的、合法的查询，除非只是生成非常基本的查询，否则它很难生成适合索引的查询。

索引的类型
索引有很多类型，可以为不同的场景提供更好的性能。在MySQL中，索引是在存储引擎层而不是服务层实现。所以，并没有统一的索引表中；不同存储引擎的索引工作方式并不一样，也不是所有的存储引擎都支持所有类型的索引。即使多个存储引擎支持同一种类型的索引，其底层的实现也可能不同。

B-Tree
当我们讨论索引时，一般说的是B-Tree索引，它使用B-Tree数据结构来存储数据。大多数MySQL引擎都支持这种索引。Archive引擎是一个礼物；5.1之前不支持任何索引，5.1以后才支持单个自增列的索引。

不过，底层的存储引擎也可能使用不同的存储结构，例如NDB集群存储引擎内部实际使用了T-Tree结构存储这种索引，即使其名字是BTREE；InnoDB则是使用了B+Tree。

存储引擎以不同的方式使用B-Tree索引，性能也各有不同，各有优劣。例如，MyISAM使用前缀压缩技术使索引更小，但InnoDB则按照原数据格式进行存储。再入MyISAM索引通过数据的无力位置引用被索引的行，而InnoDB则根据主键引用被索引的行。

B-Tree通常以为着所有的值都是按顺序存储的，并且每一个叶子页到根的距离相同。



B-Tree索引能够加快访问数据的速度，因为存储引擎不在需要进行全表扫描来获取需要的数据，取而呆滞的是从索引的根节点开始进行搜索。跟节点的槽中存放了指向字节点的指针，存储引擎根据这些指针想下层查找。通过比较节点也的值的上限和下限来判断。最终存储引擎找到值，或记录不存在。

叶子节点比较特别，他们的指针指向的是被索引的数据，而不是其他的节点也（不同引擎的指针类型不同。）上图中仅绘制了一个节点和其对应的叶子节点，其实在根节点和叶子检点之间可能有很多层节点页。树的深度和表的大小直接相关。

B-Tree对索引列的顺序组织存储的，所以很适合查找范围数据。例如，在一个机遇文本域的索引书上，按字母顺序传递连续的值进行查找是非常合适的，所以像找出所有已I到K开头的名字，这样的查找效率会非常高。

注意，索引对多个值进行排序的依据是create table语句中定义索引时列的顺序。

可以使用B-Tree索引的查询类型。B-Tree索引使用与全键值、键值范围或键前缀查找。其中键前缀查找只适用于根据最左前缀的查找。前面所述的索引对一下类型的查询有效。

① 全值匹配

全职匹配指的是和索引中的所有列进行匹配，例如姓名为 abc 出生日期为2019-01-10.

② 匹配最左前缀

例如在查找所有姓a的人。

③ 匹配列前缀

也可以只匹配某一列的值的开头部分。例如前面提到的索引可用于查找所有以a开头的的名字。这里只使用了索引的第一列。

④ 匹配范围值

例如前面提到的索引可用于查找姓a到b之间的人。这里也只是用了索引的第一列。

⑤ 精确匹配某一列并范围匹配另外一列

⑥ 只访问索引的查询

B-Tree通常可以支持只访问索引的查询，即查询只需要访问索引，而无需访问数据行。



因为索引树中的节点是有序的，所以除了按值查找之外，索引还可以用于查询中的order by操作。一般来说，如果B-Tree可以按照某种方式查找到值，那么也可以按照这种方式用于排序。所以，如果order by子句满足前面列出的集中查询类型，那么这个索引页可以满足对应的排序需求。

下面是一些关于B-Tree索引的限制：

① 如果不是按照索引的最左列开始查找，则无法使用索引。

② 不能跳过索引中的列。例：索引包含a b c三个列查询时不能只使用a c两列查询

③ 如果查询中有某个列的范围查询，则其右边所有列都无法使用索引优化查询

所以索引中列的顺序很重要，在优化性能的时候，可能需要使用相同的列但顺序不同的索引来满足不同类型的查询需求。

也有写限制并不是B-Tree本身导致的，而是MySQL优化器和存储引擎使用索引的方式导致的。

哈希索引
哈希索引基于哈希表实现，只有精确匹配搜索引所有列的查询才有效。对于每一行数据，存储引擎都会对所有的索引列计算一个哈希码，哈希码是一个较小的值，并且不同键值的行计算胡来的哈希码也不一样。哈希索引将所有的哈希码存储在索引中，同时在哈希表中保存指向每个数据行的指针。

在MySQL中，只有Memory引擎显式支持哈希索引。这也是Memory引擎表的默认索引类型，Memory引擎同时也支持B-Tree索引。值的一提的是，Memory引擎是支持非唯一哈希索引的，如果多个列的哈希值相同，索引会以链表的方式存放到多个记录指针到同一个哈希条目录中。

MySQL会先计算所查找值的哈希值，然后在索引中查找，找到指向行的指针后在去比较两个值是否相同。

因为索引自身之需存储对应的哈希值，所以索引的结构十分紧凑，这也让哈希索引查找的速度非常快。然而哈希索引也有它的限制。

① 哈希索引只包含哈希值和行指针，而不存储字段值，所以不能使用索引中的值来避免读取行。不过访问内存中的行的速度很快，所以大部分情况下不会影响性能。

② 哈希索引数据并不是按照索引值顺序存储的，所以也就无法用于排序。

③ 哈希索引不支持部分索引列匹配查找，因为哈希索引始终是使用索引列的全部内容来计算哈希值的。

④ 哈希索引只支持等值比较查询，包括 =、in、<=>。也不支持任何范围查询。

⑤ 如果哈希冲突很多的话，一些索引维护操作的代价也会很高。例如，如果在某个哈希冲突很多的列上建立索引，那么当从表中删除一行数据时，存储引擎需要遍历对应哈希值的链表中的每一行，找到并删除对应的索引，冲突越多，代价越大。

因为这些限制，哈希索引只使用与某些特定的场合。而一旦适合哈希索引，则它带来的性能提醒将非常显著。

处理Memory引擎外，NDB集群引擎也支持唯一哈希索引，且在NDB集群引擎中作用非常特殊，大家可以自行了解下。

InnoDB引擎有一个特殊的功能叫做自适应哈希索引。当InnoDB注意到某些索引值被使用的非常频繁时，它会在内存中基于B-Tree索引之上在创建一个哈希索引，这样就让B-TRee索引也具有哈希索引的一些优点，比如快速的哈希查找。这是一个完全自动的、内部的行为，用户无法控制或配置，不过可以关闭。

创建自定义哈希索引。如果存储引擎不支持哈希索引，则可以模拟像InnoDB一样创建哈希索引，这可以享受一些哈希索引的遍历，例如只需要很小的索引就可以为超长的键创建索引。

思路很简单，在B-Tree基础上创建一个伪哈希索引。还是使用B-Tree进行查找。但是它使用哈希值而不是键本身进行索引查找。你需要做的就是在查询的WHERE查询中手动指定使用哈希函数。

也可以使用触发器实现，例：

先创建表，然后创建触发器。先临时修改一下语句分隔符，这样可以在触发器定义中使用分号



然后让我们测试一下





如果使用这种方式，记住不要使用SHA1()和MD5()作为哈希函数。因为这两个函数计算出来的哈希值是非常长的字符串，会浪费大量空间，比较时也会更慢。SHA1()和MD5()是强加密函数，设计目标是最大限度消除冲突，但这里不需要这样高的要求。简单哈希函数的冲突在一个可以接受的范围，同时又能提供更好的性能。

如果数据表非常大CRC32()会出现大量的哈希冲突，则可以考虑自己实现一个简单的64位哈希函数。这个自定义函数要返回整数，而不是字符串。一个简单的办法就可以使用MD5()函数的返回值的一部分来作为自定义哈希函数。这比自己写一个哈希算法的性能可能会差一点，但实现简单。

select conv(right(md5('https://blog.csdn.net/yongqi_wang'),16),16,10) as hash64;

处理哈希冲突，当使用哈希索引进行查询的时候，必须在where自居中包含常量值

select id from hash_table where url_crc = crc32('https://blog.csdn.net/yongqi_wang') and url = 'https://blog.csdn.net/yongqi_wang';

否则一旦出现哈希冲突，另一个字符串的哈希值也相同那么查询时无法正确工作的。

要避免冲突问题，必须在where条件中带入哈希值和对应列值。如果不是想查询具体值，例如只是统计记录数，则可以不带入列值，直接使用crc32（）的哈希值查询即可。还可以使用如fnv64()函数作为哈希函数，这是移植自Percona Server的函数，可以以插件的方式在任何MySQL版本中使用，哈希值为64位，速度快，且冲突比crc32()要少很多（crc32()函数中索引有93000条出现冲突的概率是百分之一）。

空间数据索引（R-Tree）
MyISAM表支持空间索引，可以用做地理数据存储。和B-Tree索引不同，这类索引无须前缀查询。空间索引会从所有纬度来索引数据。查询时，可以有效的使用任意纬度来组合查询。必须使用MySQL的GIS相关函数如MBRCONTAINS()等来维护数据。MySQL的GIS支持并不完善，所以大部分人都不会使用这个特性。开源关系数据库系统中对GIS的解决方案做的比较好的是PostgreSQL的PostGIS。

全文索引
全文索引是一种特殊类型的索引，它查找的是文本中的关键词，而不是直接比较索引中的值。全文搜索和其他积累索引的匹配方式完全不一样。它有许多需要注意的细节，如停用词、词干和负数、布尔搜索等。全文索引更乐死与搜索引擎做的事情而不是简单的where条件匹配。

在相同的列上同时创建全文索引和基于值的B-Tree索引不会有冲突，全文索引使用与match against操作，而不是普通的where、条件操作。

创建全文索引
alter table test_user add fulltext index idx_user_name(user_name);
使用全文索引
select * from test_user where match(user_name) against('abc' in boolean mode);
其他索引类别
还有很多第三方的存储引擎使用不同类型的数据结构来存储索引。例如TokuDB使用分形树索引，这是一类新开发的数据结构，即有B-Tree的很多优点，也避免了B-Tree的一些缺点。

ScaleDB使用Patricia tries，其他一些存储引擎技术如InfiniDB和Infobright则使用了一些特殊的数据结构来优化某些特殊的查询

良好的逻辑设计和物理设计是高性能的基石，应该根据系统将要执行的查询语句来设计Schema，这往往需要权衡各种因素。例如，反范式的设计可以加快某些类型的查询，但同时可能使另一些类型的查询变慢。比如添加技术表和汇总表时一种很好的优化查询的方式，但这些表的维护成本可能会很高。MySQL独有的特性和实现细节对性能的影响也很大。

选择优化的数据类型
MySQL支持的数据类型非常多，选择正确的数据类型对于获得高性能至关重要。不管存储哪种类型的数据，下面几个简单的原则都有助于做出更好的选择。

① 更小的通常更好：

一般情况下，应该尽量使用可以正确存储数据的最小数据类型。更小的数据类型通常更快，因为它们占用更少的磁盘、内存和CPU缓存，并且处理时需要的CPU周期也更少。

但是要确保没有低估需要存储的值的范围，因为在schema中的多个地方增加数据类型的范围是一个非常耗时的操作。如果无法确定哪个数据类型是最好的，就选择你认为不会超过范围的最小类型。

② 简单就好：

简单数据类型的操作通常需要更少的CPU周期。例如，整形比字符操作代价更低，因为字符集和校对规则（排序规则）使字符比较比整形比更复杂。

③ 尽量避免NULL：

很多表都包含可以为NULL的列，即使应用程序并不需要保存NULL也是如此，这是因为可为NULL是列的 默认属性。通常情况下最好指定为NOT NULL，除非真的需要存储NULL值。

如果查询中包含可为NULL的列，对MySQL来说更难优化，因为NULL的列使得索引、索引统计和值比较都更复杂。可为NULL的列会使用更多的存储空间，在MySQL里也需要特殊处理。当可以为NULL的列被索引时，每个索引记录需要一个额外的字节，在MyISAM里甚至还可能导致固定大小的索引变成可变大小的索引（例如只有一个整数列的索引）。

通常可以把NULL的列改为NOT NULL带带的性能提升比较小，所以调优时没有必要受限在现有schema中查找并修改这种情况，除非确定这会导致问题。但是，如果计划在列上建立索引，就应该尽量避免设计成可为NULL的列。

当然也有例外，例如InnoDB使用单独的位（bit）存储NULL值，所以对于稀疏数据（很多值为NULL，只有少数行非NULL）有很好的空间效率。但这一点不适用与MyISAM。

 

在为列选择数据类型时，第一步需要确定合适的大类型数字、字符串、时间等。这通常是很简单的，但是我们会提到一些特殊的不是那么直观的例子。

下一步是选择具体类型。很多MySQL的数据类型可以存储相同类型的数据，只是存储的长度和范围不一样、允许的经度不同，或者需要的无力空间（磁盘和内存空间）不同。相同大类型的不同子类型数据有时也有一些特殊的行为和属性。

例如，DATATIME和TIMESAMP列都可以存储相同类型的数据：时间和日期，精确到秒。然而TIMESTAMP只使用DATATIME一半的存储空间，并且会根据时区变化，具有特殊的自动更新能力。另一方面，TIMESTAMP允许的时间范围要小得多，有时候他的特殊能力也会成为障碍。

1 整数类型
有两种类型的数字：整数和实数。如果存储整数，可以使用者集中整数类型：TINYINT，SMALLINT,MEDIUMINT,INT,BIGINT。分别使用8,16,24,32,64位存储空间。它们可以存储的值的范围从-2^(n-1)到-2^(n-1)-1，其中N是存储空间的位数。

整数类型有可选的UNSIGNED属性，表示不允许负值，这大致可以使正数的上线提高一倍。例如TINYINT。UNSIGNED可以存储的范围是0~255，而TINYINT的存储范围是-128~127.

有符号和无符号类型使用相同的存储空间，并具有相同的性能，因此可以根据实际情况选择合适的类型。

你的选择决定MySQL是怎么在内存和磁盘中保存数据的。然而，整数计算一般使用64位的BIGINT整数，即使在32位环境也是如此。（一些聚合函数除外，它们使用DECIMAL或DOUBLE进行计算）

MySQL可以为整数类型指定宽度，例如INT(11)，对大多数应用这是没有意义的：它不会限制值的合法范围，只是规定了MySQL的一些交互工具（例如MySQL命令行客户端）用来显示字符的个数。对于存储和计算来说，INT(1)和INT(20)是相同的。

2 实数类型
实数是带有小数部分的数字。然而，它们不只是为了存储小数部分；也可以使用DECIMAL存储比BIGINT还大的整数。MySQL即支持精确类型，也支持不精确类型。

FLOAT和DOUBLE类型支持使用标准的浮点运算进行近似计算。如果需要知道浮点运算是怎么计算的，则需要研究所使用的平台的浮点数的具体实现。

DECIMAL类型用于存储精确的小数。在MySQL5.0和更高版本，DECIMAL类型支持精确计算。MySQL4.1以及更早版本则使用浮点运算来实现DECIAML的计算，这样会因为经度损失导致一些奇怪的结果。在这些版本的MySQL中，DECIMAL只是一个存储类型。

因为CPU不支持对DECIMAL的直接计算，所以在MySQL5.0以及更高版本中，MySQL服务器自身实现了DECIMAL的高经度计算。相对而言，CPU直接支持原生浮点计算，所以浮点运算明显更快。

浮点和DECIMAL类型都可以指定经度。对于DECIMAL列，可以指定小数点前后所允许的最大位数。这会影响列的空间消耗。MySQL5.0和更高版本将数字打包保存到一个二进制字符串中（每4个字节存9个数字）。例如DECIMAL（18,9）小数点两边将各存储9个数字，一共使用9个字节：小数点前的数字用4个字节，小数点后的数字用4个字节，小数点本身占一个字节。

MySQL5.0和更高版本中的DECIMAL类型允许最多65个数字。而更早的版本中这个限制是254个数字，并且保存为未压缩的字符串。然而，这些版本实际上并不能在计算中使用这么大的数字，因为DECIMAL只是一种存储格式：在计算中DECIMAL会转换成DOUBLE类型。

有多重方法可以指定浮点列锁需要的经度，这会使得MySQL悄悄选择不同的数据类型，或者在存储时对值进行取舍。这些经度定义是非标准的，所以我们建议只指定数据类型，不指定精度。

浮点类型在存储同样范围的值时，通常比DECIMAL使用更少的空间。FLOAT使用4个字节存储。DOUBLE占用8个字节，相比FLOAT有更高精度和更大的范围。和整数类型一样，能选择的只是存储类型：MySQL使用DOUBLE作为内部浮点计算的类型。

因为需要额外的空间和计算开销，所以应该尽量只在对小数进行精确计算时才使用DECIMAL。例如存储财务数据。但在数据量比较大的时候，可以考虑使用BIGINT代替DECIMAL，将需要存储的货比单位根据小数的位数乘以响应的倍数即可。假设要存储财务数据精确到万分之一分，则可以吧所有金额乘100W，然后将结果存储在BIGINT里，这样可以同时避免浮点存储计算不精确和DECIMAL精确计算代价高的问题。

3 字符串类型
MySQL支持多种字符串类型，每种类型还有很多变种。这些数据在4.1和5.0版本发生了很大的变化，使得情况更加复杂。从MySQL4.1开始，每个字符串列可以定义自己的字符集和排序规则，或者说校对规则。这些东西会很大程度上影响性能。

VARCHAR和CHAR类型
VARCHAR和CHAR是两种最主要的字符串类型。不幸的是，很难精确的解释这些值是怎么存储在磁盘和内存中的，因为这根存储引擎的具体实现有关。下面假设使用的存储引擎是InnoDB或MyISAM。如果不是这两种引擎，请参考存储引擎相关文档。

VARCHAR

varchar类型用于存储可边长字符串，是最常见的字符串数据类型。它比定长类型更节省空间，因为它仅使用必要的空间。有一种情况例外，如果MySQL表使用ROW_FORMAT=FIXED创建的话，每一行都会使用定长存储，这会很浪费空间。

VARCHAR需要使用1或2个额外字节记录字符串的长度；如果列的最大长度小于或等于255字节，则只使用1个字节表示，否则使用2个字节。

VARCHAR节省了存储空间，所以对性能也有帮厨。但是，由于行是变长的，在UPDATE时可能使行变得比原来更长，这就导致需要做额外的工作。如果一个行占用的空间增长，并且在页内没有更多的空间可以存储，在这种情况下，不同的存储引擎的处理方式是不一样的。例如，MyISAM会将行拆分成不同的片段存储，InnoDB则需要分裂页来使行可以放入页内。其他一些存储引擎也许从不在原数据位置更新数据。

下面这些情况下是很合适使用VARCHAR的：

①  字符串列的最大长度比平均长度大很多

② 列的更新很少，所以碎片不是问题

③ 使用了想UTF-8这样复杂的字符集，每个字符都使用不同的字节数进行存储。

CHAR

CHAR类型是定长的，MySQL总是根据定义的字符串长度分配足够的空间。当存储CHAR值时，MySQL会删除所有的末尾空格。CHAR值会根据需要采用空格进行填充以方便比较。

CHAR适合存储很短的字符串，或者所有值都接近同一个长度。例如存储密码的MD5值，因为这是一个定长的值。对于经常变更的数据，CHAR也比VARCHAR更好，因为定长的CHAR类型不容易产生碎片。对于非常短的列，CHAR比VARCHAR在存储空间上也更有效率。

 

CHAR类型的这些行为可能有些难以理解，下面通过一个具体的例子来说明。首先我们创建一张只有一个CHAR(10)字段的表并插入几条数据 ：



当检索这些值的时候，你会发现str3末尾的空格被截断了；



数据如何存储取决于存储引擎盖，并非所有的存储引擎都会按照相同的方式处理定长和变长的字符串。Memory引擎只支持定长的行，即使有变长字段也会根据最大长度分配空间。不过，田中和截取空格的行为在不同存储引擎都是一样的，因为这是在MySQL服务器层进行处理的。

与CHAR和VARCHAR类似的类型还有BINARY和VARBINARY，它们存储的是二进制字符串。二进制字符串跟常规字符串非常相似，但是二进制字符串存储的是字节码而不是字符。填充也不一样；MySQL填充BINARY采用的是\0 而不是空格，在检索时也不会去掉填充值。

当需要存储二进制数据，并且希望MySQL使用字节码而不是字符进行比较时，这些类型是非常有用的。二进制比较的优势并不仅仅体现在大小写敏感上。MySQL比较BINARY字符串时，每次按一个字节，并且根据该字节的数值进行比较。因此，二进制比较比字符比较简单很多，所以也更快。

需要注意的是：

使用VARCHAR(5)和VARCHAR(100)存储‘hello’的空间开销是一样的。那么使用更短的列有什么优势呢？

事实证明它的优势在于，更长的列会消耗更多的内存，因为MySQL通常会分配固定大小的内存块来保存内部值。尤其是使用内存临时表进行排序或操作时会特别糟糕。在利用磁盘临时表进行排序也很糟糕。

所以最好的策略就是只分配所需空间。

BLOB和TEXT类型
BLOB和TEXT都是为存储很大的数据而设计的字符串数据类型，分别采用二进制和字符方式存储。

实际上，他们分别属于两种不同的数据类型；

字符类型是：TINYTEXT,SMALLTEXT,TEXT,MEDIUMTEXT,LONGTEXT；

二进制类型是：TINYBLOB,SMALLBLOB,BLOB,MEDIUMBLOB,LONGBLOB；

与其他类型不同，MySQL把每个BLOB和TEXT值当作一个独立的对象处理。存储引擎在存储时通常会做特殊处理。当BLOB和TEXT值太大时，InnoDB会使用专门的外部存储区域来进行存储，此时每个值在行内需要1~4个字节存储一个指针，然后在外部存储区域存储实际的值。

BLOB和TEXT家族之间仅有的不同是BLOB类型存储的是二进制数据，没有排序规则或字符集，而TEXT类型有字符集和排序规则。

MySQL对BLOB和TEXT列进行排序与其他类型是不同的；它支队每个列的最前max_sort_length字节而不是整个字符串做排序。如果只需要排序前面一笑部分字符，则可以减小max_sort_length的配置，或者使用ORDER BY SUSTRING(column,length);

MySQL不能讲BLOB和TEXT列全部长度的字符串进行索引，也不能使用这些索引消除排序。

需要注意的是：因为Memory引擎不支持BLOB和TEXT类型，所以，如果查询使用了BLOB或TEXT列并且需要使用隐式临时表，将不得不使用MyISAM磁盘临时表，即使只有几行数据也是如此。

这会导致严重的性能开销。即使配置MySQL将临时表存储在内存块设备上，依然需要许多昂贵的系统调用。

最好的解决方案是尽量避免是用BLOB和TEXT类型。如果实在无法避免，有一个技巧是在所有用到BLOB字段的地方都是用SUBSTRING(column,length)将列值转换为字符串，这样就可以使用内存临时表了。但是要确保截取的子串够端，不会使临时表的大小超过max_heap_table_size或tmp_table_size，超过后MySQL会将内存临时表转换为MyISAM磁盘临时表。

最坏情况下的长度分配对于排序的时候也是一样的，所以这一招对内存中创建大临时表和文件排序，以及在磁盘上创建大临时表和文件排序这两种情况都很有帮助。

使用枚举（ENUM）代替字符串类型
有时候可以使用枚举列代替常用的字符串类型。枚举列可以把一些不重复的字符串存储成一个预定含义的集合。MySQL在存储枚举时非常紧凑，会根据列表值的数量压缩到一个或两个字节中。MySQL在内部会将每个值在列表中的位置保存为整数，并且在表的.frm文件中保存“数字 - 字符串”映射关系的查找表。下面有一个例子；



这三行数据实际存储为整数，而不是字符串。可以通过数字上下文环境检索看到这个双重属性：
 



如果使用数字作为ENUM枚举常量，这种双重性很容易导致混乱，所以尽量避免这么使用。

另外一个需要注意的是，枚举字段不是按照字符串进行排序的，而是按照内部存储的整数进行排序的。

一种绕过这种限制的方式是按照需要的顺序来定义枚举列。另外也可以在查询中使用FIELD（）函数显示的指定排序顺序，但这回导致MySQL无法利用索引消除排序：

select e form enum_test order by field(e,'pig','fish','dog');

如果在定义时就是按照字母的顺序，就没有必要这么做了。

枚举最不好的地方时，字符串列表时固定的，添加或删除字符串必须使用ALTER TABLE。

因此，对于一系列未来可能会改变的字符串，使用枚举不是一个好主意，触发能接受只在列表末尾添加元素，这样在MySQL5.1中就可以补用重建整个表来完成修改。

由于MySQL把每个枚举值保存为整数，并且必须进行查找才能转换为字符串，所以枚举列有一些开销。通常枚举的列表都比较小，所以开销还可以控制，但也不能保证一直如此。在特定情况下，把CHAR/VARCHAR列与枚举列进行关联可能会比直接关联CHAR/VARCHAR列更慢。

4 日期和时间类型
MySQL可以使用许多类型来保存日期和时间值，例如YEAR和DATE。MySQL能存储的最小时间粒度为妙（MariaDB支持微妙级别的时间类型）。但是MySQL也可以使用微妙级的粒度进行临时运算，我们会展示怎么绕开这种存储限制。

大部分时间类型都没有替代品，因此没有什么是最佳选择的问题。唯一的问题是保存日期和时间的时候需要做什么。MySQL提供两种相似的日期类型；DATETIME和TIMESTAMP。对于很多应用程序，它们都能工作，但是在某些场景，一个比另一个工作的好。

① DATETIME

这个类型能保存大范围的值，从1001年到9999年，经度为秒。它把日期和时间封装到格式为YYYYMMDDHHMMSS的整数中，与时区无关。使用8个字节的存储空间。

默认情况下，MySQL以一种可排序的、无歧义的格式显示DATETO,E值，例如“2019-01-08 14:30:00”。这是ANSI标准定义的日期和时间表示方法。

② TIMESTAMP

就像它的名字一样，TIMETAMP类型保存从1970年1月1日午夜依赖的秒数，它和UNIX时间戳相同。TIMESTAMP只使用4个字节的存储空间，因为它的范围比DATETIME小的多；只能表示从1970年到2038年。MySQL提供了FROM_UNIXTIME（）函数把UNIX时间戳转换为日期，并提供了UNIX_TIMESTAMP()函数把日期转换为Unix时间戳。

MySQL4.1以上版本按照DATRETIME的方式格式化TIMESTAMP的值，但是4.0及过去版本不会再各个部分之间显示任何标点符号。这仅仅是显示格式上的区别，TIMESTAMP的存储格式在各个版本都是一样的。

TIMESTAMP显示的值也依赖于时区。MySQL服务器、操作系统，以及客户端连接都有时区设置。

因此，存储值为0的TIMESTAMP在美国东部时区显示为“1969-12-31 19:00:00”，与格林尼时间差5个小时。有必要强调一下这个区别；如果多个时区存储或访问数据，TIMESTAMP和DATETIME的行为将很不一样。前者提供的值与时区有关系，后者则保留文本表示的日期和时间。

 

除了特殊行为之外，通常也应该尽量使用TIMESTAMP，因为它比DATETIME空间效率更高。有时候人们会将UNIX时间戳存储为整数值，但这不会带来任何收益。用整数保存时间的格式通常不方便处理，所以不推荐这样做。

如果需要存储比秒更小粒度的日期和时间值怎么办？MySQL目前没有提供合适的数据类型，但是可以使用自己的存储格式；可以使用BIGINT类型存储微妙级别的时间戳或者使用DOUBLE存储秒之后的小数部分，这两种方式都可以，或者也可以使用MariaDB替代MySQL。

5 位数据类型
MySQL有少数几种存储类型使用紧凑的位存储数据。所有这些位类型，不管底层存储格式和处理方式如何，从技术上来说都是字符串类型。

① BIT

在MySQL5.0之前，BIT是TINYINT的同义词。但是在5.0以后，这是一个特性完全不同的数据类型。下面我们将讨论下BIT类型新的行为特性。

可以使用BIT列在一列中存储一个或多个true/false值。BIT(1)定义一个包含单个为的字段，BIT(2)存储2个位，以此类推。BIT列的最大长度时64个位。

BIT的行为因存储引擎而异。MyISAM会打包存储所有的BIT列，所以17个单独的BIT列只需要17个位存储（假设没有可为NULL的列），这样MyISAM只使用3个字节就能存储着17个BIT列。其他存储引擎例如Memory和InnoDB，为每个BIT列使用一个足够存储的最小整数类型来存放，所以不能节省存储空间。

MySQL把BIT当作字符串类型，而不是数字类型。当检索BIT(1)的值时，结果是一个包含二进制0或1值的字符串，而不是ASCII码的0 或 1.然而，在数字上下文的场景中检索时，结果将是位字符串转换成的数字。如果需要和另外的值比较结果，一定要记得这一点。例如，如果存储一个值b'00111001'(二进制值等于57)到BIT(8)的列并且检索它，得到的内容时字符码为57的字符串。也就是得到ASCII码为57的字符串‘9’。但是在数字上下文场景中，得到的数字是57.

例：



这是相当令人费解的，所以我们认为应该谨慎使用BIT类型，对于大部分应用，最好避免使用这种类型。

如果想在一个it的存储空间中存储一个true/false值，另一个放马是创建一个可以为空的CHAR(0)列，该列可以保存空值或者长度为零的字符串。

② SET

如果需要保存很多true/false值，可以考虑合并这些列到一个SET数据类型，它在MySQL内部是以一系列打包的位的集合来表示的。这样就有效的利用了存储空间，并且MySQL有想FIND_IN_SET和FIELD()这样的函数，方便的在查询中使用。它的主要缺点是改变列的定义的代价较高，需要alter table。一般来说，也无法在set列上通过索引查找。

③ 在整数列上进行按位操作

一种替代SET的方式是使用一个整数包装一系列的位。例如，可以把8个位包装到一个TINYINT钟，并且按位操作来使用。可以在应用中为每个位定义名称常量来简化这个工作。

比起SET，这种办法主要的好处在于可以不适用alter table改变字段代表的枚举值，缺点是查询语句更难写，并且更难理解。

 

一个包装位的应用例子是保存权限的访问控制列表。每个位或者SET元素代表一个值，如果CAN_READ、CAN_WRITE，或者CAN_DELETE。如果使用SET列，可以让MySQL在定义里存储位到值的映射关系；如果使用整数列，则可以在应用代码里存储这个对应关系。例：



如果使用整数来存储，则可以参考下面的例子



这里我们使用MySQL变量来定义值，但是也可以在代码中使用常量来代替。

6 选择标识符（identifier）
为标识列选择合适的数据类型非常重要。一般来说更有可能用标识列与其他值进行比较，或者通过标识列寻找其他列。标识列也可能在另外的表中作为外键使用，所以为标识列选择数据类型时，应该选择跟关联表中的对应列一样的类型。

当选择标识列的类型时，不仅仅需要考虑存储类型，还需要考虑MySQL对这种类型怎么执行计算和比较。例如，MySQL在内部使用整数存储ENUM和SET类型，然后在做比较操作时转换为字符串。

一旦选的了一种类型，要确保在所有关联 表中都使用同样的类型。类型之间需要精确匹配，包括想UNSIGNED这样的属性。混用不同数据类型可能导致性能问题，即使没有性能 影响，在比较操作时隐式类型转换也可能导致很难发现的错误。这种错误可能会很久以后才出现，那时候你可能已经忘记是在比较不同的数据类型了。

在可以满足值的范围的需求，并且预留未来增长空间的前提下，应该选择最小的数据类型。例如有一个state_id列存储美国各洲的名字，就不需要几千个值，所以使用TINYINT足够存储，而且比INT少了3个字节。入股哦这个值作为其他表的外键，3个字节可能导致很大的性能差异。

① 整数类型

整数通常是标识类做好的选择，因为它们很快并且十一使用AUTO_INCREMENT.

② ENUM和SET类型

对于标识类来说，EMUM和SET类型通常是一个糟糕的选择，尽管对某些只包含固定状态或者类型的静态定义表来说可能是没有问题的。ENUM和SET列适合存储固定信息，例如有序的状态、产品类型、性别等。

③ 字符串类型

如果可能，应该避免使用字符串类型作为标识列，因为他们很销毁空间，并且通常比数字类型慢。尤其是在MyISAM表里使用字符串作为标识列时要特别小心。MyISAM默认对字符串使用压缩索引，这会导致查询慢得多。在我们的测试中，发现最多会有6倍的性能下降。

对完全随机的字符串也需要多加注意，例如MD5()、SHAL()或UUID()产生的字符串。这些函数生成的新值会任意分布在很大的空间内，这会导致Insert以及一些select语句变得很慢。

[1] 因为插入值会随机的写道索引的不同位置，所以使insert语句变慢。这会导致页分裂、磁盘随机访问，以及对于聚簇存储引擎产生聚簇索引碎片。

[2] select会变的更慢，因为所及上相邻的行辉分布在磁盘和内存的不同地方。

[3] 随机值导致缓存对所有类型的查询语句效果都很差，因为会使缓存依赖的访问局部性原理失效。如果整个数据集都是一样的，那么缓存任何一部分特定数据到内存都没有好处；如果工作集比内存大，缓存将会有很多刷新和不命中。

如果存储UUID值，则应该移除“-”符号，或者最好的做法是用UNHEX()函数换行UUID值为16字节的数字，并且存储在一个BINARY(16)列中。检索时可以通过HEX()函数来格式化为16进制格式。

UUID()生成的值与加密三列函数SHAL()生成的值有不同的特征；UUID值虽然分布也不均匀，但是还是有一定顺序的。尽管如此，还是不如递增的整数好用。

 

注意：当心自动生成的schema

我们已经介绍了大部分重要的数据类型的考虑，但是还没有提到自动生成的schema设计有多糟糕。

写的很烂的schema迁移程序，或者自动生成schema的程序，都会导致严重的性能问题。有些程序存储任何东西都会使用很大的VARCHAR列，或者对需要在关联时使用不同的数据类型。如果schema是自动生成的，一定要反复检查确认。

ORM系统是另一种常见的性能噩梦，一些ORM系统会存储任意类型的数据到任意类型的后端数据存储中，这通常以为着并没有设计使用更优的数据类型来存储。有时会为每个对象的每个属性使用单独的行，甚至使用基于时间戳的版本控制，导致单个属性会有多个版本存在。

7 特殊类型数据
某些类型的数据并不直接与内置类型一致。低于秒级精度的时间戳就是一个例子；

另一个例子是IPv4地址。人们经常是用VARCHAR(15)列来存储IP地址。然而，它们实际上是32位无符号整数，不是字符串。用小数点将地址分成4端的表示方法只是为了让人们易读。所以应该用无符号整数存储IP地址。MySQL提供INET_ATON()和INET_NTOA()函数在这两种表示方法之间转换