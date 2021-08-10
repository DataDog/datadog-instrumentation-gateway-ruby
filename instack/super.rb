class A
  def hello
    puts 'A'
  end
end

class B < A
  def hello
    puts 'B+'
    super
    puts 'B-'
  end
end

module C
  def hello
    puts 'C+'
    super
    puts 'C-'
  end
end

B.prepend C

puts
B.new.hello

module D
  def self.wrapper
    proc do |*args, **kwargs|
      puts 'D+'
      super(*args, **kwargs)
      puts 'D-'
    end
  end

  define_method :hello, &self.wrapper
end

B.prepend D

puts
B.new.hello

module E
  def self.wrapper
    proc do |*args, **kwargs|
      supa = proc { super(*args, **kwargs) }

      puts 'E+'
      supa.call
      puts 'E-'
    end
  end

  define_method :hello, &self.wrapper
end

B.prepend E

puts
B.new.hello
