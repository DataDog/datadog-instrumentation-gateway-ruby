class Stack < Array
  def call(env = {})
    head.call(tail, env)
  end

  def head
    first
  end

  def tail
    Stack.new(self[1..])
  end
end

A = proc do |stack, env|
  puts 'A+'
  begin
    stack.call(env)
  ensure
    puts 'A-'
  end
end

B = proc do |stack, env|
  puts 'B+'
  begin
    stack.call(env)
  ensure
    puts 'B-'
  end
end

C = proc do |stack, env|
  puts 'C+'
  begin
    stack.call(env)
  ensure
    puts 'C-'
  end
end

class Z
  def hello(*args, **kwargs)
    puts "Z args:#{args.inspect}, kwargs:#{kwargs.inspect}"

    ['Z', args, kwargs]
  end
end

module S
  def self.stack
    return @stack if @stack

    @stack = Stack.new
    @stack << A
    @stack << B
    @stack << C
  end

  def self.wrapper
    proc do |*args, **kwargs|
      supa  = proc { |*args, **kwargs| super(*args, **kwargs) }
      mid   = proc { |_, env| { return: supa.call(*env[:args], **env[:kwargs]) } }
      stack = S.stack.dup << mid

      r = stack.call(self: self, args: args, kwargs: kwargs)

      r[:return]
    end
  end

  define_method :hello, &self.wrapper
end

Z.prepend S
rv = Z.new.hello(42, foo: :bar)
puts "rv: #{rv.inspect}"
