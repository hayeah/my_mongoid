require "my_mongoid/version"
require "active_support"
require "active_model"
require "moped"

class MyMongoid::DuplicateFieldError < RuntimeError
end

class MyMongoid::UnknownAttributeError < RuntimeError
end

class MyMongoid::UnconfiguredDatabaseError < RuntimeError
end

class MyMongoid::RecordNotFoundError < RuntimeError
end

module MyMongoid
  def self.models
    @models ||= []
  end

  def self.register_model(klass)
    models.push klass if !models.include?(klass)
  end

  def self.configuration
    Configuration.instance
  end

  def self.configure
    yield configuration
  end

  def self.session
    return @session if defined?(@session)
    host = configuration.host
    database = configuration.database
    if host.nil? || database.nil?
      raise UnconfiguredDatabaseError
    end
    @session = Moped::Session.new([host])
    @session.use(database)
    @session
  end
end

class MyMongoid::Field
  attr_reader :name, :options
  def initialize(name,options)
    @name = name
    @options = options
  end
end

class MyMongoid::Configuration
  require "singleton"
  include Singleton

  attr_accessor :host
  attr_accessor :database
end

module MyMongoid::Document
  def self.included(klass)
    klass.module_eval do
      extend ClassMethods
      include MyMongoid::Callbacks
      field :_id, :as => :id
      MyMongoid.register_model(klass)
    end
  end

  attr_reader :attributes
  def initialize(attrs)
    raise ArgumentError unless attrs.is_a?(Hash)
    @attributes = {}
    @new_record = true
    process_attributes(attrs)
  end

  def to_document
    attributes
  end

  def read_attribute(name)
    @attributes[name]
  end

  def write_attribute(name,value)
    old_value = read_attribute(name)
    unless changed_attributes.has_key?(name) || old_value == value
      changed_attributes[name] = old_value
    end
    @attributes[name] = value
  end

  def process_attributes(attrs)
    attrs.map do |name,value|
      raise MyMongoid::UnknownAttributeError if !self.respond_to?(name)
      send("#{name}=",value)
    end
  end
  alias_method :attributes=, :process_attributes

  def save
    run_callbacks(:save) do
      if new_record?
        insert_root_document
      else
        update_document
      end

      clear_changed_attributes
      true
    end
  end

  def insert_root_document
    run_callbacks(:create) do
      if self.id.nil?
        self.id = BSON::ObjectId.new
      end

      result = self.class.collection.insert(self.to_document)

      @new_record = false
    end
  end

  def update_attributes(attrs)
    process_attributes(attrs)
    save
  end

  def update_document
    updates = atomic_updates
    if !updates.empty?
      selector = {"_id" => self.id}
      self.class.collection.find(selector).update(updates)
    end
  end

  def new_record?
    @new_record == true
  end

  def clear_changed_attributes
    @changed_attributes = {}
  end

  def changed_attributes
    @changed_attributes ||= {}
  end

  def changed?
    !changed_attributes.empty?
  end

  def atomic_updates
    if !changed? || new_record?
      {}
    else
      changes = {}
      changed_attributes.each do |k,v|
        next if k == "_id"
        changes[k] = read_attribute(k)
      end
      {"$set" => changes}
    end
  end

  def delete
    self.class.collection.find({"_id" => id}).remove
    @deleted = true
  end

  def deleted?
    @deleted == true
  end
end

module MyMongoid::Callbacks
  extend ActiveSupport::Concern

  included do
    extend ActiveModel::Callbacks
    define_model_callbacks :delete, :save, :create, :update
    define_model_callbacks :initialize, :find, :only => :after
  end
end

module MyMongoid::Document::ClassMethods
  require "active_support/inflector"
  def is_mongoid_model?
    true
  end

  def collection_name
    self.to_s.tableize
  end

  def collection
    MyMongoid.session[collection_name]
  end

  def field(name,opts={})
    name = name.to_s
    @fields ||= {}
    raise MyMongoid::DuplicateFieldError if @fields.has_key?(name)
    @fields[name] = MyMongoid::Field.new(name,opts)

    self.module_eval do
      define_method(name) do
        read_attribute(name)
      end

      define_method("#{name}=") do |value|
        write_attribute(name,value)
      end
    end

    if alias_name = opts[:as]
      alias_name = alias_name.to_s
      self.module_eval do
        alias_method alias_name, name
        alias_method "#{alias_name}=", "#{name}="
      end
    end
  end

  def fields
    @fields
  end

  def create(attrs)
    record = self.new(attrs)
    record.save
    record
  end

  def instantiate(attrs)
    doc = allocate
    doc.instance_variable_set(:@attributes,attrs)
    doc
  end

  def find(query)
    query = {"_id" => query} if query.is_a?(String)
    result = self.collection.find(query).one
    if result.nil?
      raise MyMongoid::RecordNotFoundError
    end
    self.instantiate(result)
  end
end

module MyMongoid::MyCallbacks
  extend ActiveSupport::Concern

  included do
  end

  def run_callbacks(name,&block)
    callbacks = send("_#{name}_callbacks")
    callbacks.invoke(self,&block)
    # chain = callbacks.compile
    # chain.call(self,&block)
  end

  module ClassMethods
    def define_callbacks(name)
      attr = "_#{name}_callbacks"
      class_attribute attr
      self.send("#{attr}=",CallbackChain.new)
    end

    def set_callback(name,kind,filter)
      callbacks = self.send("_#{name}_callbacks")
      callback = MyMongoid::MyCallbacks::Callback.new(filter,kind)
      callbacks.append(callback)
    end
  end

  class Callback
    attr_reader :filter
    attr_reader :kind

    def initialize(filter,kind)
      @filter = filter
      @kind = kind
    end

    def invoke(target,&block)
      target.send(filter,&block)
    end

    def compile
      lambda { |target,&block| target.send(@filter,&block) }
    end
  end

  class CallbackChain
    attr_reader :chain
    def initialize
      @chain = []
    end

    def empty?
      @chain.empty?
    end

    def append(callback)
      @callbacks = nil
      @chain.push callback
    end

    def invoke(target,&block)
      _invoke(0,target,block)
    end

    def compile
      return @callbacks if !@callbacks.nil?
      k0 = lambda { |_,&main| main.call }
      @callbacks = _compile k0, @chain.length - 1
    end

    def _compile(k,i)
      return k if i < 0

      cb = @chain[i]

      callback_fn = cb.compile
      case cb.kind
      when :before
        k2 = lambda { |target,&main|
          callback_fn.call(target)
          k.call(target,&main)
        }
      when :around
        k2 = lambda { |target,&main|
          k.call(target) do
            callback_fn.call(target,&main)
          end
        }
      when :after
        k2 = lambda { |target,&main|
          k.call(target,&main)
          callback_fn.call(target)
        }
      end
      _compile(k2,i-1)
    end

    protected
    def _invoke(i,target,block)
      if i == @chain.length
        block.call
        return
      end

      recur = lambda {
        _invoke(i+1,target,block)
      }

      cb = @chain[i]
      case cb.kind
      when :before
        r = cb.invoke(target)
        recur.call
      when :around
        cb.invoke(target) {
          recur.call
        }
      when :after
        recur.call
        cb.invoke(target)
      end
    end
  end
end