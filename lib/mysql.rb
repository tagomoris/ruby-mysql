# coding: ascii-8bit

# Copyright (C) 2008 TOMITA Masahiro
# mailto:tommy@tmtm.org

require 'uri'

# MySQL connection class.
# @example
#  my = Mysql.connect('hostname', 'user', 'password', 'dbname')
#  res = my.query 'select col1,col2 from tbl where id=123'
#  res.each do |c1, c2|
#    p c1, c2
#  end
class Mysql
  require_relative "mysql/field"
  require_relative "mysql/result"
  require_relative "mysql/stmt"
  require_relative "mysql/constants"
  require_relative "mysql/error"
  require_relative "mysql/charset"
  require_relative "mysql/protocol"
  require_relative "mysql/packet"

  VERSION            = -'4.1.0'             # Version number of this library
  MYSQL_UNIX_PORT    = -"/tmp/mysql.sock"   # UNIX domain socket filename
  MYSQL_TCP_PORT     = 3306                # TCP socket port number

  # @!attribute [rw] host
  #   @return [String, nil]
  # @!attribute [rw] username
  #   @return [String, nil]
  # @!attribute [rw] password
  #   @return [String, nil]
  # @!attribute [rw] database
  #   @return [String, nil]
  # @!attribute [rw] port
  #   @return [Integer, String, nil]
  # @!attribute [rw] socket
  #   @return [String, nil] socket filename
  # @!attribute [rw] flags
  #   @return [Integer, nil]
  # @!attribute [rw] io
  #   @return [[BasicSocket, OpenSSL::SSL::SSLSocket], nil]
  # @!attribute [rw] connect_timeout
  #   @return [Numeric, nil]
  # @!attribute [rw] read_timeout
  #   @return [Numeric, nil]
  # @!attribute [rw] write_timeout
  #   @return [Numeric, nil]
  # @!attribute [rw] init_command
  #   @return [String, nil]
  # @!attribute [rw] local_infile
  #   @return [Boolean]
  # @!attribute [rw] load_data_local_dir
  #   @return [String, nil]
  # @!attribute [rw] ssl_mode
  #   @return [String, Integer] 1 or "disabled" / 2 or "preferred" / 3 or "required"
  # @!attribute [rw] ssl_context_params
  #   @return [Hash] See OpenSSL::SSL::Context#set_params
  # @!attribute [rw] get_server_public_key
  #   @return [Boolean]
  # @!attribute [rw] connect_attrs
  #   @return [Hash]
  # @!attribute [rw] yield_null_result
  #   @return [Boolean]
  # @!attribute [rw] return_result
  #   @return [Boolean]
  # @!attribute [rw] with_table
  #   @return [Boolean]
  # @!attribute [rw] auto_store_result
  #   @return [Boolean]
  # @!attribute [rw] cast
  #   @return [Boolean]
  DEFAULT_OPTS = {
    host: nil,
    username: nil,
    password: nil,
    database: nil,
    port: nil,
    socket: nil,
    flags: 0,
    io: nil,
    charset: nil,
    connect_timeout: nil,
    read_timeout: nil,
    write_timeout: nil,
    init_command: nil,
    local_infile: nil,
    load_data_local_dir: nil,
    ssl_mode: SSL_MODE_PREFERRED,
    ssl_context_params: {},
    get_server_public_key: false,
    connect_attrs: {},
    yield_null_result: true,
    return_result: true,
    with_table: false,
    auto_store_result: true,
    cast: true,
  }.freeze

  # @private
  attr_reader :protocol

  # @return [Array<Mysql::Field>] fields of result set
  attr_reader :fields

  # @return [Mysql::Result]
  attr_reader :result

  class << self
    # Make Mysql object and connect to mysqld.
    # parameter is same as arguments for {#initialize}.
    # @return [Mysql]
    def connect(*args, **opts)
      self.new(*args, **opts).connect
    end

    # Escape special character in string.
    # @param [String] str
    # @return [String]
    def escape_string(str)
      str.gsub(/[\0\n\r\\'"\x1a]/) do |s|
        case s
        when "\0" then "\\0"
        when "\n" then "\\n"
        when "\r" then "\\r"
        when "\x1a" then "\\Z"
        else "\\#{s}"
        end
      end
    end
    alias quote escape_string

    def default_options
      @default_options ||= DEFAULT_OPTS.dup
    end
  end

  # @overload initialize(uri, **opts)
  #   @param uri [String, URI] "mysql://username:password@host:port/database?param=value&..." / "mysql://username:password@%2Ftmp%2Fmysql.sock/database" / "mysql://username:password@/database?socket=/tmp/mysql.sock"
  #   @param opts [Hash] options
  # @overload initialize(host, username, password, database, port, socket, flags, **opts)
  #   @param host [String] hostname mysqld running
  #   @param username [String] username to connect to mysqld
  #   @param password [String] password to connect to mysqld
  #   @param database [String] initial database name
  #   @param port [String] port number (used if host is not 'localhost' or nil)
  #   @param socket [String] socket filename (used if host is 'localhost' or nil)
  #   @param flags [Integer] connection flag. Mysql::CLIENT_* ORed
  #   @param opts [Hash] options
  # @overload initialize(host: nil, username: nil, password: nil, database: nil, port: nil, socket: nil, flags: nil, **opts)
  #   @param host [String] hostname mysqld running
  #   @param username [String] username to connect to mysqld
  #   @param password [String] password to connect to mysqld
  #   @param database [String] initial database name
  #   @param port [String] port number (used if host is not 'localhost' or nil)
  #   @param socket [String] socket filename (used if host is 'localhost' or nil)
  #   @param flags [Integer] connection flag. Mysql::CLIENT_* ORed
  #   @param opts [Hash] options
  #   @option opts :host [String] hostname mysqld running
  #   @option opts :username [String] username to connect to mysqld
  #   @option opts :password [String] password to connect to mysqld
  #   @option opts :database [String] initial database name
  #   @option opts :port [String] port number (used if host is not 'localhost' or nil)
  #   @option opts :socket [String] socket filename (used if host is 'localhost' or nil)
  #   @option opts :flags [Integer] connection flag. Mysql::CLIENT_* ORed
  #   @option opts :charset [Mysql::Charset, String] character set
  #   @option opts :connect_timeout [Numeric, nil]
  #   @option opts :read_timeout [Numeric, nil]
  #   @option opts :write_timeout [Numeric, nil]
  #   @option opts :local_infile [Boolean]
  #   @option opts :load_data_local_dir [String]
  #   @option opts :ssl_mode [Integer]
  #   @option opts :ssl_context_params [Hash<Symbol, String>]
  #   @option opts :get_server_public_key [Boolean]
  #   @option opts :connect_attrs [Hash]
  #   @option opts :io [BasicSocket, OpenSSL::SSL::SSLSocket] Existing socket instance that will be used instead of creating a new socket
  def initialize(*args, **opts)
    @fields = nil
    @result = nil
    @protocol = nil
    @sqlstate = "00000"
    @host_info = nil
    @last_error = nil
    @opts = Mysql.default_options.dup
    parse_args(args, opts)
  end

  # Connect to mysqld.
  # parameter is same as arguments for {#initialize}.
  # @return [Mysql] self
  def connect(*args, **opts)
    parse_args(args, opts)
    if @opts[:flags] & CLIENT_COMPRESS != 0
      warn 'unsupported flag: CLIENT_COMPRESS' if $VERBOSE
      @opts[:flags] &= ~CLIENT_COMPRESS
    end
    @protocol = Protocol.new(@opts)
    @protocol.authenticate
    @host_info = (@opts[:host].nil? || @opts[:host] == "localhost") ? 'Localhost via UNIX socket' : "#{@opts[:host]} via TCP/IP"
    query @opts[:init_command] if @opts[:init_command]
    return self
  end

  def parse_args(args, opts)
    unless args.empty?
      case args[0]
      when URI
        uri = args[0]
      when /\Amysql:\/\//
        uri = URI.parse(args[0])
      when String, nil
        @opts[:host], user, passwd, dbname, port, socket, flags = *args
        @opts[:username] = user if user
        @opts[:password] = passwd if passwd
        @opts[:database] = dbname if dbname
        @opts[:port] = port if port
        @opts[:socket] = socket if socket
        @opts[:flags] = flags if flags
      when Hash
        # skip
      end
    end
    if uri
      host = uri.hostname.to_s
      host = URI.decode_www_form_component(host)
      if host.start_with?('/')
        @opts[:socket] = host
        host = ''
      end
      @opts[:host] = host
      @opts[:username] = URI.decode_www_form_component(uri.user.to_s)
      @opts[:password] = URI.decode_www_form_component(uri.password.to_s)
      @opts[:database] = uri.path.sub(/\A\/+/, '')
      @opts[:port] = uri.port
      opts = URI.decode_www_form(uri.query).to_h.transform_keys(&:intern).merge(opts) if uri.query
      opts[:flags] = opts[:flags].to_i if opts[:flags]
    end
    if args.last.kind_of? Hash
      opts = opts.merge(args.last)
    end
    @opts.update(opts)
  end

  DEFAULT_OPTS.each_key do |var|
    next if var == :charset
    define_method(var){@opts[var]}
    define_method("#{var}="){|val| @opts[var] = val}
  end

  # Disconnect from mysql.
  # @return [Mysql] self
  def close
    if @protocol
      @protocol.quit_command
      @protocol = nil
    end
    return self
  end

  # Disconnect from mysql without QUIT packet.
  # @return [Mysql] self
  def close!
    if @protocol
      @protocol.close
      @protocol = nil
    end
    return self
  end

  # Escape special character in MySQL.
  #
  # @param [String] str
  # return [String]
  def escape_string(str)
    self.class.escape_string str
  end
  alias quote escape_string

  # @return [Mysql::Charset] character set of MySQL connection
  def charset
    @opts[:charset]
  end

  # Set charset of MySQL connection.
  # @param [String, Mysql::Charset] cs
  def charset=(cs)
    charset = cs.is_a?(Charset) ? cs : Charset.by_name(cs)
    if @protocol
      @protocol.charset = charset
      query "SET NAMES #{charset.name}"
    end
    @opts[:charset] = charset
  end

  # @return [String] charset name
  def character_set_name
    @protocol.charset.name
  end

  # @return [Integer] last error number
  def errno
    @last_error ? @last_error.errno : 0
  end

  # @return [String] last error message
  def error
    @last_error&.error
  end

  # @return [String] sqlstate for last error
  def sqlstate
    @last_error ? @last_error.sqlstate : "00000"
  end

  # @return [Integer] number of columns for last query
  def field_count
    @fields.size
  end

  # @return [String] connection type
  def host_info
    @host_info
  end

  # @return [String] server version
  def server_info
    check_connection
    @protocol.server_info
  end

  # @return [Integer] server version
  def server_version
    @protocol&.server_version
  end

  # @return [String] information for last query
  def info
    @protocol&.message
  end

  # @return [Integer] number of affected records by insert/update/delete.
  def affected_rows
    @protocol ? @protocol.affected_rows : 0
  end

  # @return [Integer] latest auto_increment value
  def insert_id
    @protocol ? @protocol.insert_id : 0
  end

  # @return [Integer] number of warnings for previous query
  def warning_count
    @protocol ? @protocol.warning_count : 0
  end

  # Kill query.
  # @param [Integer] pid thread id
  # @return [Mysql] self
  def kill(pid)
    check_connection
    @protocol.kill_command pid
    self
  end

  # Execute query string.
  # @param str [String] Query.
  # @param return_result [Boolean]
  # @param yield_null_result [Boolean]
  # @return [Mysql::Result] if return_result is true and the query returns result set.
  # @return [nil] if return_result is true and the query does not return result set.
  # @return [self] if return_result is false or block is specified.
  # @example
  #  my.query("select 1,NULL,'abc'").fetch  # => [1, nil, "abc"]
  #  my.query("select 1,NULL,'abc'"){|res| res.fetch}
  def query(str, **opts, &block)
    opts = @opts.merge(opts)
    check_connection
    @fields = nil
    begin
      @protocol.query_command str
      if block
        while true
          @protocol.get_result
          res = store_result(**opts)
          block.call res if res || opts[:yield_null_result]
          break unless more_results?
        end
        return self
      end
      @protocol.get_result
      return self unless opts[:return_result]
      return store_result(**opts)
    rescue ServerError => e
      @last_error = e
      @sqlstate = e.sqlstate
      raise
    end
  end

  # Get all data for last query.
  # @return [Mysql::Result]
  # @return [nil] if no results
  def store_result(**opts)
    return nil if @protocol.field_count.nil? || @protocol.field_count == 0
    @fields = @protocol.retr_fields
    opts = @opts.merge(opts)
    @result = Result.new(@fields, @protocol, **opts)
  end

  # @return [Integer] Thread ID
  def thread_id
    check_connection
    @protocol.thread_id
  end

  # Set server option.
  # @param [Integer] opt {Mysql::OPTION_MULTI_STATEMENTS_ON} or {Mysql::OPTION_MULTI_STATEMENTS_OFF}
  # @return [Mysql] self
  def set_server_option(opt)
    check_connection
    @protocol.set_option_command opt
    self
  end

  # @return [Boolean] true if multiple queries are specified and unexecuted queries exists.
  def more_results?
    @protocol.more_results?
  end

  # execute next query if multiple queries are specified.
  # @return [Mysql::Result] result set of query if return_result is true.
  # @return [true] if return_result is false and result exists.
  # @return [nil] query returns no results.
  def next_result(**opts)
    return nil unless more_results?
    opts = @opts.merge(opts)
    @protocol.get_result
    @fields = nil
    return store_result(**opts) if opts[:return_result]
    true
  end

  # Parse prepared-statement.
  # @param [String] str query string
  # @return [Mysql::Stmt] Prepared-statement object
  def prepare(str, **opts)
    opts = @opts.merge(opts)
    st = Stmt.new(@protocol, **opts)
    st.prepare str
    st
  end

  # @private
  # Make empty prepared-statement object.
  # @return [Mysql::Stmt] If block is not specified.
  def stmt(**opts)
    opts = @opts.merge(opts)
    Stmt.new(@protocol, **opts)
  end

  # Check whether the  connection is available.
  # @return [Mysql] self
  def ping
    check_connection
    @protocol.ping_command
    self
  end

  # Flush tables or caches.
  # @param [Integer] op operation. Use Mysql::REFRESH_* value.
  # @return [Mysql] self
  def refresh(op)
    check_connection
    @protocol.refresh_command op
    self
  end

  # Reload grant tables.
  # @return [Mysql] self
  def reload
    refresh Mysql::REFRESH_GRANT
  end

  # Select default database
  # @return [Mysql] self
  def select_db(db)
    query "use #{db}"
    self
  end

  # shutdown server.
  # @return [Mysql] self
  def shutdown(level=0)
    check_connection
    @protocol.shutdown_command level
    self
  end

  # @return [String] statistics message
  def stat
    @protocol ? @protocol.statistics_command : 'MySQL server has gone away'
  end

  # Commit transaction
  # @return [Mysql] self
  def commit
    query 'commit'
    self
  end

  # Rollback transaction
  # @return [Mysql] self
  def rollback
    query 'rollback'
    self
  end

  # Set autocommit mode
  # @param [Boolean] flag
  # @return [Mysql] self
  def autocommit(flag)
    query "set autocommit=#{flag ? 1 : 0}"
    self
  end

  # session track
  # @return [Hash]
  def session_track
    @protocol.session_track
  end

  private

  def check_connection
    raise ClientError, 'MySQL client is not connected' unless @protocol
  end
end
