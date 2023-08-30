require 'spec_helper'

describe Mysql::Protocol do
  describe '.new' do
    before{ FileUtils.touch MYSQL_SOCKET }

    it 'uses the object provided as the `:io` option' do
      socket = Object.new
      protocol = described_class.new(host: 'localhost', io: socket)
      assert{ protocol.instance_variable_get(:@socket) == socket }
    end
  end
end
