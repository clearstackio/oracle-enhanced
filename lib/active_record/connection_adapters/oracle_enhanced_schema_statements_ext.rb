require 'digest/sha1'

module ActiveRecord
  module ConnectionAdapters
    module OracleEnhancedSchemaStatementsExt
      def supports_foreign_keys? #:nodoc:
        true
      end

      # Create primary key trigger (so that you can skip primary key value in INSERT statement).
      # By default trigger name will be "table_name_pkt", you can override the name with 
      # :trigger_name option (but it is not recommended to override it as then this trigger will
      # not be detected by ActiveRecord model and it will still do prefetching of sequence value).
      #
      #   add_primary_key_trigger :users
      #
      # You can also create primary key trigger using +create_table+ with :primary_key_trigger
      # option:
      #
      #   create_table :users, :primary_key_trigger => true do |t|
      #     # ...
      #   end
      #
      def add_primary_key_trigger(table_name, options)
        # call the same private method that is used for create_table :primary_key_trigger => true
        create_primary_key_trigger(table_name, options)
      end

      # Adds a new foreign key to the +from_table+, referencing the primary key of +to_table+
      # (syntax and partial implementation taken from http://github.com/matthuhiggins/foreigner)
      #
      # The foreign key will be named after the from and to tables unless you pass
      # <tt>:name</tt> as an option.
      #
      # === Examples
      # ==== Creating a foreign key
      #  add_foreign_key(:comments, :posts)
      # generates
      #  ALTER TABLE comments ADD CONSTRAINT
      #     comments_post_id_fk FOREIGN KEY (post_id) REFERENCES posts (id)
      # 
      # ==== Creating a named foreign key
      #  add_foreign_key(:comments, :posts, :name => 'comments_belongs_to_posts')
      # generates
      #  ALTER TABLE comments ADD CONSTRAINT
      #     comments_belongs_to_posts FOREIGN KEY (post_id) REFERENCES posts (id)
      # 
      # ==== Creating a cascading foreign_key on a custom column
      #  add_foreign_key(:people, :people, :column => 'best_friend_id', :dependent => :nullify)
      # generates
      #  ALTER TABLE people ADD CONSTRAINT
      #     people_best_friend_id_fk FOREIGN KEY (best_friend_id) REFERENCES people (id)
      #     ON DELETE SET NULL
      # 
      # === Supported options
      # [:column]
      #   Specify the column name on the from_table that references the to_table. By default this is guessed
      #   to be the singular name of the to_table with "_id" suffixed. So a to_table of :posts will use "post_id"
      #   as the default <tt>:column</tt>.
      # [:primary_key]
      #   Specify the column name on the to_table that is referenced by this foreign key. By default this is
      #   assumed to be "id".
      # [:name]
      #   Specify the name of the foreign key constraint. This defaults to use from_table and foreign key column.
      # [:dependent]
      #   If set to <tt>:delete</tt>, the associated records in from_table are deleted when records in to_table table are deleted.
      #   If set to <tt>:nullify</tt>, the foreign key column is set to +NULL+.
      def add_foreign_key(from_table, to_table, options = {})
        column = options[:column] || "#{to_table.to_s.singularize}_id"
        constraint_name = foreign_key_constraint_name(from_table, column, options)
        sql = "ALTER TABLE #{quote_table_name(from_table)} ADD CONSTRAINT #{quote_column_name(constraint_name)} "
        sql << foreign_key_definition(to_table, options)
        execute sql
      end

      def foreign_key_definition(to_table, options = {}) #:nodoc:
        column = options[:column] || "#{to_table.to_s.singularize}_id"
        primary_key = options[:primary_key] || "id"
        sql = "FOREIGN KEY (#{quote_column_name(column)}) REFERENCES #{quote_table_name(to_table)}(#{primary_key})"
        case options[:dependent]
        when :nullify
          sql << " ON DELETE SET NULL"
        when :delete
          sql << " ON DELETE CASCADE"
        end
        sql
      end

      # Remove the given foreign key from the table.
      #
      # ===== Examples
      # ====== Remove the suppliers_company_id_fk in the suppliers table.
      #   remove_foreign_key :suppliers, :companies
      # ====== Remove the foreign key named accounts_branch_id_fk in the accounts table.
      #   remove_foreign_key :accounts, :column => :branch_id
      # ====== Remove the foreign key named party_foreign_key in the accounts table.
      #   remove_foreign_key :accounts, :name => :party_foreign_key
      def remove_foreign_key(from_table, options)
        if Hash === options
          constraint_name = foreign_key_constraint_name(from_table, options[:column], options)
        else
          constraint_name = foreign_key_constraint_name(from_table, "#{options.to_s.singularize}_id")
        end
        execute "ALTER TABLE #{quote_table_name(from_table)} DROP CONSTRAINT #{quote_column_name(constraint_name)}"
      end

      private

      def foreign_key_constraint_name(table_name, column, options = {})
        constraint_name = original_name = options[:name] || "#{table_name}_#{column}_fk"
        return constraint_name if constraint_name.length <= OracleEnhancedAdapter::IDENTIFIER_MAX_LENGTH
        # leave just first three letters from each word
        constraint_name = constraint_name.split('_').map{|w| w[0,3]}.join('_')
        # generate unique name using hash function
        if constraint_name.length > OracleEnhancedAdapter::IDENTIFIER_MAX_LENGTH
          constraint_name = 'c'+Digest::SHA1.hexdigest(original_name)[0,OracleEnhancedAdapter::IDENTIFIER_MAX_LENGTH-1]
        end
        @logger.warn "#{adapter_name} shortened foreign key constraint name #{original_name} to #{constraint_name}" if @logger
        constraint_name
      end
      

      public

      # get table foreign keys for schema dump
      def foreign_keys(table_name) #:nodoc:
        (owner, desc_table_name, db_link) = @connection.describe(table_name)

        fk_info = select_all(<<-SQL, 'Foreign Keys')
          SELECT r.table_name to_table
                ,rc.column_name primary_key
                ,cc.column_name
                ,c.constraint_name name
                ,c.delete_rule
            FROM user_constraints#{db_link} c, user_cons_columns#{db_link} cc,
                 user_constraints#{db_link} r, user_cons_columns#{db_link} rc
           WHERE c.owner = '#{owner}'
             AND c.table_name = '#{desc_table_name}'
             AND c.constraint_type = 'R'
             AND cc.owner = c.owner
             AND cc.constraint_name = c.constraint_name
             AND r.constraint_name = c.r_constraint_name
             AND r.owner = c.owner
             AND rc.owner = r.owner
             AND rc.constraint_name = r.constraint_name
             AND rc.position = cc.position
        SQL

        fk_info.map do |row|
          options = {:column => oracle_downcase(row['column_name']), :name => oracle_downcase(row['name']),
            :primary_key => oracle_downcase(row['primary_key'])}
          case row['delete_rule']
          when 'CASCADE'
            options[:dependent] = :delete
          when 'SET NULL'
            options[:dependent] = :nullify
          end
          OracleEnhancedForeignKeyDefinition.new(table_name, oracle_downcase(row['to_table']), options)
        end
      end

      # REFERENTIAL INTEGRITY ====================================

      def disable_referential_integrity(&block) #:nodoc:
        sql_constraints = <<-SQL
        SELECT constraint_name, owner, table_name
          FROM user_constraints
          WHERE constraint_type = 'R'
          AND status = 'ENABLED'
        SQL
        old_constraints = select_all(sql_constraints)
        begin
          old_constraints.each do |constraint|
            execute "ALTER TABLE #{constraint["table_name"]} DISABLE CONSTRAINT #{constraint["constraint_name"]}"
          end
          yield
        ensure
          old_constraints.each do |constraint|
            execute "ALTER TABLE #{constraint["table_name"]} ENABLE CONSTRAINT #{constraint["constraint_name"]}"
          end
        end
      end

    end
  end
end

ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.class_eval do
  include ActiveRecord::ConnectionAdapters::OracleEnhancedSchemaStatementsExt
end