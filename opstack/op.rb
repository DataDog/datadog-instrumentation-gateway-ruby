require 'json'
require 'stringio'

class Operation
  CURRENT_OPERATION = :current_operation

  attr_reader :name
  attr_reader :parent

  def initialize(name, parent = nil)
    @name = name
    @parent = parent || Operation.current
    @listeners = {
      start: {},
      finish: [],
      data: [],
    }

    if block_given?
      start
      yield self
    end
  ensure
    finalize if block_given?
  end

  def start
    Thread.current[CURRENT_OPERATION] = self
  end

  def finish
    Thread.current[CURRENT_OPERATION] = parent
  end

  def on_start(event, &block)
    (@listeners[:start][event] ||= []) << block
  end

  def on_finish(&block)
    (@listeners[:finish] ||= []) << block
  end

  def on_data(&block)
    @listeners[:data] << block
  end

  def start_event_listeners(event)
    parent_listeners = parent.start_event_listeners(event) if parent
    parent_listeners ||= []
    (@listeners[:start][event] ||= []) + parent_listeners
  end

  def finish_event_listeners
    @listeners[:finish] ||= []
  end

  def data_event_listeners
    parent_listeners = parent.data_event_listeners if parent
    parent_listeners ||= []
    (@listeners[:data] ||= []) + parent_listeners
  end

  def emit_start(event, *args)
    listeners = start_event_listeners(event)

    listeners.each { |l| l.call(self, *args) } if listeners.any?
  end

  def emit_finish(*args)
    listeners = finish_event_listeners

    listeners.each { |l| l.call(self, *args) } if listeners.any?
  end

  def emit_data(data)
    listeners = data_event_listeners

    listeners.each { |l| l.call(self, data) } if listeners.any?
  end

  class << self
    def current
      Thread.current[CURRENT_OPERATION]
    end
  end
end

class ParsedHTTPBody
  attr_reader :data

  def initialize(data)
    @data = data
  end
end

class RawHTTPBody
  attr_reader :data

  def initialize(data)
    @data = data
  end
end

module WAF
  class Context
    def initialize
      @data = {}
    end

    def add(key, value)
      @data[key] = value
    end

    def run
      @data.each { |k, v| puts "run has: #{k}: #{v.inspect}"}
    end
  end
end

root = Operation.new('root')
root.start

# JSON body
root.on_start(:http_request) do |op|
  op.on_start(:json_parse) do |op|
    did_read = false

    op.on_finish do |op, data|
      if did_read
        op.emit_data(ParsedHTTPBody.new(data))
      end
    end

    op.on_start(:read_body) do |op|
      did_read = true
    end
  end
end

# raw body
root.on_start(:http_request) do |op|
  raw = ''

  op.on_start(:read_body) do |op|
    op.on_finish do |op, buf|
      if buf.nil?
        op.emit_data(RawHTTPBody.new(raw))
      else
        raw << buf
      end
    end
  end
end

# waf
root.on_start(:http_request) do |op|
  waf_ctx = WAF::Context.new

  op.on_data do |op, obj|
    case obj
    when RawHTTPBody
      waf_ctx.add('http.request.body.raw', obj.data)
    when ParsedHTTPBody
      waf_ctx.add('http.request.body', obj.data)
    else
      return false
    end

    waf_ctx.run
  end
end

class ChunkReader
  def initialize(io, size = 16)
    @io = io
    @size = size
  end

  def read
    @io.read(@size)
  end
end

class JSONBodyParser
  def parse(io)
    body = ''
    while (chunk = io.read)
      body << chunk
    end

    JSON.parse(body)
  end
end

class FakeServer
  def handle
    body = StringIO.new('{ "foo": "bar", "one": "two", "three": "four" }')
    reader = ChunkReader.new(body)
    parsed = JSONBodyParser.new.parse(reader)
    puts "parsed: #{parsed.inspect}"
  end
end

module ReadHook
  def read(*args)
    puts 'readhook in'
    op = Operation.new('readhook')
    op.start
    op.emit_start(:read_body)
    buf = super
  ensure
    op.emit_finish(buf)
    op.finish
    puts 'readhook out'
  end
end

module ParseHook
  def parse(*args)
    puts 'parsehook in'
    op = Operation.new('parsehook')
    op.start
    op.emit_start(:json_parse)
    res = super
  ensure
    op.emit_finish(res)
    op.finish
    puts 'parsehook out'
  end
end

module HandleHook
  def handle(*args)
    puts 'handlehook in'
    op = Operation.new('handlehook')
    op.start
    op.emit_start(:http_request)
    super
  ensure
    op.emit_finish
    op.finish
    puts 'handlehook out'
  end
end

ChunkReader.prepend ReadHook
FakeServer.prepend HandleHook
JSONBodyParser.prepend ParseHook

srv = FakeServer.new
srv.handle

root.finish
