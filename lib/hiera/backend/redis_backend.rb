class Hiera
  module Backend
    class Redis_backend
      VERSION = '2.0.1'

      attr_reader :options

      def initialize
        require 'redis'
        Hiera.debug("Hiera Redis backend #{VERSION} starting")
        @options = { separator: ':', soft_connection_failure: false }.merge(Config[:redis] || {})
        case options[:deserialize]
        when :json then require 'json'
        when :yaml then require 'yaml'
        end
      end

      def deserialize(value)
        return value unless value.is_a?(String)

        case options[:deserialize]
        when :json then JSON.parse(value)
        when :yaml then YAML.load(value)
        else
          Hiera.warn("Invalid configuration for :deserialize; found #{options[:deserialize]}")
          value
        end
      rescue => e
        Hiera.warn("Error de-serializing data: #{e.class}: #{e.message}")
        value
      end

      def lookup(key, scope, order_override, resolution_type, context)
        answer = nil
        found = false

        Backend.datasources(scope, order_override) do |source|
          redis_key = (source.split('/') << key).join(options[:separator])
          data = read_value(redis_key)
          next if data.nil?

          found = true
          new_answer = Backend.parse_answer(data, scope, {}, context)

          case resolution_type.is_a?(Hash) ? :hash : resolution_type
          when :array
            check_type(key, new_answer, Array, String)
            answer ||= []
            answer << new_answer
          when :hash
            check_type(key, new_answer, Hash)
            answer ||= {}
            answer = Backend.merge_answer(new_answer, answer, resolution_type)
          else
            answer = new_answer
            break
          end
        end

        throw :no_such_key unless found
        answer
      rescue Redis::CannotConnectError, Errno::ENOENT => e
        Hiera.warn("Cannot connect to redis server at #{redis.id}")
        raise e unless options[:soft_connection_failure]
      end

      private

      def check_type(key, value, *types)
        return if types.any? { |type| value.is_a?(type) }
        expected = types.map(&:name).join(' or ')
        raise "Hiera type mismatch for key '#{key}': expected #{expected} and got #{value.class}"
      end

      def redis
        @redis ||= Redis.new(@options)
      end

      def read_value(key)
        data = redis_query(key)
        options[:deserialize] ? deserialize(data) : data
      end

      def redis_query(redis_key)
        case redis.type(redis_key)
        when 'set'
          redis.smembers(redis_key)
        when 'hash'
          redis.hgetall(redis_key)
        when 'list'
          redis.lrange(redis_key, 0, -1)
        when 'string'
          redis.get(redis_key)
        when 'zset'
          redis.zrange(redis_key, 0, -1)
        end
      end
    end
  end
end
