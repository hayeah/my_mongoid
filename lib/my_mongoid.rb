require "my_mongoid/version"

module MyMongoid
  def self.models
    @models ||= []
  end

  def self.register_model(klass)
    models.push klass if !models.include?(klass)
  end
end

class MyMongoid::Field
  attr_reader :name
  def initialize(name)
    @name = name
  end
end

class MyMongoid::DuplicateFieldError < RuntimeError
end

class MyMongoid::UnknownAttributeError < RuntimeError
end

module MyMongoid::Document
  def self.included(klass)
    klass.module_eval do
      extend ClassMethods
      field :_id
      MyMongoid.register_model(klass)
    end
  end

  attr_reader :attributes
  def initialize(attrs)
    raise ArgumentError unless attrs.is_a?(Hash)
    @attributes = {}
    process_attributes(attrs)
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

  def new_record?
    true
  end
end

module MyMongoid::Document::ClassMethods
  def is_mongoid_model?
    true
  end

  def field(name)
    name = name.to_s
    @fields ||= {}
    raise MyMongoid::DuplicateFieldError if @fields.has_key?(name)
    @fields[name] = MyMongoid::Field.new(name)
    self.module_eval do
      define_method(name) do
        read_attribute(name)
      end

      define_method("#{name}=") do |value|
        write_attribute(name,value)
      end
    end
  end

  def fields
    @fields
  end
end