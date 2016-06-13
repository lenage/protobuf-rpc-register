require 'protobuf'
require 'protobuf/rpc/serializer'

module Protobuf
  module Rpc
    module Services
      class Base < ::Protobuf::Rpc::Service

        def compress_with(msg, serializer: :MSGPACK)
          if msg.is_a?(StandardError)
            msg = Messages::Error.new(error_class: msg.class.name, error_message: msg.message, error_backtrace: msg.backtrace)
          end
          respond_with Serializer.dump(msg, serializer: serializer)
        end

        def self.inherited(subclass)
          require 'new_relic/agent'
          subclass.include ::NewRelic::Agent::Instrumentation::ControllerInstrumentation
          subclass.inherit_rpcs!
        end

        def self.namespace
          self.name.deconstantize.deconstantize
        end

        def self.inherit_rpcs!
          superclass.rpcs.keys.each { |x| define_rpc(x) }
        end

        def self.define_rpc(method, req = ::Protobuf::Rpc::Messages::RpcCompressedMessage, res = ::Protobuf::Rpc::Messages::RpcCompressedMessage)
          self.rpc method, req, res

          define_method(method) do
            class_name = method.to_s.camelize.gsub('!', 'Bang').gsub('?', 'QuestionMark')
            result = nil
            req = Serializer.load(request)

            logger.debug(req.to_hash)

            begin
              interaction = Object.const_get(self.class.namespace, false).
                  const_get(:Interactions, false).
                  const_get(self.class.name.demodulize, false).
                  const_get(class_name, false)
            rescue NameError => e
              result = Protobuf::Rpc::MethodNotFound.new(e.message)
              result.set_backtrace(e.backtrace)
            else
              begin
                result = interaction.run!(req.to_hash)
                case result
                  when Protobuf::Message
                    result
                  when ::ActiveRecord::Base, ::ActiveRecord::Relation
                    result = result.to_proto(deprecated: false, except: interaction.except_attributes, include: interaction.include_attributes)
                  else
                    result.respond_to?(:to_proto) ? result.to_proto : result
                end
              rescue => e
                result = e
              end
            end

            compress_with result
          end

          add_transaction_tracer method
        end
      end
    end
  end
end
