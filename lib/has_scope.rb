require 'active_support'
require 'action_controller'

module HasScope
  TRUE_VALUES = ["true", true, "1", 1]

  ALLOWED_TYPES = {
    array:   [[ Array ]],
    hash:    [[ Hash, ActionController::Parameters ]],
    boolean: [[ Object ], -> v { TRUE_VALUES.include?(v) }],
    default: [[ String, Numeric ]],
  }

  def self.included(base)
    base.class_eval do
      extend ClassMethods
      class_attribute :scopes_configuration, instance_writer: false
      self.scopes_configuration = {}
    end
  end

  module ClassMethods
    # Detects params from url and apply as scopes to your classes.
    #
    # == Options
    #
    # * <tt>:type</tt> - Checks the type of the parameter sent. If set to :boolean
    #                    it just calls the named scope, without any argument. By default,
    #                    it does not allow hashes or arrays to be given, except if type
    #                    :hash or :array are set.
    #
    # * <tt>:only</tt> - In which actions the scope is applied. By default is :all.
    #
    # * <tt>:except</tt> - In which actions the scope is not applied. By default is :none.
    #
    # * <tt>:as</tt> - The key in the params hash expected to find the scope.
    #                  Defaults to the scope name. Provide an array to accept nested parameters.
    #
    # * <tt>:using</tt> - If type is a hash, you can provide :using to convert the hash to
    #                     a named scope call with several arguments.
    #
    # * <tt>:in</tt> - A shortcut for combining the `:using` option with nested hashes. Looks for a query parameter
    #                  matching the scope name in the provided values. Provide an array for more
    #                  than one level of nested hashes.
    #
    # * <tt>:if</tt> - Specifies a method, proc or string to call to determine
    #                  if the scope should apply
    #
    # * <tt>:unless</tt> - Specifies a method, proc or string to call to determine
    #                      if the scope should NOT apply.
    #
    # * <tt>:default</tt> - Default value for the scope. Whenever supplied the scope
    #                       is always called.
    #
    # * <tt>:allow_blank</tt> - Blank values are not sent to scopes by default. Set to true to overwrite.
    #
    # == Block usage
    #
    # has_scope also accepts a block. The controller, current scope and value are yielded
    # to the block so the user can apply the scope on its own. This is useful in case we
    # need to manipulate the given value:
    #
    #   has_scope :category do |controller, scope, value|
    #     value != "all" ? scope.by_category(value) : scope
    #   end
    #
    #   has_scope :not_voted_by_me, type: :boolean do |controller, scope|
    #     scope.not_voted_by(controller.current_user.id)
    #   end
    #
    def has_scope(*scopes, &block)
      options = scopes.extract_options!
      options.symbolize_keys!
      options.assert_valid_keys(:type, :only, :except, :if, :unless, :default, :as, :using, :allow_blank, :in)

      if options.key?(:in)
        options[:using] = options[:as] || scopes
        options[:as] = options[:in]

        if options.key?(:default) && !options[:default].is_a?(Hash)
          options[:default] = scopes.each_with_object({}) { |scope, hash| hash[scope] = options[:default] }
        end
      end

      if options.key?(:using)
        if options.key?(:type) && options[:type] != :hash
          raise "You cannot use :using with another :type different than :hash"
        else
          options[:type] = :hash
        end

        options[:using] = Array(options[:using])
      end

      options[:only]   = Array(options[:only])
      options[:except] = Array(options[:except])

      self.scopes_configuration = scopes_configuration.dup

      scopes.each do |scope|
        scopes_configuration[scope] ||= {
          as: Array(options.delete(:as).presence || scope), type: :default, block: block
        }
        scopes_configuration[scope] = self.scopes_configuration[scope].merge(options)
      end
    end
  end

  protected

  # Receives an object where scopes will be applied to.
  #
  #   class GraduationsController < ApplicationController
  #     has_scope :featured, type: true, only: :index
  #     has_scope :by_degree, only: :index
  #
  #     def index
  #       @graduations = apply_scopes(Graduation).all
  #     end
  #   end
  #
  def apply_scopes(target, hash = params)
    scopes_configuration.each do |scope, options|
      next unless apply_scope_to_action?(options)
      *parent_keys, key = options[:as]

      if parent_keys.empty? && hash.key?(key)
        value = hash[key]
      elsif options.key?(:using) &&
            ALLOWED_TYPES[:hash].first.any? { |klass| hash.dig(*parent_keys, key).is_a?(klass) }
        value = hash.dig(*parent_keys)[key]
      elsif (parent_keys.present? ? hash.dig(*parent_keys) : hash)&.key?(key)
        value = (parent_keys.present? ? hash.dig(*parent_keys) : hash)[key]
      elsif options.key?(:default)
        value = options[:default]
        if value.is_a?(Proc)
          value = value.arity == 0 ? value.call : value.call(self)
        end
      else
        next
      end

      value = parse_value(options[:type], value)
      value = normalize_blanks(value)

      if value && options.key?(:using)
        value = value.slice(*options[:using])
        scope_value = value.values_at(*options[:using])
        if scope_value.all?(&:present?) || options[:allow_blank]
          (current_scopes(parent_keys)[key] ||= {}).merge!(value)
          target = call_scope_by_type(options[:type], scope, target, scope_value, options)
        end
      elsif value.present? || options[:allow_blank]
        current_scopes(parent_keys)[key] = value
        target = call_scope_by_type(options[:type], scope, target, value, options)
      end
    end

    target
  end

  # Set the real value for the current scope if type check.
  def parse_value(type, value) #:nodoc:
    klasses, parser = ALLOWED_TYPES[type]
    if klasses.any? { |klass| value.is_a?(klass) }
      parser ? parser.call(value) : value
    end
  end

  # Screens pseudo-blank params.
  def normalize_blanks(value) #:nodoc:
    case value
    when Array
      value.select { |v| v.present? }
    when Hash
      value.select { |k, v| normalize_blanks(v).present? }.with_indifferent_access
    when ActionController::Parameters
      normalize_blanks(value.to_unsafe_h)
    else
      value
    end
  end

  # Call the scope taking into account its type.
  def call_scope_by_type(type, scope, target, value, options) #:nodoc:
    block = options[:block]

    if type == :boolean && !options[:allow_blank]
      block ? block.call(self, target) : target.send(scope)
    elsif options.key?(:using)
      block ? block.call(self, target, value) : target.send(scope, *value)
    else
      block ? block.call(self, target, value) : target.send(scope, value)
    end
  end

  # Given an options with :only and :except arrays, check if the scope
  # can be performed in the current action.
  def apply_scope_to_action?(options) #:nodoc:
    return false unless applicable?(options[:if], true) && applicable?(options[:unless], false)

    if options[:only].empty?
      options[:except].empty? || !options[:except].include?(action_name.to_sym)
    else
      options[:only].include?(action_name.to_sym)
    end
  end

  # Evaluates the scope options :if or :unless. Returns true if the proc
  # method, or string evals to the expected value.
  def applicable?(string_proc_or_symbol, expected) #:nodoc:
    case string_proc_or_symbol
    when String
      ActiveSupport::Deprecation.warn <<-DEPRECATION.squish
        [HasScope] Passing a string to determine if the scope should be applied
        is deprecated and it will be removed in a future version of HasScope.
      DEPRECATION

      eval(string_proc_or_symbol) == expected
    when Proc
      string_proc_or_symbol.call(self) == expected
    when Symbol
      send(string_proc_or_symbol) == expected
    else
      true
    end
  end

  # Returns the scopes used in this action.
  def current_scopes(keys = [])
    @current_scopes ||= {}
    cs = @current_scopes
    keys.each do |k|
      cs[k] ||= {}
      cs = cs[k]
    end
    cs
  end
end

ActiveSupport.on_load :action_controller do
  include HasScope
  helper_method :current_scopes if respond_to?(:helper_method)
end
