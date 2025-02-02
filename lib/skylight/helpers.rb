module Skylight
  # Instrumenting a specific method will cause an event to be created every time that method is called.
  # The event will be inserted at the appropriate place in the Skylight trace.
  #
  # To instrument a method, the first thing to do is include {Skylight::Helpers Skylight::Helpers}
  # into the class that you will be instrumenting. Then, annotate each method that
  # you wish to instrument with {Skylight::Helpers::ClassMethods#instrument_method instrument_method}.
  module Helpers
    # @see Skylight::Helpers
    module ClassMethods
      # @api private
      def method_added(name)
        super

        if (opts = @__sk_instrument_next_method)
          @__sk_instrument_next_method = nil
          instrument_method(name, **opts)
        end
      end

      # @api private
      def singleton_method_added(name)
        super

        if (opts = @__sk_instrument_next_method)
          @__sk_instrument_next_method = nil
          instrument_class_method(name, **opts)
        end
      end

      # @overload instrument_method
      #   Instruments the following method
      #
      #   @example
      #     class MyClass
      #       include Skylight::Helpers
      #
      #       instrument_method
      #       def my_method
      #         do_expensive_stuff
      #       end
      #
      #     end
      #
      # @overload instrument_method([name], opts={})
      #   @param [Symbol|String] [name]
      #   @param [Hash] opts
      #   @option opts [String] :category ('app.method')
      #   @option opts [String] :title (ClassName#method_name)
      #   @option opts [String] :description
      #
      #   You may also declare the methods to instrument at any time by passing the name
      #   of the method as the first argument to `instrument_method`.
      #
      #   @example With name
      #     class MyClass
      #       include Skylight::Helpers
      #
      #       def my_method
      #         do_expensive_stuff
      #       end
      #
      #       instrument_method :my_method
      #
      #     end
      #
      #   By default, the event will be titled using the name of the class and the
      #   method. For example, in our previous example, the event name will be:
      #   +MyClass#my_method+. You can customize this by passing using the *:title* option.
      #
      #   @example Without name
      #     class MyClass
      #       include Skylight::Helpers
      #
      #       instrument_method title: 'Expensive work'
      #       def my_method
      #         do_expensive_stuff
      #       end
      #     end
      def instrument_method(*args, **opts)
        if (name = args.pop)
          title = "#{self}##{name}"
          __sk_instrument_method_on(self, name, title, **opts)
        else
          @__sk_instrument_next_method = opts
        end
      end

      # @overload instrument_class_method([name], opts={})
      #   @param [Symbol|String] [name]
      #   @param [Hash] opts
      #   @option opts [String] :category ('app.method')
      #   @option opts [String] :title (ClassName#method_name)
      #   @option opts [String] :description
      #
      #   You may also declare the methods to instrument at any time by passing the name
      #   of the method as the first argument to `instrument_method`.
      #
      #   @example With name
      #     class MyClass
      #       include Skylight::Helpers
      #
      #       def self.my_method
      #         do_expensive_stuff
      #       end
      #
      #       instrument_class_method :my_method
      #     end
      #
      #   By default, the event will be titled using the name of the class and the
      #   method. For example, in our previous example, the event name will be:
      #   +MyClass.my_method+. You can customize this by passing using the *:title* option.
      #
      #   @example With title
      #     class MyClass
      #       include Skylight::Helpers
      #
      #       def self.my_method
      #         do_expensive_stuff
      #       end
      #
      #       instrument_class_method :my_method, title: 'Expensive work'
      #     end
      def instrument_class_method(name, **opts)
        # NOTE: If the class is defined anonymously and then assigned to a variable this code
        #   will not be aware of the updated name.
        title = "#{self}.#{name}"
        __sk_instrument_method_on(__sk_singleton_class, name, title, **opts)
      end

      private

        HAS_ARGUMENT_FORWARDING = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7.0")

        def __sk_instrument_method_on(klass, name, title, **opts)
          category = (opts[:category] || "app.method").to_s
          title    = (opts[:title] || title).to_s
          desc     = opts[:description].to_s if opts[:description]

          # NOTE: The source location logic happens before we have have a config so we can'
          # check if source locations are enabled. However, it only happens once so the potential impact
          # should be minimal. This would more appropriately belong to Extensions::SourceLocation,
          # but as that is a runtime concern, and this happens at compile time, there isn't currently
          # a clean way to turn this on and off. The absence of the extension will cause the
          # source_file and source_line to be removed from the trace span before it is submitted.
          source_file, source_line = klass.instance_method(name).source_location

          # We should strongly prefer using the new argument-forwarding syntax (...) where available.
          # In Ruby 2.7, the following are known to be syntax errors:
          #
          # - mixing positional arguments with argument forwarding (e.g., send(:method_name, ...))
          # - calling a setter method with multiple arguments, unless dispatched via send or public_send.
          #
          # So it is possible, though not recommended, to define setter methods that take multiple arguments,
          # keywords, and/or blocks. Unfortunately, this means that for setters, we still need to explicitly
          # forward the different argument types.
          is_setter_method = name.to_s.end_with?("=")

          arg_string =
            if HAS_ARGUMENT_FORWARDING
              is_setter_method ? "*args, **kwargs, &blk" : "..."
            else
              "*args, &blk"
            end

          original_method_dispatch =
            if is_setter_method
              "self.send(:before_instrument_#{name}, #{arg_string})"
            else
              "before_instrument_#{name}(#{arg_string})"
            end

          klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            alias_method :"before_instrument_#{name}", :"#{name}"       # alias_method :"before_instrument_process", :"process"
            def #{name}(#{arg_string})                                  # def process(*args, **kwargs, &blk)
              span = Skylight.instrument(                               #   span = Skylight.instrument(
                category:    :"#{category}",                            #     category:    :"app.method",
                title:       #{title.inspect},                          #     title:       "process",
                description: #{desc.inspect},                           #     description: "Process data",
                source_file: #{source_file.inspect},                    #     source_file: "myapp/lib/processor.rb",
                source_line: #{source_line.inspect})                    #     source_line: 123)
                                                                        #
              meta = {}                                                 #   meta = {}
                                                                        #
              begin                                                     #   begin
                #{original_method_dispatch}                             #     self.before_instrument_process(...)
              rescue Exception => e                                     #   rescue Exception => e
                meta[:exception_object] = e                             #     meta[:exception_object] = e
                raise e                                                 #     raise e
              ensure                                                    #   ensure
                Skylight.done(span, meta) if span                       #     Skylight.done(span, meta) if span
              end                                                       #   end
            end                                                         # end
                                                                        #
            if protected_method_defined?(:"before_instrument_#{name}")  # if protected_method_defined?(:"before_instrument_process")
              protected :"#{name}"                                      #   protected :"process"
            elsif private_method_defined?(:"before_instrument_#{name}") # elsif private_method_defined?(:"before_instrument_process")
              private :"#{name}"                                        #   private :"process"
            end                                                         # end
          RUBY
        end

        if respond_to?(:singleton_class)
          alias __sk_singleton_class singleton_class
        else
          def __sk_singleton_class
            class << self; self; end
          end
        end
    end

    # @api private
    def self.included(base)
      base.class_eval do
        @__sk_instrument_next_method = nil
        extend ClassMethods
      end
    end
  end
end
