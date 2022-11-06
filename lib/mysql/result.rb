class Mysql
  # @!visibility public
  # Result set
  class ResultBase
    include Enumerable

    # @return [Array<Mysql::Field>] field list
    attr_reader :fields
    alias fetch_fields fields

    # @return [Mysql::StatementResult]
    attr_reader :result

    # @param [Array of Mysql::Field] fields
    def initialize(fields, protocol, record_class, **opts)
      @fields = fields
      @field_index = 0             # index of field
      @records = []                # all records
      @index = 0                   # index of record
      @fieldname_with_table = nil
      @protocol = protocol
      @record_class = record_class
      @opts = opts
    end

    def retrieve
      @records = @protocol.retr_all_records(@record_class)
    end

    # ignore
    # @return [void]
    def free
      # dummy
    end

    # @return [Integer] number of record
    def size
      @records.size
    end
    alias num_rows size

    # @return [Array] current record data
    def fetch(**)
      if @index < @records.size
        @records[@index] = @records[@index].to_a unless @records[@index].is_a? Array
        @index += 1
        return @records[@index-1]
      end
      rec = @protocol.retr_record(@record_class)&.to_a
      return nil unless rec
      @records[@index] = rec
      @index += 1
      return rec
    end
    alias fetch_row fetch

    # Return data of current record as Hash.
    # The hash key is field name.
    # @param [Boolean] with_table if true, hash key is "table_name.field_name".
    # @return [Hash] current record data
    def fetch_hash(**opts)
      row = fetch(**opts)
      return nil unless row
      with_table = @opts.merge(opts).fetch(:with_table, false)
      if with_table and @fieldname_with_table.nil?
        @fieldname_with_table = @fields.map{|f| [f.table, f.name].join(".")}
      end
      ret = {}
      @fields.each_index do |i|
        fname = with_table ? @fieldname_with_table[i] : @fields[i].name
        ret[fname] = row[i]
      end
      ret
    end

    # Iterate block with record.
    # @yield [Array] record data
    # @return [self] self. If block is not specified, this returns Enumerator.
    def each(**opts, &block)
      @index = 0
      return enum_for(:each, **opts) unless block
      while (rec = fetch(**opts))
        block.call rec
      end
      self
    end

    # Iterate block with record as Hash.
    # @param [Boolean] with_table if true, hash key is "table_name.field_name".
    # @yield [Hash] record data
    # @return [self] self. If block is not specified, this returns Enumerator.
    def each_hash(**opts, &block)
      @index = 0
      return enum_for(:each_hash, **opts) unless block
      while (rec = fetch_hash(**opts))
        block.call rec
      end
      self
    end

    # Set record position
    # @param [Integer] n record index
    # @return [self] self
    def data_seek(n)
      @index = n
      self
    end

    # @return [Integer] current record position
    def row_tell
      @index
    end

    # Set current position of record
    # @param [Integer] n record index
    # @return [Integer] previous position
    def row_seek(n)
      ret = @index
      @index = n
      ret
    end

    # Server status value
    # @return [Integer] server status value
    def server_status
      @protocol.server_status
    end
  end

  # @!visibility public
  # Result set for simple query
  class Result < ResultBase
    # @private
    # @param [Array<Mysql::Field>] fields
    # @param [Mysql::Protocol] protocol
    # @param [Boolean] bulk_retrieve
    def initialize(fields, protocol=nil, **opts)
      super fields, protocol, RawRecord, **opts
      return unless protocol
      fields.each{|f| f.result = self}  # for calculating max_field
      retrieve if @opts.merge(opts).fetch(:bulk_retrieve, true)
    end

    # @private
    # calculate max_length of all fields
    def calculate_field_max_length
      return unless @records
      max_length = Array.new(@fields.size, 0)
      @records.each_with_index do |rec, i|
        rec = @records[i] = rec.to_a if rec.is_a? RawRecord
        max_length.each_index do |j|
          max_length[j] = rec[j].to_s.length if rec[j] && rec[j].to_s.length > max_length[j]
        end
      end
      max_length.each_with_index do |len, i|
        @fields[i].max_length = len
      end
    end
  end

  # @!visibility private
  # Result set for prepared statement
  class StatementResult < ResultBase
    # @private
    # @param [Array<Mysql::Field>] fields
    # @param [Mysql::Protocol] protocol
    def initialize(fields, protocol, **opts)
      super fields, protocol, StmtRawRecord, **opts
      retrieve if @opts.merge(opts).fetch(:bulk_retrieve, true)
    end
  end
end
