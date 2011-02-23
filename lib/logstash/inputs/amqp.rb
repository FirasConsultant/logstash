require "amqp" # rubygem 'amqp'
require "logstash/inputs/base"
require "logstash/namespace"
require "mq" # rubygem 'amqp'
require "uuidtools" # rubygem 'uuidtools'
require "cgi"

class LogStash::Inputs::Amqp < LogStash::Inputs::Base
  MQTYPES = [ "fanout", "direct", "topic" ]

  public
  def initialize(url, type, config={}, &block)
    super

    @mq = nil

    # Handle path /<vhost>/<type>/<name> or /<type>/<name>
    # vhost allowed to contain slashes
    if @url.path =~ %r{^/((.*)/)?([^/]+)/([^/]+)}
      unused, @vhost, @mqtype, @name = $~.captures
    else
      raise "amqp urls must have a path of /<type>/name or /vhost/<type>/name where <type> is #{MQTYPES.join(", ")}"
    end

    if !MQTYPES.include?(@mqtype)
      raise "Invalid type '#{@mqtype}' must be one of #{MQTYPES.join(", ")}"
    end
  end # def initialize

  public
  def register
    @logger.info("Registering input #{@url}")
    query_args = @url.query ? CGI.parse(@url.query) : {}
    amqpsettings = {
      :vhost => (@vhost or "/"),
      :host => @url.host,
      :port => (@url.port or 5672),
    }
    amqpsettings[:user] = @url.user if @url.user
    amqpsettings[:pass] = @url.password if @url.password
    amqpsettings[:logging] = query_args.include? "debug"
    queue_name = ((@urlopts["queue"].nil? or @urlopts["queue"].empty?) ? "logstash-#{@name}" : @urlopts["queue"])
    @logger.debug("Connecting with AMQP settings #{amqpsettings.inspect} to set up #{@mqtype.inspect} queue #{queue_name} on exchange #{@name.inspect}")
    @amqp = AMQP.connect(amqpsettings)
    @mq = MQ.new(@amqp)
    @target = nil

    @durable_exchange = @urlopts["durable_exchange"] ? true : false
    @durable_queue = @urlopts["durable_queue"] ? true : false
    @target = @mq.queue(queue_name, :durable => @durable_queue)
    case @mqtype
      when "fanout"
        @target.bind(@mq.fanout(@name, :durable => @durable_exchange))
      when "direct"
        @target.bind(@mq.direct(@name, :durable => @durable_exchange))
      when "topic"
        @target.bind(@mq.topic(@name, :durable => @durable_exchange))
    end # case @mqtype

    @target.subscribe(:ack => true) do |header, message|
      event = LogStash::Event.from_json(message)
      receive(event)
      header.ack
    end
  end # def register
end # class LogStash::Inputs::Amqp
