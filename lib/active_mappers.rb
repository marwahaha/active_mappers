require 'method_source'
require 'ruby2ruby'
require 'ruby_parser'

require 'active_support'
require 'active_support/core_ext/object/try'
require 'active_support/core_ext/hash/except'
require 'active_support/core_ext/string/inflections'
require_relative 'core_ext/hash'
require_relative 'active_mappers/handlers/inheritance'
require_relative 'active_mappers/key_transformer'


module ActiveMappers
  class Base
    @@renderers = {}

    def self.inherited(subclass)
      Handlers::Inheritance.new(subclass, self).handle
    end

    def self.attributes(*params)
      each do |resource|
        h = {}
        params.each do |param|
          h[param] = resource.try(param)
        end
        h
      end
    end

    def self.delegate(*params)
      delegator = params.last[:to]
      params.pop
      each do |resource|
        h = {}
        params.each do |param|
          h[param] = delegator.to_s.split('.').inject(resource, :try).try(param)
        end
        h
      end
    end

    def self.relation(key, mapper = nil, **options)
      path = options[:optional_path] || key
      each do |resource|
        relation_class_name = resource.class&.reflect_on_association(options[:optional_path] || key)&.class_name
        raise "undefined relation : #{key.to_s}" if (mapper.nil? && relation_class_name.nil?)

        mapper_to_use = mapper || KeyTransformer.resource_class_to_mapper(relation_class_name, self)       
        raise "'#{mapper_to_use.name}' should be a mapper" unless mapper_to_use.ancestors.map(&:to_s).include?("ActiveMappers::Base")
        
        { key => mapper_to_use.with(path.to_s.split('.').inject(resource, :try), options.merge(rootless: true)) }
      end
    end

    def self.polymorphic(key)
      each do |resource|
        resource_mapper = "#{KeyTransformer.base_namespace(self)}::#{resource.send("#{key}_type")}Mapper".constantize
        { key => resource_mapper.with(resource.send(key), rootless: true) }
      end
    end

    def self.acts_as_polymorph
      each do |resource|
        mapper = KeyTransformer.resource_to_mapper(resource, self)
        mapper.with(resource, rootless: true)
      rescue NameError
        raise NotImplementedError, 'No mapper found for this type of resource'
      end
    end

    def self.each(&block)
      @@renderers[name] = (@@renderers[name] || []) << block
    end

    def self.with(args, options = {})
      return evaluate_scopes(args, options) unless options[:scope].nil?
      
      response = if options[:rootless]
        args.respond_to?(:each) ? all(args) : one(args)
      else
        render_with_root(args, options)
      end
      response
    end

    def self.evaluate_scopes(args, options)
      class_to_call = "::#{name}Scope#{options[:scope].capitalize}".constantize rescue raise("ActiveMappers [#{name}] No scope named #{options[:scope]} found")
      return class_to_call.with(args, options.except(:scope))
    end

    def self.scope(*params, &block)
      raise "ActiveMappers [#{name}] scope must be a bloc" if block.nil? || !block.respond_to?(:call)

      
      params.each do |param|
        block_content = Ruby2Ruby.new.process(RubyParser.new.process(block.source).to_a.last)
        eval("class ::#{name}Scope#{param.capitalize} < ::#{name} ; #{block_content}; end")
      end
    end

    def self.render_with_root(args, options = {})
      resource_name = options[:root]
      resource_name ||= KeyTransformer.apply_on(self.name)
      
      if args.respond_to?(:each)
        { resource_name.to_s.pluralize.to_sym => all(args) }
      else
        { resource_name.to_s.singularize.to_sym => one(args) }
      end
    end

    def self.all(collection)
      collection.map { |el| one(el) }.compact
    end

    def self.one(resource)
      return nil unless resource
      return {} if @@renderers[name].nil? # Mapper is empty
      renderers = @@renderers[name].map do |renderer|
        renderer.call(resource)
      end.reduce(&:merge)

      KeyTransformer.format_keys(renderers)
    end
  end
end
