# coding: ascii-8bit

# Copyright (C) 2008 TOMITA Masahiro
# mailto:tommy@tmtm.org

require "socket"
require "stringio"
require "openssl"
require "bigdecimal"
require "date"
require 'time'
require_relative 'authenticator'

class Mysql
  # MySQL network protocol
  class Protocol
    VERSION = 10
    MAX_PACKET_LENGTH = 2**24-1

    # Convert netdata to Ruby value
    # @param data [Packet] packet data
    # @param type [Integer] field type
    # @param unsigned [true or false] true if value is unsigned
    # @return [Object] converted value.
    def self.net2value(pkt, type, unsigned)
      case type
      when Field::TYPE_STRING, Field::TYPE_VAR_STRING, Field::TYPE_BLOB, Field::TYPE_JSON, Field::TYPE_GEOMETRY
        return pkt.lcs
      when Field::TYPE_NEWDECIMAL
        s = pkt.lcs
        return s =~ /\./ && s !~ /\.0*\z/ ? BigDecimal(s) : s.to_i
      when Field::TYPE_TINY
        v = pkt.utiny
        return unsigned ? v : v < 128 ? v : v-256
      when Field::TYPE_SHORT
        v = pkt.ushort
        return unsigned ? v : v < 32768 ? v : v-65536
      when Field::TYPE_INT24, Field::TYPE_LONG
        v = pkt.ulong
        return unsigned ? v : v < 0x8000_0000 ? v : v-0x10000_0000
      when Field::TYPE_LONGLONG
        n1, n2 = pkt.ulong, pkt.ulong
        v = (n2 << 32) | n1
        return unsigned ? v : v < 0x8000_0000_0000_0000 ? v : v-0x10000_0000_0000_0000
      when Field::TYPE_FLOAT
        return pkt.read(4).unpack1('e')
      when Field::TYPE_DOUBLE
        return pkt.read(8).unpack1('E')
      when Field::TYPE_DATE
        len = pkt.utiny
        y, m, d = pkt.read(len).unpack("vCC")
        t = Date.new(y, m, d) rescue nil
        return t
      when Field::TYPE_DATETIME, Field::TYPE_TIMESTAMP
        len = pkt.utiny
        y, m, d, h, mi, s, sp = pkt.read(len).unpack("vCCCCCV")
        return Time.new(y, m, d, h, mi, Rational(s.to_i*1000000+sp.to_i, 1000000)) rescue nil
      when Field::TYPE_TIME
        len = pkt.utiny
        sign, d, h, mi, s, sp = pkt.read(len).unpack("CVCCCV")
        r = d.to_i*86400 + h.to_i*3600 + mi.to_i*60 + s.to_i + sp.to_f/1000000
        r *= -1 if sign != 0
        return r
      when Field::TYPE_YEAR
        return pkt.ushort
      when Field::TYPE_BIT
        return pkt.lcs
      else
        raise "not implemented: type=#{type}"
      end
    end

    # convert Ruby value to netdata
    # @param v [Object] Ruby value.
    # @return [Integer] type of column. Field::TYPE_*
    # @return [String] netdata
    # @raise [ProtocolError] value too large / value is not supported
    def self.value2net(v)
      v = v == true ? 1 : v == false ? 0 : v
      case v
      when nil
        type = Field::TYPE_NULL
        val = ""
      when Integer
        if -0x8000_0000 <= v && v < 0x8000_0000
          type = Field::TYPE_LONG
          val = [v].pack('V')
        elsif -0x8000_0000_0000_0000 <= v && v < 0x8000_0000_0000_0000
          type = Field::TYPE_LONGLONG
          val = [v&0xffffffff, v>>32].pack("VV")
        elsif 0x8000_0000_0000_0000 <= v && v <= 0xffff_ffff_ffff_ffff
          type = Field::TYPE_LONGLONG | 0x8000
          val = [v&0xffffffff, v>>32].pack("VV")
        else
          type =Field::TYPE_NEWDECIMAL
          val = Packet.lcs(v.to_s)
        end
      when BigDecimal
        type = Field::TYPE_NEWDECIMAL
        val = Packet.lcs(v.to_s)
      when Float
        type = Field::TYPE_DOUBLE
        val = [v].pack("E")
      when String
        type = Field::TYPE_STRING
        val = Packet.lcs(v)
      when Time
        type = Field::TYPE_DATETIME
        val = [11, v.year, v.month, v.day, v.hour, v.min, v.sec, v.usec].pack("CvCCCCCV")
      when DateTime
        type = Field::TYPE_DATETIME
        val = [11, v.year, v.month, v.day, v.hour, v.min, v.sec, (v.sec_fraction*1000000).to_i].pack("CvCCCCCV")
      when Date
        type = Field::TYPE_DATE
        val = [11, v.year, v.month, v.day, 0, 0, 0, 0].pack("CvCCCCCV")
      else
        raise ProtocolError, "class #{v.class} is not supported"
      end
      return type, val
    end

    attr_reader :server_info
    attr_reader :server_version
    attr_reader :thread_id
    attr_reader :client_flags
    attr_reader :sqlstate
    attr_reader :affected_rows
    attr_reader :insert_id
    attr_reader :server_status
    attr_reader :warning_count
    attr_reader :message
    attr_reader :session_track
    attr_reader :get_server_public_key
    attr_reader :field_count
    attr_accessor :charset

    # @state variable keep state for connection.
    # :INIT        :: Initial state.
    # :READY       :: Ready for command.
    # :WAIT_RESULT :: After query_command(). get_result() is needed.
    # :FIELD       :: After get_result(). retr_fields() is needed.
    # :RESULT      :: After retr_fields(), retr_all_records() is needed.
    # :CLOSED      :: Connection closed.

    # make socket connection to server.
    # @param opts [Hash]
    # @option :host [String] hostname mysqld running
    # @option :username [String] username to connect to mysqld
    # @option :password [String] password to connect to mysqld
    # @option :database [String] initial database name
    # @option :port [String] port number (used if host is not 'localhost' or nil)
    # @option :socket [String] socket filename (used if host is 'localhost' or nil)
    # @option :flags [Integer] connection flag. Mysql::CLIENT_* ORed
    # @option :charset [Mysql::Charset] character set
    # @option :connect_timeout [Numeric, nil]
    # @option :read_timeout [Numeric, nil]
    # @option :write_timeout [Numeric, nil]
    # @option :local_infile [Boolean]
    # @option :load_data_local_dir [String]
    # @option :ssl_mode [Integer]
    # @option :ssl_context_params [Hash<:Symbol, String>]
    # @option :get_server_public_key [Boolean]
    # @option :io [BasicSocket, OpenSSL::SSL::SSLSocket] Existing socket instance that will be used instead of creating a new socket
    # @raise [ClientError] connection timeout
    def initialize(opts)
      @mutex = Mutex.new
      @opts = opts
      @charset = Mysql::Charset.by_name("utf8mb4")
      @insert_id = 0
      @warning_count = 0
      @session_track = {}
      @gc_stmt_queue = []   # stmt id list which GC destroy.
      set_state :INIT
      @get_server_public_key = @opts[:get_server_public_key]
      begin
        if @opts[:io]
          @socket = @opts[:io]
        elsif @opts[:host].nil? or @opts[:host].empty? or @opts[:host] == "localhost"
          socket = @opts[:socket] || ENV["MYSQL_UNIX_PORT"] || MYSQL_UNIX_PORT
          @socket = Socket.unix(socket)
        else
          port = @opts[:port] || ENV["MYSQL_TCP_PORT"] || (Socket.getservbyname("mysql", "tcp") rescue MYSQL_TCP_PORT)
          @socket = Socket.tcp(@opts[:host], port, connect_timeout: @opts[:connect_timeout])
        end
      rescue Errno::ETIMEDOUT
        raise ClientError, "connection timeout"
      end
    end

    def close
      @socket.close rescue nil
    end

    # initial negotiate and authenticate.
    # @param charset [Mysql::Charset, nil] charset for connection. nil: use server's charset
    # @raise [ProtocolError] The old style password is not supported
    def authenticate
      synchronize(before: :INIT, after: :READY) do
        reset
        init_packet = InitialPacket.parse read
        @server_info = init_packet.server_version
        @server_version = init_packet.server_version.split(/\D/)[0, 3].inject{|a, b| a.to_i*100+b.to_i}
        @server_capabilities = init_packet.server_capabilities
        @thread_id = init_packet.thread_id
        @client_flags = CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_TRANSACTIONS | CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_MULTI_RESULTS | CLIENT_PS_MULTI_RESULTS | CLIENT_PLUGIN_AUTH | CLIENT_CONNECT_ATTRS | CLIENT_SESSION_TRACK | CLIENT_LOCAL_FILES
        @client_flags |= CLIENT_CONNECT_WITH_DB if @opts[:database]
        @client_flags |= @opts[:flags]
        if @opts[:charset]
          @charset = @opts[:charset].is_a?(Charset) ? @opts[:charset] : Charset.by_name(@opts[:charset])
        else
          @charset = Charset.by_number(init_packet.server_charset)
          @charset.encoding       # raise error if unsupported charset
        end
        enable_ssl
        Authenticator.new(self).authenticate(@opts[:username], @opts[:password].to_s, @opts[:database], init_packet.scramble_buff, init_packet.auth_plugin, @opts[:connect_attrs])
      end
    end

    SSL_MODE_KEY = {
      SSL_MODE_DISABLED        => 1,
      SSL_MODE_PREFERRED       => 2,
      SSL_MODE_REQUIRED        => 3,
      SSL_MODE_VERIFY_CA       => 4,
      SSL_MODE_VERIFY_IDENTITY => 5,
      '1'                      => 1,
      '2'                      => 2,
      '3'                      => 3,
      '4'                      => 4,
      '5'                      => 5,
      'disabled'               => 1,
      'preferred'              => 2,
      'required'               => 3,
      'verify_ca'              => 4,
      'verify_identity'        => 5,
      :disabled                => 1,
      :preferred               => 2,
      :required                => 3,
      :verify_ca               => 4,
      :verify_identity         => 5,
    }.freeze

    def enable_ssl
      ssl_mode = SSL_MODE_KEY[@opts[:ssl_mode]]
      raise ClientError, "ssl_mode #{@opts[:ssl_mode]} is not supported" unless ssl_mode

      return if ssl_mode == SSL_MODE_DISABLED
      if ssl_mode == SSL_MODE_PREFERRED
        return if @socket.local_address.unix?
        return if @server_capabilities & CLIENT_SSL == 0
      end
      if ssl_mode >= SSL_MODE_REQUIRED && @server_capabilities & CLIENT_SSL == 0
        raise ClientError::SslConnectionError, "SSL is required but the server doesn't support it"
      end

      context = OpenSSL::SSL::SSLContext.new
      context.set_params(@opts[:ssl_context_params])
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE if ssl_mode < SSL_MODE_VERIFY_CA
      context.verify_hostname = false if ssl_mode < SSL_MODE_VERIFY_IDENTITY

      ssl_socket = OpenSSL::SSL::SSLSocket.new(@socket, context)
      ssl_socket.sync_close = true
      ssl_socket.hostname = @opts[:host] if ssl_mode >= SSL_MODE_VERIFY_IDENTITY

      @client_flags |= CLIENT_SSL
      write Protocol::TlsAuthenticationPacket.serialize(@client_flags, 1024**3, @charset.number)

      ssl_socket.connect
      @socket = ssl_socket
    rescue OpenSSL::SSL::SSLError => e
      @client_flags &= ~CLIENT_SSL
      return if @opts[:ssl_mode] < SSL_MODE_REQUIRED
      raise e
    end

    def ssl_cipher
      @client_flags.allbits?(CLIENT_SSL) ? @socket.cipher : nil
    end

    # Quit command
    def quit_command
      get_result if @state == :WAIT_RESULT
      retr_fields if @state == :FIELD
      retr_all_records(RawRecord) if @state == :RESULT
      synchronize(before: :READY, after: :CLOSED) do
        reset
        write [COM_QUIT].pack("C")
        close
        @gc_stmt_queue.clear
      end
    end

    # Query command
    # @param query [String] query string
    def query_command(query)
      synchronize(before: :READY, after: :WAIT_RESULT, error: :READY) do
        reset
        write [COM_QUERY, @charset.convert(query)].pack("Ca*")
      end
    end

    # get result of query.
    # @return [integer, nil] number of fields of results. nil if no results.
    def get_result
      synchronize(before: :WAIT_RESULT, error: :READY) do
        res_packet = ResultPacket.parse read
        @field_count = res_packet.field_count
        if @field_count.to_i > 0  # result data exists
          set_state :FIELD
          return @field_count
        end
        if @field_count.nil?      # LOAD DATA LOCAL INFILE
          send_local_file(res_packet.message)
          res_packet = ResultPacket.parse read
        end
        @affected_rows, @insert_id, @server_status, @warning_count, @message, @session_track =
          res_packet.affected_rows, res_packet.insert_id, res_packet.server_status, res_packet.warning_count, res_packet.message, res_packet.session_track
        set_state :READY unless more_results?
        return nil
      end
    end

    def more_results?
      @server_status & SERVER_MORE_RESULTS_EXISTS != 0
    end

    # send local file to server
    def send_local_file(filename)
      filename = File.absolute_path(filename)
      if @opts[:local_infile] || @opts[:load_data_local_dir] && filename.start_with?(@opts[:load_data_local_dir])
        File.open(filename){|f| write f}
        write nil  # EOF
      else
        write nil  # send empty data instead of file contents
        read       # result packet
        raise ClientError::LoadDataLocalInfileRejected, 'LOAD DATA LOCAL INFILE file request rejected due to restrictions on access.'
      end
    end

    # Retrieve n fields
    # @return [Array<Mysql::Field>] field list
    def retr_fields
      synchronize(before: :FIELD, after: :RESULT, error: :READY) do
        @fields = @field_count.times.map{Field.new FieldPacket.parse(read)}
        read_eof_packet
        @no_more_records = false
        @fields
      end
    end

    # Retrieve one record for simple query or prepared statement
    # @param record_class [RawRecord or StmtRawRecord]
    # @return [<record_class>] record
    # @return [nil] no more record
    def retr_record(record_class)
      return nil if @no_more_records
      synchronize(before: :RESULT) do
        enc = charset.encoding
        begin
          unless (pkt = read).eof?
            return record_class.new(pkt, @fields, enc)
          end
          pkt.utiny
          pkt.ushort
          @server_status = pkt.ushort
          set_state(more_results? ? :WAIT_RESULT : :READY)
          @no_more_records = true
          return nil
        end
      end
    end

    # Retrieve all records for simple query or prepared statement
    # @param record_class [RawRecord or StmtRawRecord]
    # @return [Array<record_class>] all records
    def retr_all_records(record_class)
      synchronize(before: :RESULT) do
        enc = charset.encoding
        begin
          all_recs = []
          until (pkt = read).eof?
            all_recs.push record_class.new(pkt, @fields, enc)
          end
          pkt.utiny  # 0xFE
          _warnings = pkt.ushort
          @server_status = pkt.ushort
          @no_more_records = true
          all_recs
        ensure
          set_state(more_results? ? :WAIT_RESULT : :READY)
        end
      end
    end

    # Ping command
    def ping_command
      simple_command [COM_PING].pack("C")
    end

    # Kill command
    def kill_command(pid)
      simple_command [COM_PROCESS_KILL, pid].pack("CV")
    end

    # Refresh command
    def refresh_command(op)
      simple_command [COM_REFRESH, op].pack("CC")
    end

    # Set option command
    def set_option_command(opt)
      simple_command [COM_SET_OPTION, opt].pack("Cv")
    end

    # Shutdown command
    def shutdown_command(level)
      simple_command [COM_SHUTDOWN, level].pack("CC")
    end

    # Statistics command
    def statistics_command
      simple_command [COM_STATISTICS].pack("C")
    end

    # Stmt prepare command
    # @param stmt [String] prepared statement
    # @return [Array<Integer, Integer, Array<Field>>] statement id, number of parameters, field list
    def stmt_prepare_command(stmt)
      synchronize(before: :READY, after: :READY) do
        reset
        write [COM_STMT_PREPARE, charset.convert(stmt)].pack("Ca*")
        res_packet = PrepareResultPacket.parse read
        if res_packet.param_count > 0
          res_packet.param_count.times{read}    # skip parameter packet
          read_eof_packet
        end
        if res_packet.field_count > 0
          fields = res_packet.field_count.times.map{Field.new FieldPacket.parse(read)}
          read_eof_packet
        else
          fields = []
        end
        return res_packet.statement_id, res_packet.param_count, fields
      end
    end

    # Stmt execute command
    # @param stmt_id [Integer] statement id
    # @param values [Array] parameters
    # @return [Integer] number of fields
    def stmt_execute_command(stmt_id, values)
      synchronize(before: :READY, after: :WAIT_RESULT, error: :READY) do
        reset
        write ExecutePacket.serialize(stmt_id, Mysql::Stmt::CURSOR_TYPE_NO_CURSOR, values)
      end
    end

    # Stmt close command
    # @param stmt_id [Integer] statement id
    def stmt_close_command(stmt_id)
      get_result if @state == :WAIT_RESULT
      retr_fields if @state == :FIELD
      retr_all_records(StmtRawRecord) if @state == :RESULT
      synchronize(before: :READY, after: :READY) do
        reset
        write [COM_STMT_CLOSE, stmt_id].pack("CV")
        @gc_stmt_queue.delete stmt_id
      end
    end

    def gc_stmt(stmt_id)
      @gc_stmt_queue.push stmt_id
    end

    def check_state(st)
      raise Mysql::ClientError::CommandsOutOfSync, 'command out of sync' unless @state == st
    end

    def set_state(st)
      @state = st
      return if st != :READY || @gc_stmt_queue.empty? || @socket&.closed?
      gc_disabled = GC.disable
      begin
        while (st = @gc_stmt_queue.shift)
          reset
          write [COM_STMT_CLOSE, st].pack("CV")
        end
      ensure
        GC.enable unless gc_disabled
      end
    end

    def synchronize(before: nil, after: nil, error: nil)
      @mutex.synchronize do
        check_state before if before
        begin
          return yield
        rescue
          set_state error if error
          raised = true
          raise
        ensure
          set_state after if after && !raised
        end
      end
    end

    # Reset sequence number
    def reset
      @seq = 0    # packet counter. reset by each command
    end

    # Read one packet data
    # @return [Packet] packet data
    # @rails [ProtocolError] invalid packet sequence number
    def read
      data = ''
      len = nil
      begin
        timeout = @state == :INIT ? @opts[:connect_timeout] : @opts[:read_timeout]
        header = read_timeout(4, timeout)
        raise EOFError unless header && header.length == 4
        len1, len2, seq = header.unpack("CvC")
        len = (len2 << 8) + len1
        raise ProtocolError, "invalid packet: sequence number mismatch(#{seq} != #{@seq}(expected))" if @seq != seq
        @seq = (@seq + 1) % 256
        ret = read_timeout(len, timeout)
        raise EOFError unless ret && ret.length == len
        data.concat ret
      rescue EOFError, OpenSSL::SSL::SSLError
        close
        raise ClientError::ServerLost, 'Lost connection to server during query'
      rescue Errno::ETIMEDOUT
        raise ClientError, "read timeout"
      end while len == MAX_PACKET_LENGTH

      @sqlstate = "00000"

      # Error packet
      if data[0] == ?\xff
        _, errno, marker, @sqlstate, message = data.unpack("Cvaa5a*")
        unless marker == "#"
          _, errno, message = data.unpack("Cva*")    # Version 4.0 Error
          @sqlstate = ""
        end
        @server_status &= ~SERVER_MORE_RESULTS_EXISTS
        message.force_encoding(@charset.encoding)
        if Mysql::ServerError::ERROR_MAP.key? errno
          raise Mysql::ServerError::ERROR_MAP[errno].new(message, @sqlstate)
        end
        raise Mysql::ServerError.new(message, @sqlstate, errno)
      end
      Packet.new(data)
    end

    def read_timeout(len, timeout)
      return @socket.read(len) if timeout.nil? || timeout == 0
      result = ''
      e = Time.now + timeout
      while result.size < len
        now = Time.now
        raise Errno::ETIMEDOUT if now > e
        r = @socket.read_nonblock(len - result.size, exception: false)
        case r
        when :wait_readable
          IO.select([@socket], nil, nil, e - now)  # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
          next
        when :wait_writable
          IO.select(nil, [@socket], nil, e - now)  # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
          next
        else
          result << r
        end
      end
      return result
    end

    # Write one packet data
    # @param data [String, IO, nil] packet data. If data is nil, write empty packet.
    def write(data)
      timeout = @state == :INIT ? @opts[:connect_timeout] : @opts[:write_timeout]
      @socket.sync = false
      if data.nil?
        write_timeout([0, 0, @seq].pack("CvC"), timeout)
        @seq = (@seq + 1) % 256
      else
        data = StringIO.new data if data.is_a? String
        while (d = data.read(MAX_PACKET_LENGTH))
          write_timeout([d.length%256, d.length/256, @seq].pack("CvC")+d, timeout)
          @seq = (@seq + 1) % 256
        end
      end
      @socket.sync = true
      @socket.flush
    rescue Errno::EPIPE, OpenSSL::SSL::SSLError
      close
      raise ClientError::ServerGoneError, 'MySQL server has gone away'
    rescue Errno::ETIMEDOUT
      raise ClientError, "write timeout"
    end

    def write_timeout(data, timeout)
      return @socket.write(data) if timeout.nil? || timeout == 0
      len = 0
      e = Time.now + timeout
      while len < data.size
        now = Time.now
        raise Errno::ETIMEDOUT if now > e
        l = @socket.write_nonblock(data[len..], exception: false)
        case l
        when :wait_readable
          IO.select([@socket], nil, nil, e - now)  # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
        when :wait_writable
          IO.select(nil, [@socket], nil, e - now)  # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
        else
          len += l
        end
      end
      return len
    end

    # Read EOF packet
    # @raise [ProtocolError] packet is not EOF
    def read_eof_packet
      pkt = read
      raise ProtocolError, "packet is not EOF" unless pkt.eof?
      pkt.utiny  # 0xFE
      _warnings = pkt.ushort
      @server_status = pkt.ushort
    end

    # Send simple command
    # @param packet :: [String] packet data
    # @return [String] received data
    def simple_command(packet)
      synchronize(before: :READY, after: :READY) do
        reset
        write packet
        read.to_s
      end
    end

    # Initial packet
    class InitialPacket
      def self.parse(pkt)
        protocol_version = pkt.utiny
        server_version = pkt.string
        thread_id = pkt.ulong
        scramble_buff = pkt.read(8)
        f0 = pkt.utiny
        server_capabilities = pkt.ushort
        server_charset = pkt.utiny
        server_status = pkt.ushort
        server_capabilities2 = pkt.ushort
        scramble_length = pkt.utiny
        _f1 = pkt.read(10)
        rest_scramble_buff = pkt.string
        auth_plugin = pkt.string

        server_capabilities |= server_capabilities2 << 16
        scramble_buff.concat rest_scramble_buff

        raise ProtocolError, "unsupported version: #{protocol_version}" unless protocol_version == VERSION
        raise ProtocolError, "invalid packet: f0=#{f0}" unless f0 == 0
        raise ProtocolError, "invalid packet: scramble_length(#{scramble_length}) != length of scramble(#{scramble_buff.size + 1})" unless scramble_length == scramble_buff.size + 1

        self.new protocol_version, server_version, thread_id, server_capabilities, server_charset, server_status, scramble_buff, auth_plugin
      end

      attr_reader :protocol_version, :server_version, :thread_id, :server_capabilities, :server_charset, :server_status, :scramble_buff, :auth_plugin

      def initialize(*args)
        @protocol_version, @server_version, @thread_id, @server_capabilities, @server_charset, @server_status, @scramble_buff, @auth_plugin = args
      end
    end

    # Result packet
    class ResultPacket
      def self.parse(pkt)
        field_count = pkt.lcb
        if field_count == 0
          affected_rows = pkt.lcb
          insert_id = pkt.lcb
          server_status = pkt.ushort
          warning_count = pkt.ushort
          message = pkt.lcs
          session_track = parse_session_track(pkt.lcs) if server_status & SERVER_SESSION_STATE_CHANGED
          message = pkt.lcs unless pkt.to_s.empty?

          return self.new(field_count, affected_rows, insert_id, server_status, warning_count, message, session_track)
        elsif field_count.nil?   # LOAD DATA LOCAL INFILE
          return self.new(nil, nil, nil, nil, nil, pkt.to_s)
        else
          return self.new(field_count)
        end
      end

      def self.parse_session_track(data)
        session_track = {}
        pkt = Packet.new(data.to_s)
        until pkt.to_s.empty?
          type = pkt.lcb
          session_track[type] ||= []
          case type
          when SESSION_TRACK_SYSTEM_VARIABLES
            p = Packet.new(pkt.lcs)
            session_track[type].push [p.lcs, p.lcs]
          when SESSION_TRACK_SCHEMA
            pkt.lcb  # skip
            session_track[type].push pkt.lcs
          when SESSION_TRACK_STATE_CHANGE
            session_track[type].push pkt.lcs
          when SESSION_TRACK_GTIDS
            pkt.lcb  # skip
            pkt.lcb  # skip
            session_track[type].push pkt.lcs
          when SESSION_TRACK_TRANSACTION_CHARACTERISTICS, SESSION_TRACK_TRANSACTION_STATE
            pkt.lcb  # skip
            session_track[type].push pkt.lcs
          end
        end
        session_track
      end

      attr_reader :field_count, :affected_rows, :insert_id, :server_status, :warning_count, :message, :session_track

      def initialize(*args)
        @field_count, @affected_rows, @insert_id, @server_status, @warning_count, @message, @session_track = args
        @session_track ||= {}
      end
    end

    # Field packet
    class FieldPacket
      def self.parse(pkt)
        _first = pkt.lcs
        db = pkt.lcs
        table = pkt.lcs
        org_table = pkt.lcs
        name = pkt.lcs
        org_name = pkt.lcs
        _f0 = pkt.utiny
        charsetnr = pkt.ushort
        length = pkt.ulong
        type = pkt.utiny
        flags = pkt.ushort
        decimals = pkt.utiny
        f1 = pkt.ushort

        raise ProtocolError, "invalid packet: f1=#{f1}" unless f1 == 0
        default = pkt.lcs
        return self.new(db, table, org_table, name, org_name, charsetnr, length, type, flags, decimals, default)
      end

      attr_reader :db, :table, :org_table, :name, :org_name, :charsetnr, :length, :type, :flags, :decimals, :default

      def initialize(*args)
        @db, @table, @org_table, @name, @org_name, @charsetnr, @length, @type, @flags, @decimals, @default = args
      end
    end

    # Prepare result packet
    class PrepareResultPacket
      def self.parse(pkt)
        raise ProtocolError, "invalid packet" unless pkt.utiny == 0
        statement_id = pkt.ulong
        field_count = pkt.ushort
        param_count = pkt.ushort
        f = pkt.utiny
        warning_count = pkt.ushort
        raise ProtocolError, "invalid packet" unless f == 0x00
        self.new statement_id, field_count, param_count, warning_count
      end

      attr_reader :statement_id, :field_count, :param_count, :warning_count

      def initialize(*args)
        @statement_id, @field_count, @param_count, @warning_count = args
      end
    end

    # Authentication packet
    class AuthenticationPacket
      def self.serialize(client_flags, max_packet_size, charset_number, username, scrambled_password, databasename, auth_plugin, connect_attrs)
        data = [
          client_flags,
          max_packet_size,
          charset_number,
          "",                   # always 0x00 * 23
          username,
          Packet.lcs(scrambled_password),
        ]
        pack = "VVCa23Z*A*"
        if databasename
          data.push databasename
          pack.concat "Z*"
        end
        data.push auth_plugin
        pack.concat "Z*"
        attr = connect_attrs.map{|k, v| [Packet.lcs(k.to_s), Packet.lcs(v.to_s)]}.flatten.join
        data.pack(pack) + Packet.lcb(attr.size)+attr
      end
    end

    # TLS Authentication packet
    class TlsAuthenticationPacket
      def self.serialize(client_flags, max_packet_size, charset_number)
        [
          client_flags,
          max_packet_size,
          charset_number,
          "",                   # always 0x00 * 23
        ].pack("VVCa23")
      end
    end

    # Execute packet
    class ExecutePacket
      def self.serialize(statement_id, cursor_type, values)
        nbm = null_bitmap values
        netvalues = ""
        types = values.map do |v|
          t, n = Protocol.value2net v
          netvalues.concat n unless v.nil?
          t
        end
        [Mysql::COM_STMT_EXECUTE, statement_id, cursor_type, 1, nbm, 1, types.pack("v*"), netvalues].pack("CVCVa*Ca*a*")
      end

      # make null bitmap
      #
      # If values is [1, nil, 2, 3, nil] then returns "\x12"(0b10010).
      def self.null_bitmap(values)
        bitmap = values.enum_for(:each_slice, 8).map do |vals|
          vals.reverse.inject(0){|b, v| (b << 1 | (v.nil? ? 1 : 0))}
        end
        return bitmap.pack("C*")
      end
    end

    # Authentication result packet
    class AuthenticationResultPacket
      def self.parse(pkt)
        result = pkt.utiny
        auth_plugin = pkt.string
        scramble = pkt.string
        self.new(result, auth_plugin, scramble)
      end

      attr_reader :result, :auth_plugin, :scramble

      def initialize(*args)
        @result, @auth_plugin, @scramble = args
      end
    end
  end

  # raw record
  class RawRecord
    def initialize(packet, fields, encoding)
      @packet, @fields, @encoding = packet, fields, encoding
    end

    def to_a
      @fields.map do |f|
        s = @packet.lcs
        if s.nil?
          nil
        elsif f.type == Field::TYPE_BIT or f.charsetnr == Charset::BINARY_CHARSET_NUMBER
          s.b
        else
          Charset.convert_encoding(s, @encoding)
        end
      end
    end
  end

  # prepared statement raw record
  class StmtRawRecord
    # @param pkt [Packet]
    # @param fields [Array of Fields]
    # @param encoding [Encoding]
    def initialize(packet, fields, encoding)
      @packet, @fields, @encoding = packet, fields, encoding
    end

    # Parse statement result packet
    # @return [Array<Object>] one record
    def parse_record_packet
      @packet.utiny  # skip first byte
      null_bit_map = @packet.read((@fields.length+7+2)/8).unpack1("b*")
      rec = @fields.each_with_index.map do |f, i|
        if null_bit_map[i+2] == '1'
          nil
        else
          unsigned = f.flags & Field::UNSIGNED_FLAG != 0
          v = Protocol.net2value(@packet, f.type, unsigned)
          if v.nil? or v.is_a? Numeric or v.is_a? Time or v.is_a? Date
            v
          elsif f.type == Field::TYPE_BIT
            Charset.to_binary(v)
          elsif v.is_a? String
            f.charsetnr == Charset::BINARY_CHARSET_NUMBER ? Charset.to_binary(v) : Charset.convert_encoding(v, @encoding)
          else
            v
          end
        end
      end
      rec
    end

    alias to_a parse_record_packet
  end
end
