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
  stack.call(env)
  puts 'A-'
end

B = proc do |stack, env|
  puts 'B+'
  stack.call(env)
  puts 'B-'
end

C = proc do |stack, env|
  puts 'C+'
  stack.call(env)
  puts 'C-'
end

class Z
  def hello
    puts 'Z'
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
      supa = proc { super(*args, **kwargs) }

      stack = S.stack.dup << supa
      stack.call
    end
  end

  define_method :hello, &self.wrapper
end

Z.prepend S
Z.new.hello
