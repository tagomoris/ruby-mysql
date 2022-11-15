# ruby-mysql

## Description

ruby-mysql is a MySQL client library.
It is written entirely in Ruby.
Therefore libmysqlclient is not required and no compilation is required during installation.

## Installation

```ruby
gem install ruby-mysql
```

## Synopsis

```ruby
require 'mysql'

my = Mysql.connect('mysql://username:password@hostname:port/dbname?charset=utf8mb4')
my.query("select col1, col2 from tblname").each do |col1, col2|
  p col1, col2
end
stmt = my.prepare('insert into tblname (col1,col2) values (?,?)')
stmt.execute 123, 'abc'
```

## Major incompatibility with 3.0

### Result values are now converted by default

| MySQL type          | Ruby class         |
|---------------------|--------------------|
| NULL                | NilClass           |
| INT                 | Integer            |
| DECIMAL             | BigDecimal         |
| FLOAT, DOUBLE       | Float              |
| DATE                | Date               |
| DATETIME, TIMESTAMP | Time               |
| TIME                | Float (as seconds) |
| YEAR                | Integer            |
| CHAR, VARCHAR       | String             |
| BIT                 | String             |
| TEXT, BLOB, JSON    | String             |

3.0:
```ruby
pp my.query('select 123,123.45,now(),cast(now() as date)').fetch.map{[_1, _1.class]}
#=> [["123", String],
#    ["123.45", String],
#    ["2022-11-15 00:17:11", String],
#    ["2022-11-15", String]]
```

4.0:
```ruby
pp my.query('select 123,123.45,now(),cast(now() as date)').fetch.map{[_1, _1.class]}
#=> [[123, Integer],
#    [0.12345e3, BigDecimal],
#    [2022-11-15 00:17:17 +0900, Time],
#    [#<Date: 2022-11-15 ((2459899j,0s,0n),+0s,2299161j)>, Date]]
```

To specify `cast: false`, you get the same behavior as in 3.0.
```ruby
my.query('select 123,123.45,now(),cast(now() as date)', cast: false).fetch.map{[_1, _1.class]}
#=> [["123", String],
#    ["123.45", String],
#    ["2022-11-15 00:19:18", String],
#    ["2022-11-15", String]]
```

It can also be specified during Mysql.new and Mysql.connect.

```ruby
my = Mysql.connect('mysql://user:pass@localhost/', cast: false)
```

Changing mysql.default_options will affect the behavior of subsequently created instances.

```ruby
my1 = Mysql.connect('mysql://user:pass@localhost/')
Mysql.default_options[:cast] = false
my2 = Mysql.connect('mysql://user:pass@localhost/')
pp my1.query('select 123,123.45,now(),cast(now() as date)').fetch.map{[_1, _1.class]}
#=> [[123, Integer],
#    [0.12345e3, BigDecimal],
#    [2022-11-15 00:26:09 +0900, Time],
#    [#<Date: 2022-11-15 ((2459899j,0s,0n),+0s,2299161j)>, Date]]
pp my2.query('select 123,123.45,now(),cast(now() as date)').fetch.map{[_1, _1.class]}
#=> [["123", String],
#    ["123.45", String],
#    ["2022-11-15 00:26:09", String],
#    ["2022-11-15", String]]
```

### Mysql::Result#each now always return records from the beginning

3.0:
```ruby
res = my.query('select 123 union select 456')
res.entries
#=> [["123"], ["456"]]
res.entries
#=> []
```

4.0:
```ruby
res = my.query('select 123 union select 456')
res.entries
#=> [[123], [456]]
res.entries
#=> [[123], [456]]
```

## Copyright

* Author: TOMITA Masahiro <tommy@tmtm.org>
* Copyright: Copyright 2008 TOMITA Masahiro
* License: MIT
