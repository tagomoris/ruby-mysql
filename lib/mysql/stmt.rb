class Mysql
  # @!visibility public
  # Prepared statement
  # @!attribute [r] affected_rows
  #   @return [Integer]
  # @!attribute [r] insert_id
  #   @return [Integer]
  # @!attribute [r] server_status
  #   @return [Integer]
  # @!attribute [r] warning_count
  #   @return [Integer]
  # @!attribute [r] param_count
  #   @return [Integer]
  # @!attribute [r] fields
  #   @return [Array<Mysql::Field>]
  # @!attribute [r] sqlstate
  #   @return [String]
  class Stmt
    include Enumerable

    attr_reader :affected_rows, :info, :insert_id, :server_status, :warning_count
    attr_reader :param_count, :fields, :sqlstate

    # @private
    def self.finalizer(protocol, statement_id)
      proc do
        protocol.gc_stmt statement_id
      end
    end

    # @private
    # @param [Mysql::Protocol] protocol
    def initialize(protocol, **opts)
      @protocol = protocol
      @opts = opts
      @statement_id = nil
      @affected_rows = @insert_id = @server_status = @warning_count = 0
      @sqlstate = "00000"
      @param_count = nil
    end

    # @private
    # parse prepared-statement and return {Mysql::Stmt} object
    # @param [String] str query string
    # @return self
    def prepare(str)
      raise ClientError, 'MySQL client is not connected' unless @protocol
      close
      begin
        @sqlstate = "00000"
        @statement_id, @param_count, @fields = @protocol.stmt_prepare_command(str)
      rescue ServerError => e
        @last_error = e
        @sqlstate = e.sqlstate
        raise
      end
      ObjectSpace.define_finalizer(self, self.class.finalizer(@protocol, @statement_id))
      self
    end

    # Execute prepared statement.
    # @param [Object] values values passed to query
    # @return [Mysql::Result] if return_result is true and the query returns result set.
    # @return [nil] if return_result is true and the query does not return result set.
    # @return [self] if return_result is false or block is specified.
    def execute(*values, **opts, &block)
      raise ClientError, "Invalid statement handle" unless @statement_id
      raise ClientError, "not prepared" unless @param_count
      raise ClientError, "parameter count mismatch" if values.length != @param_count
      values = values.map{|v| @protocol.charset.convert v}
      opts = @opts.merge(opts)
      begin
        @sqlstate = "00000"
        @protocol.stmt_execute_command @statement_id, values
        @fields = @result = nil
        if block
          while true
            get_result
            res = store_result(**opts)
            block.call res if res || opts[:yield_null_result]
            break unless more_results?
          end
          return self
        end
        get_result
        return self unless opts[:return_result]
        return store_result(**opts)
      rescue ServerError => e
        @last_error = e
        @sqlstate = e.sqlstate
        raise
      end
    end

    def get_result
      @protocol.get_result
      @affected_rows, @insert_id, @server_status, @warning_count, @info =
        @protocol.affected_rows, @protocol.insert_id, @protocol.server_status, @protocol.warning_count, @protocol.message
    end

    def store_result(**opts)
      return nil if @protocol.field_count.nil? || @protocol.field_count == 0
      @fields = @protocol.retr_fields
      opts = @opts.merge(opts)
      @result = StatementResult.new(@fields, @protocol, **opts)
    end

    def more_results?
      @protocol.more_results?
    end

    # execute next query if precedure is called.
    # @return [Mysql::StatementResult] result set of query if return_result is true.
    # @return [true] if return_result is false and result exists.
    # @return [nil] query returns no results or no more results.
    def next_result(**opts)
      return nil unless more_results?
      opts = @opts.merge(opts)
      @fields = @result = nil
      get_result
      return self unless opts[:return_result]
      return store_result(**opts)
    rescue ServerError => e
      @last_error = e
      @sqlstate = e.sqlstate
      raise
    end

    # Close prepared statement
    # @return [void]
    def close
      ObjectSpace.undefine_finalizer(self)
      @protocol.stmt_close_command @statement_id if @statement_id
      @statement_id = nil
    end

    # @return [Array] current record data
    def fetch(**opts)
      @result.fetch(**opts)
    end

    # Return data of current record as Hash.
    # The hash key is field name.
    # @param [Boolean] with_table if true, hash key is "table_name.field_name".
    # @return [Hash] record data
    def fetch_hash(**opts)
      @result.fetch_hash(**opts)
    end

    # Iterate block with record.
    # @yield [Array] record data
    # @return [Mysql::Stmt] self
    # @return [Enumerator] If block is not specified
    def each(**opts, &block)
      return enum_for(:each, **opts) unless block
      while (rec = fetch(*opts))
        block.call rec
      end
      self
    end

    # Iterate block with record as Hash.
    # @param [Boolean] with_table if true, hash key is "table_name.field_name".
    # @yield [Hash] record data
    # @return [Mysql::Stmt] self
    # @return [Enumerator] If block is not specified
    def each_hash(**opts, &block)
      return enum_for(:each_hash, **opts) unless block
      while (rec = fetch_hash(**opts))
        block.call rec
      end
      self
    end

    # @return [Integer] number of record
    def size
      @result.size
    end
    alias num_rows size

    # Set record position
    # @param [Integer] n record index
    # @return [void]
    def data_seek(n)
      @result.data_seek(n)
    end

    # @return [Integer] current record position
    def row_tell
      @result.row_tell
    end

    # Set current position of record
    # @param [Integer] n record index
    # @return [Integer] previous position
    def row_seek(n)
      @result.row_seek(n)
    end

    # @return [Integer] number of columns for last query
    def field_count
      @fields.length
    end

    # ignore
    # @return [void]
    def free_result
      # dummy
    end

    # Returns Mysql::Result object that is empty.
    # Use fields to get list of fields.
    # @return [Mysql::Result]
    def result_metadata
      return nil if @fields.empty?
      Result.new @fields
    end
  end
end
