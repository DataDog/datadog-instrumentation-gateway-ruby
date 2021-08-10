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

a = proc do |stack, env|
  puts 'a+'
  stack.call(env)
  puts 'a-'
end

b = proc do |stack, env|
  puts 'b+'
  stack.call(env)
  puts 'b-'
end

c = proc do |stack, env|
  puts 'c+'
  stack.call(env)
  puts 'c-'
end

stack = Stack.new
stack << a
stack << b
stack << c
stack << proc { puts 'z' }

stack.call
