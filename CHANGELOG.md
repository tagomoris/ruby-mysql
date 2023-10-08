## [4.1.0] - 2023-10-08

- Support geometry column <https://gitlab.com/tmtms/ruby-mysql/-/merge_requests/1>
- FIX: If the server is localhost and disconnect the connection, Errno::EPIPE is raised <https://gitlab.com/tmtms/ruby-mysql/-/merge_requests/3> <https://gitlab.com/tmtms/ruby-mysql/-/issues/1>
- Allow for existing socket when connecting <https://gitlab.com/tmtms/ruby-mysql/-/merge_requests/2> <https://gitlab.com/tmtms/ruby-mysql/-/merge_requests/5>
  - add `io` keyword parameter

## [4.0.0] - 2022-11-09

### Incompatible changes

- unsupport MySQL 5.5 and Ruby 2.5
- `Mysql::Result#fetch` returns converted values unless `cast` is false
- `Mysql::Result#each` always returns records from the beginning
- Retrieving a DECIMAL type with a prepared statement returns a `BigDecimal` object instead of `String`
- Retrieving a DATE type value with a prepared statement returns a `Date` object instead of `Time`
- delete `Mysql#more_results`. use `#more_results?` instead.
- remove `Mysql::Result#fetch_field`, `#field_tell`, `#field_seek`, `#fetch_field_direct`, `#fetch_lengths`, `#num_fields`.
- error 'command out of sync' is `Mysql::ClientError::CommandOutOfSync` instead of `RuntimeError`.
- error 'Authentication requires secure connection' is `Mysql::ClientError::AuthPluginErr` instead of `RuntimeError`.

### Features

- `Mysql.default_options` is global options.
- `Mysql#connect` option `ssl_mode`: support `SSL_MODE_VERIFY_CA`, `SSL_MODE_VERIFY_IDENTITY`.
- `Mysql#connect` option `ssl_context_params`: see `OpenSSL::SSL::SSLContext#set_params`.
- `Mysql#connect` option `connect_attrs`.
- `Mysql::Stmt#more_results?`, `#next_result`, `#info`.
- `Mysql#close` and `Mysql::Stmt#close` read pending packets.
- `Mysql#query` and `Mysql::Stmt#execute` option: `return_result` and `yield_null_result`.
- support session tracking. See https://dev.mysql.com/doc/refman/8.0/en/session-state-tracking.html
- thread safe.
- `Mysql#query`, `Mysql::Stmt#execute` option: `auto_store_result`.
- add `Mysql::Result#server_status`

### Fixes

- When using connection that disconnected from client. error 'MySQL client is not connected' is occured instead of 'MySQL server has gone away'.
- When SSL error, `MySQL::ClientError::ServerLost` or `ServerGoneError` is occured instead of `OpenSSL::SSL::SSLError`.
- `Mysql#server_version` don't require connection.
- use `connect_timeout` instead of `read/write_timeout` on initial negotiation.
- enable to changing `local_infile` for established connection.
- `Mysql.connect` with host nil ignores parameters
- raises `IOError` after `Mysql#close`
- Fractional seconds of time types were ignored when retrieving values using prepared statements
- `Mysql::Stmt#execute` allows true or false values.

### Others

- Mysql#prpare raises Mysql::ClientError if the connection is not connected.
- using rubocop
- migrate from GitHub to GitLab
- ignore Gemfile.lock
- use rspec instead of test-unit
- using connection parameter from spec/config.rb for testing
- split files

## [3.0.1] - 2022-06-18

- LICENSE: correct author
- FIX: correct LOAD DATA LOCAL INFILE result information.
- FIX: reset SERVER_MORE_RESULTS_EXISTS when error packet is received.
- FIX: close the socket when the connection is disconnected.
- FIX: allow multiple results by default.

## [3.0.0] - 2021-11-16

- `Mysql.new` no longer connect. use `Mysql.connect` or `Mysql#connect`.

- `Mysql.init` is removed. use `Mysql.new` instead.

- `Mysql.new`, `Mysql.conncet` and `Mysql#connect` takes URI object or URI string or Hash object.
  example:
      Mysql.connect('mysql://user:password@hostname:port/dbname?charset=ascii')
      Mysql.connect('mysql://user:password@%2Ftmp%2Fmysql.sock/dbname?charset=ascii') # for UNIX socket
      Mysql.connect('hostname', 'user', 'password', 'dbname')
      Mysql.connect(host: 'hostname', username: 'user', password: 'password', database: 'dbname')

- `Mysql.options` is removed. use `Mysql#param = value` instead.
  For example:
      m = Mysql.init
      m.options(Mysql::OPT_LOCAL_INFILE, true)
      m.connect(host, user, passwd)
  change to
      m = Mysql.new
      m.local_infile = true
      m.connect(host, user, passwd)
  or
      m = Mysql.connect(host, user, passwd, local_infile: true)

- `Mysql::Time` is removed.
  Instead, `Time` object is returned for the DATE, DATETIME, TIMESTAMP data,
  and `Integer` object is returned for the TIME data.
  If DATE, DATETIME, TIMESTAMP are invalid values for Time, nil is returned.

- meaningless methods are removed:
  * `bind_result`
  * `client_info`
  * `client_version`
  * `get_proto_info`
  * `get_server_info`
  * `get_server_version`
  * `proto_info`
  * `query_with_result`

- alias method are removed:
  * `get_host_info`: use `host_info`
  * `real_connect`: use `connect`
  * `real_query`: use `query`

- methods corresponding to deprecated APIs in MySQL are removed:
  * `list_dbs`: use `SHOW DATABASES`
  * `list_fields`: use `SHOW COLUMNS`
  * `list_processes`: use `SHOW PROCESSLIST`
  * `list_tables`: use `SHOW TABLES`
