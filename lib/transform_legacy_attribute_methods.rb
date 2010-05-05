#transform_legacy_attribute_methods makes attribute aliases that can be used in dynamic finders and attribute hashes. 

#Author: Skye Shaw (sshaw@lucas.cis.temple.edu)
#License: http://www.opensource.org/licenses/mit-license.php

# Inspired by:
# http://stackoverflow.com/questions/538793/legacy-schema-and-dynamic-find-ruby-on-rails/540096#540096

module TransformLegacyAttributeMethods
  VERSION = "0.2"

  mattr_accessor :transformer
  self.transformer = :underscore

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def transform_legacy_attribute_methods(*args, &block) 
      skip = []

      cattr_accessor :transformed_attribute_hash, :inverse_transformed_attribute_hash
      self.transformed_attribute_hash = {}
      private :transformed_attribute_hash, :inverse_transformed_attribute_hash

      if args.last.is_a?(Hash) 
        args.last.assert_valid_keys(:skip) 
        skip = [ args.pop[:skip] ].flatten
      end

      transformer = block_given? ? block : (args.shift || TransformLegacyAttributeMethods.transformer)

      column_names.each do |name|
      	next if skip.include?(name) || skip.include?(name.to_sym)
      
      	transformed_name = transformer.respond_to?(:call) ? transformer.call(name) : name.send(transformer)
      	raise "transformer returned nil for column '#{name}'" if transformed_name.nil?
      	transformed_attribute_hash[transformed_name.to_s] = name

        define_transformed_attribute_methods(name, transformed_name)
      end
      
      # fosrias: Need this to parse returned attributes in to_xml and to_json serialization
      self.inverse_transformed_attribute_hash = transformed_attribute_hash.invert
      
      self.class_eval do
        def attributes_with_transform
          attrs = attributes_without_transform
          transformed_attribute_hash.each do |transformed_name, name|
            attrs[transformed_name] = attrs[name]
          end
          attrs
        end
        alias_method_chain :attributes, :transform
        
        # fosrias: This the the better way to go since anything that calls read_attribute or write_attribute
        # will work, e.g., composite primary keys gem calls it to set the obj.id property. If you use rails
        # convention names for primary keys with that gem and this plugin, it fails without this approach
        # for legacy attributes. Thus, [] and []= overrides are unnecessary.
        def read_attribute_with_transform(name)
          read_attribute_without_transform(self.class.real_attribute_name(name))
        end
        alias_method_chain :read_attribute, :transform
        
        def write_attribute_with_transform(name, value)
          write_attribute_without_transform(self.class.real_attribute_name(name), value)
        end
        alias_method_chain :write_attribute, :transform

        # fosrias: Allows calculate methods to work with transformed names. Overrides existing method.
        def self.column_for(field)
          field_name = field.to_s.split('.').last
          columns.detect { |c| c.name.to_s == self.class.real_attribute_name(field_name) }
        end
        
        # fosrias: We need this so that custom primary keys work with the id property.
        # Allows transformed attributes to be used as the custom primary key(s).
        def column_for_attribute_with_transform(name)
          column_for_attribute_without_transform(self.class.real_attribute_name(name))
        end
        alias_method_chain :column_for_attribute, :transform

        # fosrias: Add transformed names as methods to render statements.
        def to_xml_with_transform(options = {}, &block)
          to_xml_without_transform(include_transformed_accessor_methods(options), &block)
        end
        alias_method_chain :to_xml, :transform

        def to_json_with_transform(options = {}, &block)
          to_json_without_transform(include_transformed_accessor_methods(options), &block)
        end
        alias_method_chain :to_json, :transform

        # fosrias: Since transformed attributes are accessible as methods, we include them as 
        # :methods options for out-of-the-box functionality. 
        private
        def include_transformed_accessor_methods(options = {})
          attrs = self.instance_variable_get('@attributes')
          options[:methods] = attrs.inject(Array(options[:methods])) do |method_attributes, value|
             name = value[0]
             method_attributes << inverse_transformed_attribute_hash[name].to_sym if inverse_transformed_attribute_hash.include?(name)
             method_attributes
         end
         options
        end
      end

      self.instance_eval do
        #Transformed attribute names have to be returned to their original to be used in the DB query
        def construct_attributes_from_arguments(attribute_names, arguments)
          attributes = {}
          attribute_names.each_with_index do |name, idx| 
            name = real_attribute_name(name)
            attributes[name] = arguments[idx] 
          end
          attributes
        end
        
        def all_attributes_exists?(attribute_names)
          attribute_names = expand_attribute_names_for_aggregates(attribute_names)
          attribute_names.all? { |name| column_methods_hash.include?(name.to_sym) || transformed_attribute_hash.include?(name) }
        end
        
        # fosrias: Allows using rails convention in sql options. We replace transformed field names with
        # their original values for both finder and calculation sql.
        # Have to use alias here vs. alias_method_chain otherwise sti extended classes do not like it.
        alias :old_construct_finder_sql :construct_finder_sql
        
        def construct_finder_sql(options)
          transformed_sql = old_construct_finder_sql(options)
          construct_legacy_sql_for(transformed_sql)
        end
   
        alias :old_construct_calculation_sql :construct_calculation_sql
        def construct_calculation_sql(operation, column_name, options)
          transformed_sql = old_construct_calculation_sql(operation, column_name, options)
          construct_legacy_sql_for(transformed_sql)
        end
        
        private 
        # fosrias: Parses out transformed field names and replaces them with legacy names.
        # AS functionality is maintained, i.e. AS avg_transformed_attribute is not changed but
        # AVG(transformed_attribute) becomes AVG(LegacyAttribute).
        def construct_legacy_sql_for(sql)
          transformed_attribute_hash.each do |transformed_name, original_name|
            index = sql.index(%r{#{transformed_name}})
            if (index && index > 0)
              
              length = transformed_name.length
              
              #Have to parse so that each instance of an individual name is found
              while index && index > 0 
              
                #Check the name is surrounded by anything but a letter or an underscore
                # so that we don't substitute a name into a word that includes the 
                # transformed name as a substring.
                surrounding_characters = sql.slice(index-1,1) + sql.slice(index + length, 1)
                if (!surrounding_characters.match /[\w_]/)
                  sql[index..index + length - 1] = original_name
                end
                # Look for another instance
                index = sql.index(%r{#{transformed_name}}, index + 1)
              end
            end
          end
          sql
        end
      end
    end

    def real_attribute_name(name)
      transformed_attribute_hash.include?(name.to_s) ? transformed_attribute_hash[name.to_s] : name
    end

    private
    def define_transformed_attribute_methods(name, transformed_name)
      define_method(transformed_name.to_sym) do
        read_attribute_without_transform(name)
      end

      define_method("#{transformed_name}=".to_sym) do |value|
        write_attribute_without_transform(name, value)
      end
      
      define_method("#{transformed_name}?".to_sym) do
        self.send("#{name}?".to_sym)
      end

      define_method("#{transformed_name}_before_type_cast".to_sym) do
        self.send("#{name}_before_type_cast".to_sym)
      end
    end
  end
end
