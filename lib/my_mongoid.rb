require "my_mongoid/version"

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
    if self.id.nil?
      self.id = BSON::ObjectId.new
    end

    result = self.class.collection.insert(self.to_document)

    @new_record = false
    true
  end

  def new_record?
    @new_record == true
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
    event = Event.new(attrs)
    event.save
    event
  end

  def instantiate(attrs)
    doc = allocate
    doc.instance_variable_set(:@attributes,attrs)
    doc
  end

  def find(query)
    result = self.collection.find(query).one
    if result.nil?
      raise MyMongoid::RecordNotFoundError
    end
    Event.instantiate(result)
  end
end