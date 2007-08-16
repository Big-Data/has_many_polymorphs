
module ActiveRecord #:nodoc:
  module Associations #:nodoc:

=begin rdoc

Class methods added to ActiveRecord::Base for setting up polymorphic associations.

== Notes
  
STI association targets must enumerated and named. For example, if Dog and Cat both inherit from Animal, you still need to say <tt>[:dogs, :cats]</tt>, and not <tt>[:animals]</tt>.

Namespaced models follow the Rails <tt>underscore</tt> convention. ZooAnimal::Lion becomes <tt>:'zoo_animal/lion'</tt>.

You do not need to set up any other associations other than for either the regular method or the double. The join associations and all individual and reverse associations are generated for you. However, a join class and table is required. There are tentative reports that it works without it if you make the parent class join to the targets <tt>:through</tt> itself, but this is untested.

=end

   module PolymorphicClassMethods
   
     RESERVED_KEYS = [:conditions, :order, :limit, :offset, :extend, :skip_duplicates, 
                                   :join_extend, :dependent, :rename_individual_collections] #:nodoc:
 
=begin rdoc

This method creates a doubled-sided polymorphic relationship. It must be called on the join model:

  class Devouring < ActiveRecord::Base
    belongs_to :eater, :polymorphic => true
    belongs_to :eaten, :polymorphic => true
  
    acts_as_double_polymorphic_join(
      :eaters => [:dogs, :cats], 
      :eatens => [:cats, :birds]
    )       
  end

The method works by defining one or more special <tt>has_many_polymorphs</tt> association on every model in the target lists, depending on which side of the association it is on. Double self-references will work.

The two association names and their value arrays are the only required parameters.

== Available options

These options are passed through to targets on both sides of the association. If you want to affect only one side, prepend the key with the name of that side. For example, <tt>:eaters_extend</tt>.

<tt>:dependent</tt>:: Accepts <tt>:destroy</tt>, <tt>:nullify</tt>, or <tt>:delete_all</tt>. Controls how the join record gets treated on any association delete (whether from the polymorph or from an individual collection); defaults to <tt>:destroy</tt>.
<tt>:skip_duplicates</tt>:: If <tt>true</tt>, will check to avoid pushing already associated records (but also triggering a database load). Defaults to <tt>true</tt>.
<tt>:rename_individual_collections</tt>:: If <tt>true</tt>, all individual collections are prepended with the polymorph name, and the children's parent collection is appended with <tt>"\_of_#{association_name}"</tt>.
<tt>:extend</tt>:: One or an array of mixed modules and procs, which are applied to the polymorphic association (usually to define custom methods).
<tt>:join_extend</tt>:: One or an array of mixed modules and procs, which are applied to the join association.
<tt>:conditions</tt>:: An array or string of conditions for the SQL <tt>WHERE</tt> clause. 
<tt>:order</tt>:: A string for the SQL <tt>ORDER BY</tt> clause.
<tt>:limit</tt>:: An integer. Affects the polymorphic and individual associations.
<tt>:offset</tt>:: An integer. Only affects the polymorphic association.
  
=end

      def acts_as_double_polymorphic_join options={}, &extension     
        
        collections = options._select {|k,v| v.is_a? Array and k.to_s !~ /(#{RESERVED_KEYS.map(&:to_s).join('|')})$/}      
        raise PolymorphicError, "Couldn't understand options in acts_as_double_polymorphic_join. Valid parameters are your two class collections, and then #{RESERVED_KEYS.inspect[1..-2]}, with optionally your collection names prepended and joined with an underscore." unless collections.size == 2
        
        options = options._select {|k,v| !collections[k]}
        options[:extend] = (options[:extend] ? Array(options[:extend]) + [extension] : extension) if extension # inline the block
          
        collection_option_keys = Hash[*collections.keys.map do |key|
          [key, RESERVED_KEYS.map{|option| "#{key}_#{option}".to_sym}] 
        end._flatten_once]    
      
        collections.keys.each do |collection|      
          options.each do |key, value|
            next if collection_option_keys.values.flatten.include? key
            # shift the general options to the individual sides
            collection_value = options[collection_key = "#{collection}_#{key}".to_sym]
            case key
              when :conditions
                collection_value, value = sanitize_sql(collection_value), sanitize_sql(value)
                options[collection_key] = (collection_value ? "(#{collection_value}) AND (#{value})" : value)
              when :order
                options[collection_key] = (collection_value ? "#{collection_value}, #{value}" : value)
              when :extend, :join_extend
                options[collection_key] = Array(collection_value) + Array(value)
              when :limit, :offset, :dependent, :rename_individual_collections
                options[collection_key] ||= value
              else
                raise PolymorphicError, "Unknown option key #{key.inspect}."
            end     
          end
        end
  
        join_name = self.name.tableize.to_sym
        collections.each do |association_id, children|
          parent_hash_key = (collections.keys - [association_id]).first # parents are the entries in the _other_ children array
          
          begin
            parent_foreign_key = self.reflect_on_association(parent_hash_key._singularize).primary_key_name
          rescue NoMethodError
            raise PolymorphicError, "Couldn't find 'belongs_to' association for :#{parent_hash_key._singularize} in #{self.name}." unless parent_foreign_key
          end
  
          parents = collections[parent_hash_key]
          conflicts = (children & parents) # set intersection          
          parents.each do |plural_parent_name| 
  
            parent_class = plural_parent_name._as_class
            singular_reverse_association_id = parent_hash_key._singularize 
              
            parent_class.send(:has_many_polymorphs, 
              association_id, {:is_double => true,
                                  :from => children, 
                                  :as => singular_reverse_association_id,
                                  :through => join_name.to_sym, 
                                  :foreign_key => parent_foreign_key, 
                                  :foreign_type_key => parent_foreign_key.to_s.sub(/_id$/, '_type'),
                                  :singular_reverse_association_id => singular_reverse_association_id,
                                  :conflicts => conflicts}.merge(Hash[*options._select do |key, value|
                                    collection_option_keys[association_id].include? key and !value.nil?
                                  end.map do |key, value|
                                    [key.to_s[association_id.to_s.length+1..-1].to_sym, value]
                                  end._flatten_once])) # rename side-specific options to general names
  
            if conflicts.include? plural_parent_name 
              # unify the alternate sides of the conflicting children
              (conflicts).each do |method_name|
                unless parent_class.instance_methods.include?(method_name)
                  parent_class.send(:define_method, method_name) do
                    (self.send("#{singular_reverse_association_id}_#{method_name}") + 
                      self.send("#{association_id._singularize}_#{method_name}")).freeze
                  end
                end     
              end
              
              # unify the join model... join model is always renamed for doubles, unlike child associations
              unless parent_class.instance_methods.include?(join_name)
                parent_class.send(:define_method, join_name) do
                  (self.send("#{join_name}_as_#{singular_reverse_association_id}") + 
                    self.send("#{join_name}_as_#{association_id._singularize}")).freeze
                end              
              end                         
            else
              unless parent_class.instance_methods.include?(join_name)
                parent_class.send(:alias_method, join_name, "#{join_name}_as_#{singular_reverse_association_id}")
              end
            end                      
  
          end
        end
      end

=begin rdoc

This method createds a single-sided polymorphic relationship. 

  class Petfood < ActiveRecord::Base
    has_many_polymorphs :eaters, :from => [:dogs, :cats, :birds]
  end

The only required parameter, aside from the association name, is <tt>:from</tt>. 

The method generates a number of associations aside from the polymorphic one. In this example Petfood also gets <tt>dogs</tt>, <tt>cats</tt>, and <tt>birds</tt>, and Dog, Cat, and Bird get <tt>petfoods</tt>. (The reverse association to the parent is always plural.)

== Available options

<tt>:from</tt>:: An array of symbols representing the target classes. Required.
<tt>:as</tt>:: A symbol for the parent's interface in the join--what the parent 'acts as'.
<tt>:through</tt>:: A symbol representing the class of the join model. Follows Rails defaults if not supplied (the parent and the association names, alphabetized, concatenated with an underscore, and singularized).
<tt>:foreign_key</tt>:: The column name for the parent's id in the join. 
<tt>:foreign_type_key</tt>:: The column name for the parent's class in the join, if the parent itself is polymorphic. Rarely needed.
<tt>:polymorphic_key</tt>:: The column name for the child's id in the join.
<tt>:polymorphic_type_key</tt>:: The column name for the child's class in the join.
<tt>:dependent</tt>:: Accepts <tt>:destroy</tt>, <tt>:nullify</tt>, <tt>:delete_all</tt>. Controls how the join record gets treated on any associate delete (whether from the polymorph or from an individual collection); defaults to <tt>:destroy</tt>.
<tt>:skip_duplicates</tt>:: If <tt>true</tt>, will check to avoid pushing already associated records (but also triggering a database load). Defaults to <tt>true</tt>.
<tt>:rename_individual_collections</tt>:: If <tt>true</tt>, all individual collections are prepended with the polymorph name, and the children's parent collection is appended with "_of_#{association_name}"</tt>. For example, <tt>zoos</tt> becomes <tt>zoos_of_animals</tt>. This is to help avoid method name collisions in crowded classes.
<tt>:extend</tt>:: One or an array of mixed modules and procs, which are applied to the polymorphic association (usually to define custom methods).
<tt>:join_extend</tt>:: One or an array of mixed modules and procs, which are applied to the join association.
<tt>:parent_extend</tt>:: One or an array of mixed modules and procs, which are applied to the target classes' association to the parent.
<tt>:conditions</tt>:: An array or string of conditions for the SQL <tt>WHERE</tt> clause. 
<tt>:parent_conditions</tt>:: An array or string of conditions which are applied to the target classes' association to the parent.
<tt>:order</tt>:: A string for the SQL <tt>ORDER BY</tt> clause.
<tt>:group</tt>:: An array or string of conditions for the SQL <tt>GROUP BY</tt> clause. Affects the polymorphic and individual associations.
<tt>:limit</tt>:: An integer. Affects the polymorphic and individual associations.
<tt>:offset</tt>:: An integer. Only affects the polymorphic association.
<tt>:uniq</tt>:: If <tt>true</tt>, the records returned are passed through a pure-Ruby <tt>uniq</tt> before they are returned. Rarely needed.

If you pass a block, it gets converted to a Proc and added to <tt>:extend</tt>. 

=end

      def has_many_polymorphs (association_id, options = {}, &extension)
        _logger_debug "has_many_polymorphs: associating #{self}.#{association_id}"
        reflection = create_has_many_polymorphs_reflection(association_id, options, &extension)
        # puts "Created reflection #{reflection.inspect}"
        # configure_dependency_for_has_many(reflection)
        collection_reader_method(reflection, PolymorphicAssociation)
      end
  
      # Composed method that assigns option defaults,  builds the reflection object, and sets up all the related associations on the parent, join, and targets.
      def create_has_many_polymorphs_reflection(association_id, options, &extension) #:nodoc:
        options.assert_valid_keys(
          :from,
          :as,
          :through,
          :foreign_key,
          :foreign_type_key,
          :polymorphic_key, # same as :association_foreign_key
          :polymorphic_type_key,
          :dependent, # default :destroy, only affects the join table
          :skip_duplicates, # default true, only affects the polymorphic collection
          :ignore_duplicates, # deprecated
          :is_double,
          :rename_individual_collections,
          :reverse_association_id, # not used
          :singular_reverse_association_id,
          :conflicts,
          :extend,
          :join_class_name,
          :join_extend,
          :parent_extend,
          :table_aliases,
          :select, # applies to the polymorphic relationship
          :conditions, # applies to the polymorphic relationship, the children, and the join
  #        :include,
          :parent_conditions,
          :order, # applies to the polymorphic relationship, the children, and the join
          :group, # only applies to the polymorphic relationship and the children
          :limit, # only applies to the polymorphic relationship and the children
          :offset, # only applies to the polymorphic relationship
          :parent_order,
          :parent_group,
          :parent_limit,
          :parent_offset,
  #        :source,
          :uniq, # XXX untested, only applies to the polymorphic relationship
  #        :finder_sql,
  #        :counter_sql,
  #        :before_add,
  #        :after_add,
  #        :before_remove,
  #        :after_remove
           :dummy)
  
        # validate against the most frequent configuration mistakes
        verify_pluralization_of(association_id)            
        raise PolymorphicError, ":from option must be an array" unless options[:from].is_a? Array            
        options[:from].each{|plural| verify_pluralization_of(plural)}
  
        options[:as] ||= self.name.demodulize.downcase.to_sym
        options[:conflicts] = Array(options[:conflicts])      
        options[:foreign_key] ||= "#{options[:as]}_id"
        
        options[:association_foreign_key] = 
          options[:polymorphic_key] ||= "#{association_id._singularize}_id"
        options[:polymorphic_type_key] ||= "#{association_id._singularize}_type"      
        
        if options.has_key? :ignore_duplicates
          _logger_warn "DEPRECATION WARNING: please use :skip_duplicates instead of :ignore_duplicates"
          options[:skip_duplicates] = options[:ignore_duplicates]
        end
        options[:skip_duplicates] = true unless options.has_key? :skip_duplicates
        options[:dependent] = :destroy unless options.has_key? :dependent
        options[:conditions] = sanitize_sql(options[:conditions])
        
  #      options[:finder_sql] ||= "(options[:polymorphic_key]
  
        options[:through] ||= build_join_table_symbol((options[:as]._pluralize or self.table_name), association_id)
        options[:join_class_name] ||= options[:through]._classify      
        options[:table_aliases] ||= build_table_aliases([options[:through]] + options[:from])
        options[:select] ||= build_select(association_id, options[:table_aliases]) 
  
        options[:through] = "#{options[:through]}_as_#{options[:singular_reverse_association_id]}" if options[:singular_reverse_association_id]
        options[:through] = demodulate(options[:through]).to_sym
  
        options[:extend] = spiked_create_extension_module(association_id, Array(options[:extend]) + Array(extension)) 
        options[:join_extend] = spiked_create_extension_module(association_id, Array(options[:join_extend]), "Join") 
        options[:parent_extend] = spiked_create_extension_module(association_id, Array(options[:parent_extend]), "Parent") 
        
        # create the reflection object      
        returning(create_reflection(:has_many_polymorphs, association_id, options, self)) do |reflection|
          if defined? Dependencies and RAILS_ENV == "development"                    
            inject_dependencies(association_id, reflection) if Dependencies.mechanism == :load
          end
          
          # set up the other related associations      
          create_join_association(association_id, reflection)
          create_has_many_through_associations_for_parent_to_children(association_id, reflection)
          create_has_many_through_associations_for_children_to_parent(association_id, reflection)      
        end             
      end
  
      private
  

      # table mapping for use at the instantiation point      
      
      def build_table_aliases(from)
        # for the targets
        returning({}) do |aliases|
          from.map(&:to_s).sort.map(&:to_sym).each_with_index do |plural, t_index|
            table = plural._as_class.table_name
            plural._as_class.columns.map(&:name).each_with_index do |field, f_index|
              aliases["#{table}.#{field}"] = "t#{t_index}_r#{f_index}"
            end
          end
        end
      end
  
      def build_select(association_id, aliases)
        # <tt>instantiate</tt> has to know which reflection the results are coming from
        (["\'#{self.name}\' AS polymorphic_parent_class", 
           "\'#{association_id}\' AS polymorphic_association_id"] + 
        aliases.map do |table, _alias|
          "#{table} AS #{_alias}"
        end.sort).join(", ")
      end
  
      # model caching         
      def inject_dependencies(association_id, reflection)
        _logger_debug "has_many_polymorphs: injecting dependencies"
        requirements = [self, reflection.klass].map{|klass| [klass, klass.base_class]}.flatten.uniq
        (all_classes_for(association_id, reflection) - requirements).each do |target_klass|
          Dependencies.inject_dependency(target_klass, *requirements)        
        end
      end
     
      # method sub-builders
   
      def create_join_association(association_id, reflection)
  
        options = {:foreign_key => reflection.options[:foreign_key], 
          :dependent => reflection.options[:dependent], 
          :class_name => reflection.klass.name, 
          :extend => reflection.options[:join_extend],
  #        :limit => reflection.options[:limit],
  #        :offset => reflection.options[:offset],
          :order => devolve(association_id, reflection, reflection.options[:order], reflection.klass),
          :conditions => devolve(association_id, reflection, reflection.options[:conditions], reflection.klass)
          }        
          
        if reflection.options[:foreign_type_key]         
          type_check = "#{reflection.options[:foreign_type_key]} = #{quote_value(self.base_class.name)}"
          conjunction = options[:conditions] ? " AND " : nil
          options[:conditions] = "#{options[:conditions]}#{conjunction}#{type_check}"
        end
  
        has_many(reflection.options[:through], options)      
        inject_before_save_into_join_table(association_id, reflection)          
      end
      
      def inject_before_save_into_join_table(association_id, reflection)
        sti_hook = "sti_class_rewrite"
        rewrite_procedure = %[self.send(:#{association_id._singularize}_type=, self.#{association_id._singularize}_type.constantize.base_class.name)]
        
        # XXX should be abstracted?
        reflection.klass.class_eval %[          
          unless instance_methods.include? "before_save_with_#{sti_hook}"
            if instance_methods.include? "before_save"                             
              alias_method :before_save_without_#{sti_hook}, :before_save 
              def before_save_with_#{sti_hook}
                before_save_without_#{sti_hook}
                #{rewrite_procedure}
              end
            else
              def before_save_with_#{sti_hook}
                #{rewrite_procedure}
              end  
            end
            alias_method :before_save, :before_save_with_#{sti_hook}
          end
        ]      
      end
              
      def create_has_many_through_associations_for_children_to_parent(association_id, reflection)
        
        child_pluralization_map(association_id, reflection).each do |plural, singular|
          if singular == reflection.options[:as]
            raise PolymorphicError, if reflection.options[:is_double]
              "You can't give either of the sides in a double-polymorphic join the same name as any of the individual target classes."
            else
              "You can't have a self-referential polymorphic has_many :through without renaming the non-polymorphic foreign key in the join model." 
            end
          end
                  
          parent = self
          plural._as_class.instance_eval do          
            # this shouldn't be called at all during doubles; there is no way to traverse to a double polymorphic parent (XXX is that right?)
            unless reflection.options[:is_double] or reflection.options[:conflicts].include? self.name.tableize.to_sym  
  
              # the join table
              through = "#{reflection.options[:through]}#{'_as_child' if parent == self}".to_sym
              has_many(through,
                :as => association_id._singularize, 
                :class_name => reflection.klass.name,
                :dependent => reflection.options[:dependent], 
                :extend => reflection.options[:join_extend],
  #              :limit => reflection.options[:limit],
  #              :offset => reflection.options[:offset],
                :order => devolve(association_id, reflection, reflection.options[:order], reflection.klass),
                :conditions => devolve(association_id, reflection, reflection.options[:conditions], reflection.klass)
                )
  
              # the association to the target's parents
              association = "#{reflection.options[:as]._pluralize}#{"_of_#{association_id}" if reflection.options[:rename_individual_collections]}".to_sym                        
              has_many(association, 
                :through => through, 
                :class_name => parent.name,
                :source => reflection.options[:as], 
                :foreign_key => reflection.options[:foreign_key] ,
                :extend => reflection.options[:parent_extend],
                :conditions => reflection.options[:parent_conditions],
                :order => reflection.options[:parent_order],
                :offset => reflection.options[:parent_offset],
                :limit => reflection.options[:parent_limit],
                :group => reflection.options[:parent_group])
                      
            end                    
          end
        end
      end
        
      def create_has_many_through_associations_for_parent_to_children(association_id, reflection)
        child_pluralization_map(association_id, reflection).each do |plural, singular|
          #puts ":source => #{child}"
          current_association = demodulate(child_association_map(association_id, reflection)[plural])
          source = demodulate(singular)
          
          if reflection.options[:conflicts].include? plural
            # XXX check this
            current_association = "#{association_id._singularize}_#{current_association}" if reflection.options[:conflicts].include? self.name.tableize.to_sym
            source = "#{source}_as_#{association_id._singularize}".to_sym
          end        
            
          # make push/delete accessible from the individual collections but still operate via the general collection
          extension_module = self.class_eval %[
            module #{self.name + current_association._classify + "PolymorphicChildAssociationExtension"}
              def push *args; proxy_owner.send(:#{association_id}).send(:push, *args); self; end               
              alias :<< :push
              def delete *args; proxy_owner.send(:#{association_id}).send(:delete, *args); end
              def clear; proxy_owner.send(:#{association_id}).send(:clear, #{singular._classify}); end
              self
            end]            
                      
          has_many(current_association.to_sym, 
              :through => reflection.options[:through], 
              :source => association_id._singularize,
              :source_type => plural._as_class.base_class.name,
              :class_name => plural._as_class.name, # make STI not conflate subtypes
              :extend => (Array(extension_module) + reflection.options[:extend]),
              :limit => reflection.options[:limit],
  #        :offset => reflection.options[:offset],
              :order => devolve(association_id, reflection, reflection.options[:order], plural._as_class),
              :conditions => devolve(association_id, reflection, reflection.options[:conditions], plural._as_class),
              :group => devolve(association_id, reflection, reflection.options[:group], plural._as_class)
              )
            
        end
      end
  
      # some support methods    
      
      def child_pluralization_map(association_id, reflection)
        Hash[*reflection.options[:from].map do |plural|
          [plural,  plural._singularize]
        end.flatten]
      end
      
      def child_association_map(association_id, reflection)            
        Hash[*reflection.options[:from].map do |plural|
          [plural, "#{association_id._singularize.to_s + "_" if reflection.options[:rename_individual_collections]}#{plural}".to_sym]
        end.flatten]
      end         
  
      def demodulate(s)
        s.to_s.gsub('/', '_').to_sym
      end
              
      def build_join_table_symbol(a, b)
        [a.to_s, b.to_s].sort.join("_").to_sym
      end
      
      def all_classes_for(association_id, reflection)
        klasses = [self, reflection.klass, *child_pluralization_map(association_id, reflection).keys.map(&:_as_class)]
        klasses += klasses.map(&:base_class)
        klasses.uniq
      end
      
      def devolve(association_id, reflection, string, klass)
        return unless string
        (all_classes_for(association_id, reflection) - # the join class must always be preserved
          [klass, klass.base_class, reflection.klass, reflection.klass.base_class]).map do |klass|
          klass.columns.map do |column| 
            [klass.table_name, column.name]
          end.map do |table, column|
            ["#{table}.#{column}", "`#{table}`.#{column}", "#{table}.`#{column}`", "`#{table}`.`#{column}`"]
          end
        end.flatten.sort_by(&:size).reverse.each do |quoted_reference|        
          string.gsub!(quoted_reference, "NULL")
        end
        string
      end
      
      def verify_pluralization_of(sym)
        sym = sym.to_s
        singular = sym.singularize
        plural = singular.pluralize
        raise PolymorphicError, "Pluralization rules not set up correctly. You passed :#{sym}, which singularizes to :#{singular}, but that pluralizes to :#{plural}, which is different. Maybe you meant :#{plural} to begin with?" unless sym == plural
      end      
    
      def spiked_create_extension_module(association_id, extensions, identifier = nil)    
        module_extensions = extensions.select{|e| e.is_a? Module}
        proc_extensions = extensions.select{|e| e.is_a? Proc }
        
        # support namespaced anonymous blocks as well as multiple procs
        proc_extensions.each_with_index do |proc_extension, index|
          module_name = "#{self.to_s}#{association_id._classify}Polymorphic#{identifier}AssociationExtension#{index}"
          the_module = self.class_eval "module #{module_name}; self; end" # XXX hrm
          the_module.class_eval &proc_extension
          module_extensions << the_module
        end
        module_extensions
      end
                
    end
  end
end
