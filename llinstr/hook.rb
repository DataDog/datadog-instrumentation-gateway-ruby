require 'pry'

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

class Callback
  attr_reader :name

  def initialize(name = nil, opts = {}, &block)
    @name = name
    @block = block
    @disabled = false
  end

  if RUBY_VERSION < '3.0'
    def call(*args, &block)
      return if @disabled
      @block.call(*args, &block)
    end
  else
    def call(*args, **kwargs, &block)
      return if @disabled
      @block.call(*args, **kwargs, &block)
    end
  end

  def disable
    @disabled = true
  end

  def enable
    @disabled = false
  end

  def disabled?
    @disabled
  end
end

class HookPointError < StandardError; end

class HookModule < Module
  def initialize(key)
    @key = key
  end

  attr_reader :key

  def inspect
    "#<#{self.class.name}: #{@key.inspect}>"
  end
end

class HookPoint
  DEFAULT_STRATEGY = Module.respond_to?(:prepend) ? :prepend : :chain

  class << self
    def parse(hook_point)
      klass_name, separator, method_name = hook_point.split(/(\#|\.)/, 2)

      raise ArgumentError, hook_point if klass_name.nil? || separator.nil? || method_name.nil?
      raise ArgumentError, hook_point unless ['.', '#'].include?(separator)

      method_kind = separator == '.' ? :klass_method : :instance_method

      [klass_name.to_sym, method_kind, method_name.to_sym]
    end

    def const_exist?(name)
      resolve_const(name) && true
    rescue NameError, ArgumentError
      false
    end

    def resolve_const(name)
      raise ArgumentError if name.nil? || name.empty?

      name.to_s.split('::').inject(Object) { |a, e| a.const_get(e, false) }
    end

    def strategy_module(strategy)
      case strategy
      when :prepend then Prepend
      when :chain then Chain
      else
        raise HookPointError, "unknown strategy: #{strategy.inspect}"
      end
    end
  end

  attr_reader :klass_name, :method_kind, :method_name

  def initialize(hook_point, strategy = DEFAULT_STRATEGY)
    @klass_name, @method_kind, @method_name = HookPoint.parse(hook_point)
    @strategy = strategy

    extend HookPoint.strategy_module(strategy)
  end

  def to_s
    @to_s ||= "#{@klass_name}#{@method_kind == :instance_method ? '#' : '.'}#{@method_name}"
  end

  def exist?
    return false unless HookPoint.const_exist?(@klass_name)

    if klass_method?
      (
        klass.singleton_class.public_instance_methods(false) +
        klass.singleton_class.protected_instance_methods(false) +
        klass.singleton_class.private_instance_methods(false)
      ).include?(@method_name)
    elsif instance_method?
      (
        klass.public_instance_methods(false) +
        klass.protected_instance_methods(false) +
        klass.private_instance_methods(false)
      ).include?(@method_name)
    else
      raise HookPointError, "#{self} unknown hook point kind"
    end
  end

  def klass
    HookPoint.resolve_const(@klass_name)
  end

  def klass_method?
    @method_kind == :klass_method
  end

  def instance_method?
    @method_kind == :instance_method
  end

  def private_method?
    if klass_method?
      klass.private_methods.include?(@method_name)
    elsif instance_method?
      klass.private_instance_methods.include?(@method_name)
    else
      raise HookPointError, "#{self} unknown hook point kind"
    end
  end

  def protected_method?
    if klass_method?
      klass.protected_methods.include?(@method_name)
    elsif instance_method?
      klass.protected_instance_methods.include?(@method_name)
    else
      raise HookPointError, "#{self} unknown hook point kind"
    end
  end

  def installed?(key)
    super
  end

  def install(key, &block)
    unless exist?
      return
    end

    if installed?(key)
      return
    end

    super
  end

  def uninstall(key)
    unless exist?
      return
    end

    unless installed?(key)
      return
    end

    super
  end

  def enable(key)
    super
  end

  def disable(key)
    super
  end

  def disabled?(key)
    super
  end

  module Prepend
    def installed?(key)
      prepended?(key) && overridden?(key)
    end

    def install(key, &block)
      prepend(key)
      override(key, &block)
    end

    def uninstall(key)
      unoverride(key) if overridden?(key)
    end

    def enable(key)
      raise HookPointError, 'enable called with prepend strategy'
    end

    def disable(key)
      unoverride(key)
    end

    def disabled?(key)
      !overridden?(key)
    end

    private

    def hook_module(key)
      target = klass_method? ? klass.singleton_class : klass
      mod = target.ancestors.each { |e| break if e == target; break(e) if e.class == HookModule && e.key == key }
      raise "Inconsistency detected: #{target} missing from its own ancestors" if mod.is_a?(Array)

      [target, mod]
    end

    def prepend(key)
      target, mod = hook_module(key)

      mod ||= HookModule.new(key)

      target.instance_eval { prepend(mod) }
    end

    def prepended?(key)
      _, mod = hook_module(key)

      mod != nil
    end

    def overridden?(key)
      _, mod = hook_module(key)

      (mod.instance_methods(false) + mod.protected_instance_methods(false) + mod.private_instance_methods(false)).include?(method_name)
    end

    def override(key, &block)
      hook_point = self
      method_name = @method_name

      _, mod = hook_module(key)

      mod.instance_eval do
        if hook_point.private_method?
          private
        elsif hook_point.protected_method?
          protected
        else
          public
        end

        define_method(:"#{method_name}", &block)
      end
    end

    def unoverride(key)
      method_name = @method_name

      _, mod = hook_module(key)

      mod.instance_eval { remove_method(method_name) }
    end
  end

  module Chain
    def installed?(key)
      defined(key)
    end

    def install(key, &block)
      define(key, &block)
      chain(key)
    end

    def uninstall(key)
      disable(key)
      remove(key)
    end

    def enable(key)
      chain(key)
    end

    def disable(key)
      unchain(key)
    end

    def disabled?(key)
      !chained?(key)
    end

    private

    def defined(suffix)
      if klass_method?
        (klass.methods + klass.protected_methods + klass.private_methods).include?(:"#{method_name}_with_#{suffix}")
      elsif instance_method?
        (klass.instance_methods + klass.protected_instance_methods + klass.private_instance_methods).include?(:"#{method_name}_with_#{suffix}")
      else
        Sqreen::Graft.logger.error { "[#{Process.pid}] #{self} unknown hook point kind" }
        raise HookPointError, "#{self} unknown hook point kind"
      end
    end

    def define(suffix, &block)
      hook_point = self
      method_name = @method_name

      if klass_method?
        klass.singleton_class.instance_eval do
          if hook_point.private_method?
            private
          elsif hook_point.protected_method?
            protected
          else
            public
          end

          define_method(:"#{method_name}_with_#{suffix}", &block)
        end
      elsif instance_method?
        klass.class_eval do
          if hook_point.private_method?
            private
          elsif hook_point.protected_method?
            protected
          else
            public
          end

          define_method(:"#{method_name}_with_#{suffix}", &block)
        end
      else
        raise HookPointError, 'unknown hook point kind'
      end
    end

    def remove(suffix)
      method_name = @method_name

      if klass_method?
        klass.singleton_class.instance_eval do
          remove_method(:"#{method_name}_with_#{suffix}")
        end
      elsif instance_method?
        klass.class_eval do
          remove_method(:"#{method_name}_with_#{suffix}")
        end
      else
        raise HookPointError, 'unknown hook point kind'
      end
    end

    def chained?(suffix)
      method_name = @method_name

      if klass_method?
        klass.singleton_class.instance_eval do
          instance_method(:"#{method_name}").original_name == :"#{method_name}_with_#{suffix}"
        end
      elsif instance_method?
        klass.class_eval do
          instance_method(:"#{method_name}").original_name == :"#{method_name}_with_#{suffix}"
        end
      else
        raise HookPointError, 'unknown hook point kind'
      end
    end

    def chain(suffix)
      method_name = @method_name

      if klass_method?
        klass.singleton_class.instance_eval do
          alias_method :"#{method_name}_without_#{suffix}", :"#{method_name}"
          alias_method :"#{method_name}", :"#{method_name}_with_#{suffix}"
        end
      elsif instance_method?
        klass.class_eval do
          alias_method :"#{method_name}_without_#{suffix}", :"#{method_name}"
          alias_method :"#{method_name}", :"#{method_name}_with_#{suffix}"
        end
      else
        raise HookPointError, 'unknown hook point kind'
      end
    end

    def unchain(suffix)
      method_name = @method_name

      if klass_method?
        klass.singleton_class.instance_eval do
          alias_method :"#{method_name}", :"#{method_name}_without_#{suffix}"
        end
      elsif instance_method?
        klass.class_eval do
          alias_method :"#{method_name}", :"#{method_name}_without_#{suffix}"
        end
      end
    end

    if RUBY_VERSION < '3.0'
      def apply(obj, suffix, *args, &block)
        obj.send("#{method_name}_without_#{suffix}", *args, &block)
      end
    else
      def apply(obj, suffix, *args, **kwargs, &block)
        obj.send("#{method_name}_without_#{suffix}", *args, **kwargs, &block)
      end
    end
  end
end

class Hook
  DEFAULT_STRATEGY = HookPoint::DEFAULT_STRATEGY

  @hooks = {}

  def self.[](hook_point, strategy = DEFAULT_STRATEGY)
    @hooks[hook_point] ||= new(hook_point, nil, strategy)
  end

  def self.add(hook_point, strategy = DEFAULT_STRATEGY, &block)
    self[hook_point, strategy].add(&block)
  end

  def self.ignore
    Thread.current[:hook_entered] = true
    yield
  ensure
    Thread.current[:hook_entered] = false
  end

  attr_reader :point, :stack

  def initialize(hook_point, dependency_test = nil, strategy = DEFAULT_STRATEGY)
    @disabled = false
    @point = hook_point.is_a?(HookPoint) ? hook_point : HookPoint.new(hook_point, strategy)
    @dependency_test = dependency_test || Proc.new { point.exist? }
    @stack = Stack.new
  end

  def dependency?
    @dependency_test.call if @dependency_test
  end

  def add(&block)
    tap { instance_eval(&block) }
  end

  def callback_name(tag = nil)
    "#{point}" << (tag ? ":#{tag}" : "")
  end

  def append(tag = nil, opts = {}, &block)
    @stack << Callback.new(callback_name(tag), opts, &block)
  end

  def unshift(tag = nil, opts = {}, &block)
    @stack.unshift Callback.new(callback_name(tag), opts, &block)
  end

  def before(tag = nil, opts = {}, &block)
    #
  end

  def after(tag = nil, opts = {}, &block)
    #
  end

  def depends_on(&block)
    @dependency_test = block
  end

  def enable
    @disabled = false
  end

  def disable
    @disabled = true
  end

  def disabled?
    @disabled
  end

  def install
    unless point.exist?
      return
    end

    point.install('hook', &Hook.wrapper(self))
  end

  def uninstall
    unless point.exist?
      return
    end

    point.uninstall('hook', &Hook.wrapper(self))
  end

  class << self
    if RUBY_VERSION < '3.0'
      def wrapper(hook)
        proc do |*args, &block|
          supa = proc { |*args| super(*args) }
          mid  = proc { |_, env| { return: supa.call(*env[:args]) } }
          stack = hook.stack.dup
          stack << mid

          stack.call(self: self, args: args)
        end
      end
    else
      def wrapper(hook)
        proc do |*args, **kwargs, &block|
          supa = proc { |*args, **kwargs| super(*args, **kwargs) }
          mid  = proc { |_, env| { return: supa.call(*env[:args], **env[:kwargs]) } }
          stack = hook.stack.dup
          stack << mid

          stack.call(self: self, args: args, kwargs: kwargs)
        end
      end
    end
  end
end


# trying HookPoint

class A
  def hello
    puts 'A'
  end
end

p A.new.singleton_class.ancestors

hook_point = HookPoint.new('A#hello')

hook_point.install('test') do |*args, **kwargs|
  puts 'H+'
  r = super(*args, **kwargs)
  puts 'H-'
  r
end

A.new.hello

p A.new.singleton_class.ancestors

hook_point.uninstall('test')

A.new.hello

p A.new.singleton_class.ancestors

hook_point.install('test') do |*args, **kwargs|
  puts 'H+'
  r = super(*args, **kwargs)
  puts 'H-'
  r
end

A.new.hello

p A.new.singleton_class.ancestors


# trying Hook

class B
  def hello(*args, **kwargs)
    puts "B args:#{args.inspect}, kwargs:#{kwargs.inspect}"

    ['B', args, kwargs]
  end
end

Hook['B#hello'].add do
  append do |stack, env|
    puts 'X+'
    r = stack.call(env)
    puts 'X-'
    r.merge(foo: 'bar')
  end

  append do |stack, env|
    begin
      p env
      env[:args][0] = 43
      r = stack.call(env)
    ensure
      p env
      p r
    end
  end
end.install

B.new.hello(42, foo: :bar)
